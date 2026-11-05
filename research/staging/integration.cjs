// Entirely synthetic end-to-end rehearsal. NEVER accepts a production Supabase URL.
// Run ONLY in the disposable local Supabase stack started by the staging workflow.
'use strict';
const assert=require('node:assert/strict');
const crypto=require('node:crypto');
const {createClient}=require('@supabase/supabase-js');
const url=process.env.STAGING_SUPABASE_URL || 'http://127.0.0.1:54321';
const anonKey=process.env.STAGING_ANON_KEY;
const serviceKey=process.env.STAGING_SERVICE_ROLE_KEY;
assert(/^http:\/\/(127\.0\.0\.1|localhost):54321\/?$/.test(url),
  'Refusing to run synthetic integration against a non-local Supabase URL');
assert(anonKey&&serviceKey,'Local Supabase keys were not supplied');
const options={auth:{autoRefreshToken:false,persistSession:false}};
const service=createClient(url,serviceKey,options);
const anon=createClient(url,anonKey,options);
const uid=()=>crypto.randomUUID();
function ok(result,where){
 if(result.error)throw Error(where+': '+result.error.message);
 return result.data;
}
async function checkFunction(client,body,expectedFailure=false){
 const {data,error}=await client.functions.invoke('liminal-auto-activate',{body});
 if(expectedFailure){
  assert(error||data?.error,'Expected denied function request');
  return {data,error};
 }
 if(error){
  let detail=error.message;
  try{detail+=' / '+JSON.stringify(await error.context?.json?.())}catch(e){}
  throw Error('Edge Function '+body.action+': '+detail);
 }
 assert(!data?.error,'Edge Function rejected request: '+data.error);
 return data;
}
const rect={type:'FeatureCollection',features:[{type:'Feature',properties:{},
 geometry:{type:'Polygon',coordinates:[[[-74.19,40.300],[-74.14,40.300],
 [-74.14,40.35],[-74.19,40.35],[-74.19,40.300]]]}}]};
