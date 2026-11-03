'use strict';
// Only the two-person SHARED study. No personal hotspot modules or Supabase access.
const test = require('node:test');
const assert = require('node:assert/strict');
const {generateBatch, distance} = require('./adaptive-engine.js');
const {auditCoverage, phasePlan} = require('./coverage-audit.js');
const {freezeStage} = require('./freeze-stage.js');
const {preparePromotion} = require('./append-only-promotion.js');

const bounds = [-74.18,40.31,-74.15,40.34];
const eligible = p => p[0] >= bounds[0] && p[0] <= bounds[2] &&
  p[1] >= bounds[1] && p[1] <= bounds[3];
const uuid = i => '00000000-0000-4000-8000-' + String(i+1).padStart(12,'0');
const studyId = uuid(1000), people = [uuid(1001),uuid(1002)];
const existing = Array.from({length:100},(_,i)=>{
 const a=[-74.179+(i%10)*.0027,40.311+Math.floor(i/10)*.0028];
 return {id:'original-'+i,A:a,B:[a[0]+.00012,a[1]+.00009]};
});
const observations=existing.flatMap((p,i)=>[
 {point:p.A,pairId:p.id,participant:'A',valence:i===32?'bad':'neutral',strength:i===32?4:null},
 {point:p.B,pairId:p.id,participant:'B',valence:'neutral',strength:null}
]);
const options={count:20,bounds,eligible,observations,existingPairs:existing,
 batchIndex:1,adaptivePercent:50,seed:'shared-test-fixed'};
test('shared sampling preserves the original array, outputs 10 controls and 10 adaptive pairs',()=>{
 const old=JSON.stringify(existing);
 const x=generateBatch(options),y=generateBatch(options);
 assert.deepEqual(x,y);
 assert.equal(JSON.stringify(existing),old);
 assert.equal(x.pairs.length,20);
 assert.equal(x.pairs.filter(p=>p.mode==='broad').length,10);
 assert(x.pairs.every(p=>eligible(p.A)&&eligible(p.B)&&distance(p.A,p.B)<=60.97));
});
test('coverage audit is response-blind and detects unsampled territory',()=>{
 const audit=auditCoverage({bounds,eligible,existingPairs:existing,sampleCount:300});
 assert.equal(audit.assignedPairs,100);
 assert(audit.combined.p90Meters>0);
 assert(!JSON.stringify(audit).includes('strength'));
});
test('first two 20-pair batches remain 50/50, then shift to 75/25',()=>{
 const pct=n=>phasePlan({releasedAdditionalPairs:n,approvedAdditionalPairs:100}).adaptivePercent;
 assert.deepEqual([pct(0),pct(20),pct(40)],[50,50,75]);
});
test('freeze creates separate orders and does not mutate generated locations',()=>{
 const batch=generateBatch(options),baseline=JSON.stringify(batch);
 const frozen=freezeStage({batch,seed:'frozen-test',uuidForPair:uuid});
 assert.equal(frozen.rows.length,20);
 assert.equal(JSON.stringify(batch),baseline);
 assert.deepEqual(frozen.rows.map(r=>r.sequence_a).sort((a,b)=>a-b),
   Array.from({length:20},(_,i)=>i+1));
 assert(frozen.rows.some(r=>r.sequence_a!==r.sequence_b));
});
test('promotion blocked until BOTH participants complete their original 100',()=>{
 const batch=generateBatch(options),frozen=freezeStage({batch,seed:'frozen-test',uuidForPair:uuid});
 const assignments=existing.flatMap((p,i)=>people.map((user,j)=>({
   id:uuid(2000+i*2+j),study_id:studyId,user_id:user,
   pair_id:uuid(3000+i),sequence_no:i+1
 })));
 const staged={id:uuid(5000),state:'staged',
   pairs:frozen.rows.map(row=>({stagingId:row.id,mode:row.sampling_mode,
     A:[row.a_longitude,row.a_latitude],B:[row.b_longitude,row.b_latitude],
     maximumSeparationMeters:row.maximum_separation_meters}))};
 const completed=assignments.filter(a=>a.user_id===people[0]).map(a=>a.id);
 const args={studyId,participants:people,assignments,batch:staged,
   completedAssignmentIds:completed,seed:'promo-test'};
 assert.throws(()=>preparePromotion(args),/both|original/i);
 const ready=preparePromotion({...args,completedAssignmentIds:assignments.map(a=>a.id)});
 assert.equal(ready.rows.length,40);
 assert(ready.rows.every(r=>r.sequence_no>=101&&r.sequence_no<=120));
 assert.equal(assignments.length,200);
});
