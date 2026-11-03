'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {freezeStage}=require('./freeze-stage.js');
const uuid=i=>'00000000-0000-4000-8000-'+String(i+1).padStart(12,'0');
const pairs=Array.from({length:20},(_,i)=>({
 mode:i%2?'broad':'interesting',
 A:[-74.17+i*.0001,40.32],B:[-74.1699+i*.0001,40.3201],
 maximumSeparationMeters:60.96
}));
test('frozen stage preserves all pairs but uses separate participant orders',()=>{
 const batch={staged:true,batchIndex:1,adaptivePercent:50,pairs};
 const original=JSON.stringify(batch);
 const x=freezeStage({batch,seed:'independent',uuidForPair:uuid});
 assert.deepEqual(x,freezeStage({batch,seed:'independent',uuidForPair:uuid}));
 assert.equal(x.rows.length,20);assert.equal(JSON.stringify(batch),original);
 assert.deepEqual(x.rows.map(x=>x.sequence_a).sort((a,b)=>a-b),Array.from({length:20},(_,i)=>i+1));
 assert.deepEqual(x.rows.map(x=>x.sequence_b).sort((a,b)=>a-b),Array.from({length:20},(_,i)=>i+1));
 assert(x.rows.some(x=>x.sequence_a!==x.sequence_b));
 assert(x.rows.every((x,i)=>x.id===uuid(i)&&x.a_longitude===pairs[i].A[0]));
});
test('stage rejects duplicate pair UUIDs or batches above review limit',()=>{
 assert.throws(()=>freezeStage({batch:{staged:true,pairs},seed:'x',uuidForPair:()=>uuid(0)}),/unique/);
 assert.throws(()=>freezeStage({batch:{staged:true,pairs:[...pairs,...pairs]},seed:'x',uuidForPair:uuid}),/1–30/);
});
