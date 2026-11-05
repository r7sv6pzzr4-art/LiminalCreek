import test from 'node:test';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {generateBatch as serverGenerate,distance} from '../supabase/functions/_shared/adaptive-engine.mjs';
const require=createRequire(import.meta.url);
const {generateBatch:localGenerate}=require('./adaptive-engine.js');

const bounds=[-74.18,40.31,-74.15,40.34];
const eligible=p=>p[0]>=bounds[0]&&p[0]<=bounds[2]&&p[1]>=bounds[1]&&p[1]<=bounds[3];
const originals=Array.from({length:100},(_,i)=>{
 const A=[-74.179+(i%10)*.0027,40.311+Math.floor(i/10)*.0028];
 return {id:'synthetic-'+i,A,B:[A[0]+.00012,A[1]+.00009]};
});
const obs=originals.flatMap((p,i)=>[
 {point:p.A,participant:'A',pairId:p.id,valence:i===35?'bad':'neutral',
  strength:i===35?4:null},
 {point:p.B,participant:'B',pairId:p.id,valence:'neutral',strength:null}
]);
test('Edge ES module and reviewed shared generator produce identical candidates',()=>{
 const args={count:20,bounds,eligible,observations:obs,existingPairs:originals,
  batchIndex:1,seed:'fixed-server-parity',adaptivePercent:50};
 const a=serverGenerate(args),b=localGenerate(args);
 assert.deepEqual(a,b);
 assert.equal(a.pairs.filter(x=>x.mode==='broad').length,10);
 assert(a.pairs.every(x=>eligible(x.A)&&eligible(x.B)&&distance(x.A,x.B)<=60.97));
});
test('40 activation is two non-overlapping 20-pair phases, without altering originals',()=>{
 const initial=JSON.stringify(originals),existingPairs=originals.slice();
 let pairCount=0;
 for(let chunk=0;chunk<2;chunk++){
  const batch=serverGenerate({count:20,bounds,eligible,observations:obs,
   existingPairs,seed:'activation-40-'+chunk,batchIndex:chunk+1,adaptivePercent:50});
  assert.equal(batch.pairs.length,20);
  assert.equal(batch.pairs.filter(p=>p.mode==='broad').length,10);
  existingPairs.push(...batch.pairs.map(p=>({A:p.A,B:p.B})));
  pairCount+=20;
 }
 assert.equal(pairCount,40);
 assert.equal(JSON.stringify(originals),initial);
 assert.equal(existingPairs.length,140);
});
test('activation after first 40 uses 75% adaptive',()=>{
 const batch=serverGenerate({count:20,bounds,eligible,observations:obs,
  existingPairs:originals,batchIndex:3,seed:'later-phase-test',adaptivePercent:75});
 assert.equal(batch.pairs.filter(p=>p.mode==='broad').length,5);
});
