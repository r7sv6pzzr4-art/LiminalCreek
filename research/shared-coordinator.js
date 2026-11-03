/* Shared-study coordinator — OFFLINE, INACTIVE.
 * Uses already-exported PRIVATE input only. No Supabase, fetch, browser or DB APIs.
 * Never publish a snapshot or generated locations to GitHub / Pages / Actions.
 * This is an in-memory planning preview, NOT database staging or release.
 */
'use strict';
const {generateBatch,distance}=require('./adaptive-engine.js');
const {auditCoverage,phasePlan}=require('./coverage-audit.js');
function check(ok,message){if(!ok)throw Error(message)}
function geometries(input){
 const root=input?.type==='FeatureCollection'?input.features.map(f=>f.geometry):
   input?.type==='Feature'? [input.geometry]:[input];
 const polygons=[];
 for(const g of root){
  if(g?.type==='Polygon')polygons.push(g.coordinates);
  else if(g?.type==='MultiPolygon')polygons.push(...g.coordinates);
  else throw Error('Only Polygon and MultiPolygon geometry is supported');
 }
 check(polygons.length>0,'Empty study geometry');
 return polygons;
}
function ringContains(point,ring){
 let inside=false;
 for(let i=0,j=ring.length-1;i<ring.length;j=i++){
  const a=ring[i],b=ring[j];
  if((a[1]>point[1])!==(b[1]>point[1]) &&
      point[0]<(b[0]-a[0])*(point[1]-a[1])/(b[1]-a[1])+a[0])inside=!inside;
 }
 return inside;
}
function geometryMask(geometry){
 const polygons=geometries(geometry);
 const eligible=p=>polygons.some(r=>ringContains(p,r[0])&&!r.slice(1).some(h=>ringContains(p,h)));
 const all=polygons.flatMap(r=>r[0]);
 const bounds=[Math.min(...all.map(p=>p[0])),Math.min(...all.map(p=>p[1])),
  Math.max(...all.map(p=>p[0])),Math.max(...all.map(p=>p[1]))];
 check(bounds.every(Number.isFinite),'Invalid geometry coordinates');
 return {eligible,bounds};
}
function prepareSharedPreview({polygons,originalPairs,observations=[],completion,
  releasedAdditionalPairs=0,approvedAdditionalPairs=20,seed,batchIndex=1,
  sampleCount=1200}={}){
 check(Array.isArray(originalPairs)&&originalPairs.length===100,
  'Exactly 100 original matched pairs required for initial preview');
 check(typeof seed==='string'&&seed.length>=8,'Explicit reproducible seed required');
 check(completion&&Number.isInteger(completion.A)&&Number.isInteger(completion.B)&&
  [completion.A,completion.B].every(x=>x>=0&&x<=100),'Completion counts for both participants required');
 const {eligible,bounds}=geometryMask(polygons);
 for(const pair of originalPairs){
  check(Array.isArray(pair.A)&&Array.isArray(pair.B)&&eligible(pair.A)&&eligible(pair.B),
   'Original pair outside eligible area');
  check(distance(pair.A,pair.B)<=60.97,'Original matched pair exceeds 200 ft');
 }
 check(Array.isArray(observations),'Observations array required');
 // Restrict inputs to the minimum fields used for sampling. Never propagate
 // comments, feelings, email, names or any user-supplied extra properties.
 const safeObservations=observations.map(o=>({
  point:o.point,participant:o.participant,pairId:o.pairId,
  valence:o.valence,strength:o.strength
 }));
 const coverage=auditCoverage({bounds,eligible,existingPairs:originalPairs,
  seed:seed+'-coverage-audit',sampleCount});
 const plan=phasePlan({releasedAdditionalPairs,approvedAdditionalPairs});
 check(plan.nextBatchPairs>0,'No additional matched pairs authorized');
 const batch=generateBatch({bounds,eligible,observations:safeObservations,
  existingPairs:originalPairs,count:plan.nextBatchPairs,
  adaptivePercent:plan.adaptivePercent,seed,batchIndex});
 // Dry-run invariants independent from the selection engine.
 for(const pair of batch.pairs){
  check(eligible(pair.A)&&eligible(pair.B),'Proposed pair outside polygons');
  check(distance(pair.A,pair.B)<=60.97,'Proposed matched pair exceeds 200 ft');
 }
 return {privatePreview:true,productionWrites:false,
   releaseEligible:completion.A===100&&completion.B===100,
   completion:{A:completion.A,B:completion.B},
   coverage,phase:plan.phase,adaptivePercent:plan.adaptivePercent,
   batch,warning:'PRIVATE LOCAL PREVIEW ONLY. Do not publish coordinates or commit output.'};
}
module.exports={geometryMask,prepareSharedPreview};
