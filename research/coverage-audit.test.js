'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {auditCoverage,phasePlan,dist}=require('./coverage-audit.js');
const bounds=[-74.180,40.310,-74.170,40.320];
const eligible=p=>p[0]>=bounds[0]&&p[0]<=bounds[2]&&p[1]>=bounds[1]&&p[1]<=bounds[3]
 &&!(p[0]>-74.176&&p[0]<-74.174&&p[1]>40.313&&p[1]<40.315);
const base=Array.from({length:100},(_,i)=>{
 const p=[-74.179+(i%5)*.00025,40.3105+Math.floor(i/5)*.00043];
 return {A:p,B:[p[0]+.00007,p[1]+.00003]};
});
test('seeded coverage audit reports estimated gaps for both participants; excludes ineligible areas',()=>{
 const a=auditCoverage({bounds,eligible,existingPairs:base,sampleCount:700,seed:'before'});
 const b=auditCoverage({bounds,eligible,existingPairs:base,sampleCount:700,seed:'before'});
 assert.deepEqual(a,b);
 assert.equal(a.assignedPairs,100);
 assert(a.combined.p90Meters>150,'Clustered baseline should have substantial geographic holes');
 assert(a.largestCoverageGaps.every(x=>eligible(x.point)));
 assert(a.participantA.p90Meters>=0&&a.participantB.p90Meters>=0);
 assert(!JSON.stringify(a).includes('descriptions')&&!JSON.stringify(a).includes('notes'));
});
test('response-blind coverage additions reduce holes in synthetic under-covered region',()=>{
 const added=Array.from({length:20},(_,i)=>{
  const p=[-74.1725+(i%4)*.00045,40.311+Math.floor(i/4)*.0016];
  return {A:p,B:[p[0]+.00008,p[1]+.00005]};
 });
 const before=auditCoverage({bounds,eligible,existingPairs:base,sampleCount:850,seed:'compare'});
 const after=auditCoverage({bounds,eligible,existingPairs:[...base,...added],sampleCount:850,seed:'compare'});
 assert(after.combined.p90Meters<before.combined.p90Meters);
 assert(after.combined.estimatedFractionBeyondMeters[200]<
   before.combined.estimatedFractionBeyondMeters[200]);
});
test('phase schedule uses two 50% coverage-repair batches followed by 75% refinement',()=>{
 const plan=n=>phasePlan({releasedAdditionalPairs:n,approvedAdditionalPairs:100});
 assert.deepEqual([0,20,40,60,80,100].map(n=>[plan(n).nextBatchPairs,plan(n).adaptivePercent]),
 [[20,50],[20,50],[20,75],[20,75],[20,75],[0,75]]);
 assert.equal(plan(35).nextBatchPairs,5,'Never straddle the transition within a frozen batch');
 assert.equal(phasePlan({releasedAdditionalPairs:20,approvedAdditionalPairs:30}).nextBatchPairs,10);
 assert.equal(phasePlan({releasedAdditionalPairs:0,approvedAdditionalPairs:0}).nextBatchPairs,0);
 assert.throws(()=>phasePlan({releasedAdditionalPairs:40,approvedAdditionalPairs:20}),/cap/);
 assert.throws(()=>phasePlan({releasedAdditionalPairs:40}),/required/);
});
