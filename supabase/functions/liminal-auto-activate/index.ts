// DEVELOPMENT ONLY. Supabase Edge Function: authenticated, admin-only shared sampling.
// Reads private responses server-side; NEVER sends observations or coordinates to browsers.
// No live deployment is performed by this file.
import { createClient } from "npm:@supabase/supabase-js@2";
import { generateBatch, distance } from "../_shared/adaptive-engine.mjs";

const URL = Deno.env.get("SUPABASE_URL") || "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const PUBLIC_KEY = Deno.env.get("SUPABASE_ANON_KEY") || "";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization,apikey,content-type,x-client-info",
  "Access-Control-Allow-Methods": "POST,OPTIONS",
  "Content-Type": "application/json",
};
const reply = (data: unknown,status=200)=>
 new Response(JSON.stringify(data),{status,headers:cors});
const fail = (message:string,status=409)=>reply({error:message},status);
const requireCheck=(ok:unknown,message:string)=>{if(!ok)throw Error(message)};
type Position = [number,number];
type Pair = { A:Position; B:Position };
type Member = {user_id:string};
type Assignment = {
 id:string; user_id:string; pair_id:string; sequence_no:number;
 longitude:number;latitude:number;
};
type ResponseRow = {
 assignment_id:string; user_id:string;valence:string;
 strength:number|null;
};
function areaMask(input: any){
 const features=input?.type==="FeatureCollection"?input.features.map((f:any)=>f.geometry)
   :input?.type==="Feature"?[input.geometry]:[input];
 const polys:number[][][][]=[];
 for(const g of features){
  if(g?.type==="Polygon")polys.push(g.coordinates);
  else if(g?.type==="MultiPolygon")polys.push(...g.coordinates);
  else throw Error("Unexpected study polygon geometry");
 }
 requireCheck(polys.length>0,"Study area is empty");
 const ring=(p:Position,points:number[][])=>{
  let inside=false;
  for(let i=0,j=points.length-1;i<points.length;j=i++){
   const a=points[i],b=points[j];
   if((a[1]>p[1])!==(b[1]>p[1])&&p[0]<(b[0]-a[0])*(p[1]-a[1])/(b[1]-a[1])+a[0])inside=!inside;
  }
  return inside;
 };
 const eligible=(p:Position)=>polys.some(poly=>ring(p,poly[0])&&!poly.slice(1).some(h=>ring(p,h)));
 const exterior=polys.flatMap(p=>p[0]);
 const bounds=[Math.min(...exterior.map(p=>p[0])),Math.min(...exterior.map(p=>p[1])),
               Math.max(...exterior.map(p=>p[0])),Math.max(...exterior.map(p=>p[1]))];
 requireCheck(bounds.every(Number.isFinite),"Invalid study bounds");
 return {bounds,eligible};
}
async function allRows(client:any,table:string,fields:string,studyId:string){
 const output:any[]=[];
 for(let start=0;start<50000;start+=900){
  const {data,error}=await client.from(table).select(fields).eq("study_id",studyId)
    .order("id",{ascending:true}).range(start,start+899);
  if(error)throw Error("Cannot read a consistent private study snapshot");
  output.push(...(data||[]));
  if(!data||data.length<900)return output;
 }
 throw Error("Study exceeds the supported snapshot size");
}
function randomizedOrder(count:number){
 const output=Array.from({length:count},(_,i)=>i+1);
 const buf=new Uint32Array(1);
 for(let i=count-1;i>0;i--){
  crypto.getRandomValues(buf);
  const j=buf[0]%(i+1);
  [output[i],output[j]]=[output[j],output[i]];
 }
 return output;
}
Deno.serve(async req=>{
 if(req.method==="OPTIONS")return new Response(null,{headers:cors});
 if(req.method!=="POST")return fail("POST required",405);
 try{
  requireCheck(URL&&SERVICE_KEY&&PUBLIC_KEY,"Function environment is not configured");
  const bearer=req.headers.get("Authorization")||"";
  if(!/^Bearer\s+\S+$/i.test(bearer))return fail("Sign in required",401);
  const token=bearer.replace(/^Bearer\s+/i,"");
  const admin=createClient(URL,SERVICE_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
  const caller=createClient(URL,PUBLIC_KEY,{
   global:{headers:{Authorization:bearer}},
   auth:{persistSession:false,autoRefreshToken:false}
  });
  const {data:identity,error:authError}=await caller.auth.getUser(token);
  if(authError||!identity.user)return fail("Invalid session",401);
  const {data:membership,error:memberError}=await admin.from("participants")
   .select("study_id,is_admin").eq("user_id",identity.user.id).eq("is_admin",true).limit(1).maybeSingle();
  if(memberError||!membership)return fail("Administrator account required",403);
  const payload=await req.json();
  if(payload?.action==="status"){
   const {data,error}=await caller.rpc("liminal_admin_auto_status");
   if(error)throw Error(error.message);
   return reply({status:data});
  }
  if(payload?.action!=="activate"&&payload?.action!=="check")
   return fail("Unknown action",400);
  const requestId=String(payload.requestId||"");
  if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(requestId))
   return fail("Invalid activation ID",400);
  // A prior committed request must be recognized even if today's assignment
  // queue is no longer ready. This prevents duplicate creation on lost replies.
  const {data:prior,error:priorError}=await admin.from("liminal_auto_batches")
   .select("id,pair_count,first_sequence").eq("study_id",membership.study_id)
   .eq("request_id",requestId).maybeSingle();
  if(priorError)throw Error("Could not verify previous activation");
  if(payload.action==="check")
   return reply({committed:!!prior,addedPairs:prior?.pair_count||0,
    firstSequence:prior?.first_sequence||null,batchId:prior?.id||null});
  const requested=payload.count;
  if(requested!==20&&requested!==40)return fail("Choose 20 or 40 pairs",400);
  if(prior){
   if(prior.pair_count!==requested)return fail("Request ID already used with another batch size",409);
   return reply({activated:true,alreadyCommitted:true,addedPairs:prior.pair_count,
    firstSequence:prior.first_sequence,batchId:prior.id});
  }
  const {data:status,error:statusError}=await caller.rpc("liminal_admin_auto_status");
  if(statusError||!status?.canActivate)return fail(
   "Both participants must finish all currently assigned locations before activation");
  const studyId=membership.study_id;
  if(status.studyId!==studyId)throw Error("Study authorization mismatch");
  const {data:study,error:studyError}=await admin.from("studies")
   .select("polygons,started_at,revealed_at").eq("id",studyId).single();
  if(studyError||!study||!study.started_at||study.revealed_at)throw Error("Shared study is not active");
  const [memberRows,assignmentRows,responseRows]=await Promise.all([
   admin.from("participants").select("user_id").eq("study_id",studyId).order("user_id",{ascending:true}),
   allRows(admin,"assignments","id,user_id,pair_id,sequence_no,longitude,latitude",studyId),
   allRows(admin,"responses","id,assignment_id,user_id,valence,strength",studyId)
  ]);
  if(memberRows.error||!memberRows.data)throw Error("Cannot read participant roster");
  const members=(memberRows.data as Member[]).map(m=>m.user_id);
  requireCheck(members.length===2&&members[0]!==members[1],"Exactly two participants required");
  const assignments=assignmentRows as Assignment[],responses=responseRows as ResponseRow[];
  requireCheck(assignments.length===status.assignedRows&&responses.length===status.responseRows,
   "Study snapshot changed; retry");
  requireCheck(assignments.length>=200&&assignments.length===responses.length&&
    assignments.length%2===0,"Both participant queues must be fully completed");
  const userSet=new Set(members);
  const byId=new Map(assignments.map(a=>[a.id,a]));
  requireCheck(byId.size===assignments.length,"Duplicate assignment");
  const paired=new Map<string,{A?:Position,B?:Position,sequenceA?:number,sequenceB?:number}>();
  const originalCounts={A:0,B:0};
  for(const a of assignments){
   const role=a.user_id===members[0]?"A":a.user_id===members[1]?"B":null;
   if(role===null||!userSet.has(a.user_id))throw Error("Unknown assignment owner");
   let p=paired.get(a.pair_id);
   if(!p){p={};paired.set(a.pair_id,p)}
   requireCheck(!p[role],"Duplicate paired assignment");
   p[role]=[a.longitude,a.latitude];
   if(role==="A")p.sequenceA=a.sequence_no;else p.sequenceB=a.sequence_no;
   if(a.sequence_no<=100)originalCounts[role]++;
  }
  requireCheck(originalCounts.A===100&&originalCounts.B===100,"Original assignments changed");
  const existingPairs:Pair[]=[];
  for(const [,pair] of paired){
   requireCheck(pair.A&&pair.B,"Incomplete matched site pair");
   existingPairs.push({A:pair.A!,B:pair.B!});
  }
  requireCheck(existingPairs.length===assignments.length/2,"Unbalanced assignment queue");
  const seenResponse=new Set<string>();
  const observations=responses.map(r=>{
   const a=byId.get(r.assignment_id);
   requireCheck(a&&a.user_id===r.user_id&&!seenResponse.has(r.assignment_id),
    "Response ownership/inventory mismatch");
   seenResponse.add(r.assignment_id);
   return {point:[a!.longitude,a!.latitude] as Position,
    participant:a!.user_id===members[0]?"A":"B",
    pairId:a!.pair_id,valence:r.valence,strength:r.strength};
  });
  const {bounds,eligible}=areaMask(study.polygons);
  for(const pair of existingPairs)
   requireCheck(eligible(pair.A)&&eligible(pair.B),"Existing assignment outside eligible area");
  const seed=crypto.randomUUID();
  const requestedRows:any[]=[];
  const currentPairs=existingPairs.slice();
  const nextSequence=existingPairs.length+1;
  for(let chunk=0;chunk<requested/20;chunk++){
   const slotStart=nextSequence+20*chunk;
   const percent=slotStart<=140?50:75;
   const next=generateBatch({count:20,bounds,eligible,
    observations,existingPairs:currentPairs,batchIndex:Math.floor((slotStart-101)/20)+1,
    seed:seed+"-"+chunk,adaptivePercent:percent});
   requireCheck(next.pairs.length===20,"Sampling engine did not return 20 pairs");
   for(const pair of next.pairs){
    requireCheck(eligible(pair.A)&&eligible(pair.B)&&distance(pair.A,pair.B)<=60.97,
     "Generated candidate fails geographic validation");
    requestedRows.push({pairId:crypto.randomUUID(),mode:pair.mode,
     longitudeA:pair.A[0],latitudeA:pair.A[1],
     longitudeB:pair.B[0],latitudeB:pair.B[1],adaptivePercent:percent});
    currentPairs.push({A:pair.A,B:pair.B});
   }
  }
  const orderA=randomizedOrder(requested);
  const orderB=randomizedOrder(requested);
  requestedRows.forEach((r,i)=>{r.orderA=orderA[i];r.orderB=orderB[i]});
  const {data:result,error:commitError}=await admin.rpc("liminal_admin_commit_auto_batch",{
   p_actor_user_id:identity.user.id,
   p_request_id:requestId,
   p_expected_assignment_rows:assignments.length,
   p_expected_response_rows:responses.length,
   p_seed:seed,p_pairs:requestedRows
  });
  if(commitError)throw Error(commitError.message);
  return reply({activated:true,addedPairs:result.addedPairs,
   firstSequence:result.firstSequence,batchId:result.batchId,
   alreadyCommitted:result.alreadyCommitted});
 }catch(e){
  return fail(e instanceof Error?e.message:"Activation failed",409);
 }
});