async function run(){
 console.log('STAGING: Creating two synthetic Auth identities');
 const base='liminal-synthetic-'+uid().slice(0,8);
 const pass='SyntheticTestingOnly-2026-123!';
 const a=ok(await service.auth.admin.createUser({
  email:base+'-a@example.invalid',password:pass,email_confirm:true
 }), 'create A').user;
 const b=ok(await service.auth.admin.createUser({
  email:base+'-b@example.invalid',password:pass,email_confirm:true
 }), 'create B').user;
 assert(a?.id&&b?.id&&a.id!==b.id);
 const study=ok(await service.from('studies').insert({
  name:'SYNTHETIC Liminal integration test',polygons:rect,started_at:new Date().toISOString()
 }).select('id').single(),'create study');
 ok(await service.from('participants').insert([
  {study_id:study.id,user_id:a.id,display_name:'Synthetic A',is_admin:true},
  {study_id:study.id,user_id:b.id,display_name:'Synthetic B',is_admin:false}
 ]),'create roster');
 const assignments=[];
 for(let n=1;n<=100;n++){
  const id=uid();
  const lat=40.303+Math.floor((n-1)/10)*.0047;
  const lon=-74.187+((n-1)%10)*.0047;
  assignments.push({id:uid(),study_id:study.id,user_id:a.id,pair_id:id,sequence_no:n,
   longitude:lon,latitude:lat,sampling_type:'broad'});
  assignments.push({id:uid(),study_id:study.id,user_id:b.id,pair_id:id,sequence_no:n,
   longitude:lon+.00012,latitude:lat+.00010,sampling_type:'broad'});
 }
 ok(await service.from('assignments').insert(assignments),'create 200 original assignments');
 const date='2026-01-10T09:00:00Z';
 function synthResponse(row){
  const hot=row.sequence_no%13===0;
  return {assignment_id:row.id,study_id:study.id,user_id:row.user_id,
   valence:hot?'mixed':'neutral',descriptions:[hot?'intense':'none'],
   strength:hot?4:null,note:'synthetic only',recorded_at:date};
 }
 ok(await service.from('responses').insert(assignments.filter(r=>r.user_id===b.id||r.sequence_no<=88).map(synthResponse)),
   'seed 188 submitted observations');
 const adminClient=createClient(url,anonKey,options);
 const guestClient=createClient(url,anonKey,options);
 ok(await adminClient.auth.signInWithPassword({email:base+'-a@example.invalid',password:pass}), 'admin sign in');
 ok(await guestClient.auth.signInWithPassword({email:base+'-b@example.invalid',password:pass}), 'guest sign in');
 const guestStatus=await guestClient.rpc('liminal_admin_auto_status');
 assert(guestStatus.error,'Nonadmin should be denied status');
 await checkFunction(guestClient,{action:'activate',count:20,adaptivePercent:50,requestId:uid()},true);
 const baseline=ok(await adminClient.rpc('liminal_admin_auto_status'),'admin status');
 assert.equal(baseline.assignedRows,200);
 assert.equal(baseline.responseRows,188);
 assert.equal(baseline.canActivate,true);
 assert.equal(baseline.participants.find(p=>p.isYou)?.completed,88);
 assert.equal(baseline.participants.find(p=>!p.isYou)?.completed,100);
 console.log('STAGING: 88/100 + 100/100 status and role checks passed');
 const original=ok(await service.from('assignments').select('*').eq('study_id',study.id)
   .lte('sequence_no',100).order('id',{ascending:true}),'original snapshot');
 const req1=uid();
 const first=await checkFunction(adminClient,{action:'activate',count:20,adaptivePercent:50,requestId:req1});
 assert.equal(first.addedPairs,20);
 assert.equal(first.firstSequence,101);
 const again=await checkFunction(adminClient,{action:'activate',count:20,adaptivePercent:50,requestId:req1});
 assert.equal(again.alreadyCommitted,true);
 const blocked=await checkFunction(adminClient,{action:'activate',count:10,adaptivePercent:50,requestId:uid()},true);
 assert(blocked.error||blocked.data?.error);
 const afterFirst=ok(await service.from('assignments').select('*').eq('study_id',study.id)
   .lte('sequence_no',100).order('id',{ascending:true}),'unchanged original assignments');
 assert.deepEqual(afterFirst,original,'Original assignment records changed');
 const appended=ok(await service.from('assignments').select('*').eq('study_id',study.id)
  .gte('sequence_no',101).lte('sequence_no',120),'20-pair assignment inventory');
 assert.equal(appended.length,40);
 assert.equal(new Set(appended.map(r=>r.pair_id)).size,20);
 const key=(r)=>r.user_id;
 assert.equal(appended.filter(r=>key(r)===a.id).length,20);
 assert.equal(appended.filter(r=>key(r)===b.id).length,20);
 console.log('STAGING: 20-pair early release, permissions, idempotence passed');
 // Simulate each participant finishing exactly 116 and 119 assignments in order.
 const makeRows=appended.filter(r=>(r.user_id===a.id&&r.sequence_no<=116)
   ||(r.user_id===b.id&&r.sequence_no<=119));
 const remainingInitial=assignments.filter(r=>r.user_id===a.id&&r.sequence_no>=89);
 ok(await service.from('responses').insert([...remainingInitial,...makeRows].map(synthResponse)),
   'seed 116/120 and 119/120');
 const progress=ok(await adminClient.rpc('liminal_admin_auto_status'),'partial progress');
 assert.equal(progress.responseRows,235);
 assert.equal(progress.canActivate,true);
 assert.equal(progress.participants.find(p=>p.isYou)?.currentSetCompleted,16);
 assert.equal(progress.participants.find(p=>!p.isYou)?.currentSetCompleted,19);
 const request2=uid();
 const second=await checkFunction(adminClient,{action:'activate',count:30,adaptivePercent:75,requestId:request2});
 assert.equal(second.addedPairs,30);
 assert.equal(second.firstSequence,121);
 const check=await checkFunction(adminClient,{action:'check',requestId:request2});
 assert.equal(check.committed,true);
 assert.equal(check.addedPairs,30);
 const totals=ok(await service.from('assignments').select('sequence_no,user_id,pair_id')
   .eq('study_id',study.id),'verify 30-pair append');
 assert.equal(totals.length,300);
 assert.equal(totals.filter(r=>r.sequence_no>=121&&r.sequence_no<=150).length,60);
 const unchanged=ok(await service.from('assignments').select('*').eq('study_id',study.id)
   .lte('sequence_no',100).order('id',{ascending:true}),'verify original preservation');
 assert.deepEqual(unchanged,original);
 const nextA=ok(await adminClient.rpc('next_liminal_place'),'participant A next place')[0];
 const nextB=ok(await guestClient.rpc('next_liminal_place'),'participant B next place')[0];
 const seq117=assignments.find(r=>r.user_id===a.id&&r.sequence_no===117)||
  appended.find(r=>r.user_id===a.id&&r.sequence_no===117);
 const seq120=appended.find(r=>r.user_id===b.id&&r.sequence_no===120);
 assert.equal(nextA.assignment_id,seq117.id);
 assert.equal(nextB.assignment_id,seq120.id);
 console.log('STAGING PASS: 235 real submitted mock responses, 30 queued pairs 121–150, next locations remain 117/120');
}
run().catch(e=>{console.error('STAGING FAILURE:',e.message);process.exitCode=1});
