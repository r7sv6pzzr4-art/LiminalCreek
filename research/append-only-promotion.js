/*
 * LiminalCreek / adaptive batch promotion proposal — INACTIVE.
 * This module ONLY builds candidate insert rows. It has no database access,
 * and must be called by an audited, transactional, trusted server process.
 */
'use strict';
function assert(ok,message){if(!ok)throw new Error(message)}
function random(seed){
  let a=2166136261;
  for(const c of String(seed))a=Math.imul(a^c.charCodeAt(0),16777619);
  return ()=>{a+=0x6D2B79F5;let t=a;t=Math.imul(t^t>>>15,t|1);
    t^=t+Math.imul(t^t>>>7,t|61);return ((t^t>>>14)>>>0)/4294967296};
}
function shuffle(array,seed){
  const rng=random(seed),a=array.slice();
  for(let i=a.length-1;i>0;i--){const j=Math.floor(rng()*(i+1));[a[j],a[i]]=[a[i],a[j]];}
  return a;
}
const EARTH=6371008.8,RAD=Math.PI/180;
function distance(a,b){return EARTH*Math.hypot(
  (a[0]-b[0])*RAD*Math.cos((a[1]+b[1])*RAD/2),(a[1]-b[1])*RAD);}
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function preparePromotion({studyId,participants,assignments,completedAssignmentIds,
  batch,seed,originalCount=100,alreadyReleasedBatchIds=[]}){
  assert(uuid.test(studyId),'A valid study UUID is required');
  assert(Array.isArray(participants)&&participants.length===2,'Exactly two participants required');
  const [aId,bId]=participants;
  assert(aId!==bId&&participants.every(id=>uuid.test(id)),'Distinct valid user UUIDs required');
  assert(Array.isArray(assignments),'Current assignment inventory required');
  assert(Array.isArray(completedAssignmentIds),'Completed assignment inventory required');
  assert(batch&&uuid.test(batch.id)&&Array.isArray(batch.pairs)&&batch.pairs.length>0,'Frozen staged batch required');
  assert(batch.state==='staged','Only staged batches may be promoted');
  assert(!alreadyReleasedBatchIds.includes(batch.id),'Batch already released');
  assert(seed!=null,'Reproducible participant shuffle seed is required');
  assert(originalCount===100,'The immutable initial cohort must be 100 pairs');
  const completed=new Set(completedAssignmentIds);
  const originalByUser={};
  const maxSeq={};
  for(const userId of participants){
    const own=assignments.filter(a=>a.user_id===userId&&a.study_id===studyId);
    const seqs=own.map(a=>a.sequence_no);
    assert(seqs.every(n=>Number.isInteger(n)&&n>=1),'Invalid sequence number');
    assert(new Set(seqs).size===seqs.length,'Duplicate sequence number');
    const base=own.filter(a=>a.sequence_no<=100);
    assert(base.length===100,'Original 100 assignments must exist unchanged');
    for(let i=1;i<=100;i++)assert(base.some(a=>a.sequence_no===i),'Original sequence incomplete');
    assert(base.every(a=>completed.has(a.id)),'Wait until both participants finish original 100');
    originalByUser[userId]=base;
    maxSeq[userId]=Math.max(...seqs);
  }
  const baseA=originalByUser[aId],baseB=originalByUser[bId];
  const pairSetA=new Set(baseA.map(p=>p.pair_id));
  const pairSetB=new Set(baseB.map(p=>p.pair_id));
  assert(pairSetA.size===100&&pairSetB.size===100&&
    [...pairSetA].every(id=>pairSetB.has(id)),'Original paired cohort is inconsistent');
  const usedPairs=new Set(assignments.map(a=>a.pair_id));
  assert(batch.pairs.every(p=>uuid.test(p.stagingId)&&!usedPairs.has(p.stagingId)),
    'Staged pair UUID missing or already present in assignments');
  assert(new Set(batch.pairs.map(p=>p.stagingId)).size===batch.pairs.length,
    'Duplicate staged pair identifier');
  for(const p of batch.pairs){
    assert(['interesting','uncertain','quiet','broad'].includes(p.mode),'Invalid sampling mode');
    assert([p.A,p.B].every(point=>Array.isArray(point)&&point.length===2&&
      point.every(Number.isFinite)&&point[0]>=-180&&point[0]<=180&&
      point[1]>=-90&&point[1]<=90),'Invalid staged paired coordinate');
    assert(distance(p.A,p.B)<=60.96+0.01 &&
      (!p.maximumSeparationMeters||distance(p.A,p.B)<=p.maximumSeparationMeters+0.01),
      'Staged pair exceeds the allowed separation');
  }
  const rows=[];
  for(const [role,userId] of [['A',aId],['B',bId]]){
    const planned=shuffle(batch.pairs,String(seed)+'-'+role);
    planned.forEach((p,index)=>rows.push({
      study_id:studyId,user_id:userId,pair_id:p.stagingId,
      longitude:p[role][0],latitude:p[role][1],
      sequence_no:maxSeq[userId]+index+1,sampling_type:'adaptive'
    }));
  }
  // Caller must atomically verify DB snapshot+batch state, insert exactly
  // rows.length assignments and mark batch released. NEVER rewrite old rows.
  return {batchId:batch.id,rows,appendOnly:true,expectedAssignmentCount:assignments.length};
}
module.exports={preparePromotion};
