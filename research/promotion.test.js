'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {preparePromotion}=require('./append-only-promotion.js');
const studyId='00000000-0000-4000-8000-000000000001';
const userA='00000000-0000-4000-8000-000000000002';
const userB='00000000-0000-4000-8000-000000000003';
const uuidOf=n=>'00000000-0000-4000-8000-'+String(n).padStart(12,'0');
const original=Array.from({length:100},(_,i)=>[userA,userB].map((user,j)=>({
  id:uuidOf(1000+i*2+j),study_id:studyId,user_id:user,
  sequence_no:i+1,pair_id:uuidOf(i+1),longitude:-74.17,latitude:40.32
}))).flat();
const frozen={id:uuidOf(9999),state:'staged',pairs:Array.from({length:12},(_,i)=>({
  stagingId:uuidOf(20000+i),mode:i%4===0?'quiet':'interesting',
  A:[-74.17+i/10000,40.32],B:[-74.17+i/10000,40.3202]
}))};
function promote(overrides={}){
  return preparePromotion({
    studyId,participants:[userA,userB],
    assignments:original,completedAssignmentIds:original.map(x=>x.id),
    batch:frozen,seed:'separate shuffled queues',...overrides
  });
}
test('promotion proposes APPEND-ONLY rows and preserves original assignment inventory',()=>{
  const snapshot=JSON.stringify(original);
  const result=promote();
  assert.equal(result.rows.length,24);
  assert.equal(result.appendOnly,true);
  assert.equal(result.expectedAssignmentCount,200);
  assert.equal(JSON.stringify(original),snapshot);
  const forA=result.rows.filter(x=>x.user_id===userA);
  const forB=result.rows.filter(x=>x.user_id===userB);
  assert.deepEqual(forA.map(x=>x.sequence_no),Array.from({length:12},(_,i)=>101+i));
  assert.deepEqual(forB.map(x=>x.sequence_no),Array.from({length:12},(_,i)=>101+i));
  assert.deepEqual(new Set(forA.map(x=>x.pair_id)),new Set(forB.map(x=>x.pair_id)));
  assert(forA.every(row=>row.sampling_type==='adaptive'));
  assert(forB.every(row=>row.sampling_type==='adaptive'));
});
test('cannot promote when either participant has an incomplete original assignment',()=>{
  assert.throws(()=>promote({completedAssignmentIds:original
    .filter(x=>x.id!==original[199].id).map(x=>x.id)}),/Wait until/);
});
test('cannot promote duplicate or unstaged batches',()=>{
  assert.throws(()=>promote({alreadyReleasedBatchIds:[frozen.id]}),/already released/);
  assert.throws(()=>promote({batch:{...frozen,state:'released'}}),/Only staged/);
});
test('subsequent batches continue from max sequence and cannot alter originals',()=>{
  const prior=promote().rows.map((r,i)=>({...r,id:uuidOf(30000+i)}));
  const later={id:uuidOf(9998),state:'staged',pairs:[{
    stagingId:uuidOf(40000),mode:'broad',A:[-74.165,40.321],B:[-74.1652,40.321]
  }]};
  const next=promote({assignments:[...original,...prior],batch:later});
  assert(next.rows.every(r=>r.sequence_no===113));
  assert.deepEqual(original.length,200);
});
