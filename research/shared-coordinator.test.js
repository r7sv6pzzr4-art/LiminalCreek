'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {geometryMask,prepareSharedPreview}=require('./shared-coordinator.js');
const square=[[-74.18,40.31],[-74.15,40.31],[-74.15,40.34],[-74.18,40.34],[-74.18,40.31]];
const hole=[[-74.171,40.321],[-74.168,40.321],[-74.168,40.324],[-74.171,40.324],[-74.171,40.321]];
const polygon={type:'Polygon',coordinates:[square]};
const originals=Array.from({length:100},(_,i)=>{
 const A=[-74.179+(i%10)*.0027,40.311+Math.floor(i/10)*.0028];
 return {id:'original-'+i,A,B:[A[0]+.00012,A[1]+.00009]};
});
const observations=originals.flatMap((p,i)=>[
 {point:p.A,participant:'A',pairId:p.id,valence:i===35?'bad':'neutral',
  strength:i===35?4:null,note:'PRIVATE SENTINEL'},
 {point:p.B,participant:'B',pairId:p.id,valence:'neutral',strength:null}
]);
const args={polygons:polygon,originalPairs:originals,observations,completion:{A:95,B:100},
 approvedAdditionalPairs:20,seed:'offline-synthetic-snapshot'};
test('honors polygon holes',()=>{
 const mask=geometryMask({type:'Polygon',coordinates:[square,hole]});
 assert(mask.eligible([-74.176,40.32]));
 assert(!mask.eligible([-74.169,40.322]));
});
test('private offline preview produces exactly 20 pairs, not a release',()=>{
 const snapshot=JSON.stringify({originals,observations});
 const a=prepareSharedPreview(args),b=prepareSharedPreview(args);
 assert.deepEqual(a,b);
 assert.equal(a.batch.pairs.length,20);
 assert.equal(a.batch.pairs.filter(p=>p.mode==='broad').length,10);
 assert.equal(a.releaseEligible,false);
 assert.equal(a.productionWrites,false);
 assert.equal(a.coverage.assignedPairs,100);
 assert.equal(JSON.stringify({originals,observations}),snapshot);
 assert(!JSON.stringify(a).includes('PRIVATE SENTINEL'));
});
test('preview becomes release-eligible only when both original cohorts finished',()=>{
 const r=prepareSharedPreview({...args,completion:{A:100,B:100}});
 assert.equal(r.releaseEligible,true);
});
test('no approved extension, invalid baseline, excessive separation all fail closed',()=>{
 assert.throws(()=>prepareSharedPreview({...args,approvedAdditionalPairs:0}),/authorized/);
 assert.throws(()=>prepareSharedPreview({...args,originalPairs:originals.slice(1)}),/100 original/);
 assert.throws(()=>prepareSharedPreview({...args,
  originalPairs:originals.map((x,i)=>i===0?{...x,B:[-74.177,40.311]}:x)}),/200 ft/);
});

test('before/after audits use identical geographic samples, and candidate locations remain unchanged',()=>{
 const result=prepareSharedPreview(args);
 const {eligible,bounds}=geometryMask(args.polygons);
 const expected=require('./adaptive-engine.js').generateBatch({
  bounds,eligible,observations:args.observations,existingPairs:args.originalPairs,
  count:20,seed:args.seed,batchIndex:1,adaptivePercent:50
 });
 assert.deepEqual(result.batch,expected,'Coverage reporting must not change candidate locations');
 assert.equal(result.coverage.seed,result.coverageAfter.seed);
 assert.equal(result.coverage.samples,result.coverageAfter.samples);
 assert.equal(result.coverage.assignedPairs,100);
 assert.equal(result.coverageAfter.assignedPairs,120);
 for(const scope of ['combined','participantA','participantB']){
  const before=result.coverage[scope],after=result.coverageAfter[scope];
  for(const metric of ['medianMeters','p90Meters'])
   assert(after[metric]<=before[metric]+1e-8,scope+' '+metric+' must not worsen');
  for(const radius of [100,200])
   assert(after.estimatedFractionBeyondMeters[radius]<=
    before.estimatedFractionBeyondMeters[radius]+1e-12,
    scope+' >'+radius+'m area must not increase');
 }
});
