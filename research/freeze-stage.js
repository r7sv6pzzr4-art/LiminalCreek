/* Frozen staging plan builder — INACTIVE. No database credentials or writes.
 * Called by a future trusted coordinator. Do not expose staged pairs to users.
 * Pair UUIDs are allocated by the coordinator, not generated in a browser.
 */
'use strict';
const {preparePromotion}=require('./append-only-promotion.js');
function assert(ok,msg){if(!ok)throw Error(msg)}
function hashSeed(seed){
 let a=2166136261;for(const c of String(seed))a=Math.imul(a^c.charCodeAt(0),16777619);
 return ()=>{a+=0x6D2B79F5;let t=a;t=Math.imul(t^t>>>15,t|1);t^=t+Math.imul(t^t>>>7,t|61);return ((t^t>>>14)>>>0)/4294967296};
}
function permutation(n,seed){
 const rng=hashSeed(seed),indices=Array.from({length:n},(_,i)=>i);
 for(let i=n-1;i>0;i--){let j=Math.floor(rng()*(i+1));[indices[i],indices[j]]=[indices[j],indices[i]];}
 return indices;
}
function freezeStage({batch,uuidForPair,seed}){
 assert(batch?.staged===true&&Array.isArray(batch.pairs),'Verified generated batch required');
 assert(batch.pairs.length>=1&&batch.pairs.length<=30,'Batch must contain 1–30 pairs');
 assert(typeof uuidForPair==='function'&&seed!=null,'Trusted UUID allocator and seed required');
 const count=batch.pairs.length,orderA=permutation(count,seed+'-A'),orderB=permutation(count,seed+'-B');
 const seqA=new Map(orderA.map((index,order)=>[index,order+1]));
 const seqB=new Map(orderB.map((index,order)=>[index,order+1]));
 const rows=batch.pairs.map((p,i)=>({
   id:uuidForPair(i),pair_index:i+1,sampling_mode:p.mode,
   a_longitude:p.A[0],a_latitude:p.A[1],
   b_longitude:p.B[0],b_latitude:p.B[1],
   maximum_separation_meters:p.maximumSeparationMeters,
   sequence_a:seqA.get(i),sequence_b:seqB.get(i)
 }));
 assert(new Set(rows.map(r=>r.id)).size===count,'Stage pair IDs must be unique');
 return {batchIndex:batch.batchIndex,seed:String(seed),adaptivePercent:batch.adaptivePercent,
   rows,frozen:true};
}
module.exports={freezeStage,permutation};
