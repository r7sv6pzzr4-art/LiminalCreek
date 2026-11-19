/* LiminalCreek coverage assessment and phase schedule — INACTIVE DRAFT.
 * Pure, deterministic and RESPONSE-BLIND: supply only eligible geometry and
 * allocated paired coordinates. Runs in a trusted environment, never the
 * participant browser. Do not publish coordinates from live assignments.
 */
'use strict';
const R=6371008.8,RAD=Math.PI/180;
function assert(value,msg){if(!value)throw Error(msg)}
function dist(a,b){
 const x=(b[0]-a[0])*RAD*Math.cos((a[1]+b[1])*RAD/2),y=(b[1]-a[1])*RAD;
 return R*Math.hypot(x,y);
}
function rngFor(seed){
 let h=2166136261;for(const c of String(seed))h=Math.imul(h^c.charCodeAt(0),16777619);
 return ()=>{h+=0x6D2B79F5;let t=h;t=Math.imul(t^t>>>15,t|1);
  t^=t+Math.imul(t^t>>>7,t|61);return ((t^t>>>14)>>>0)/4294967296;};
}
function nearest(point,sites){
 let smallest=Infinity;for(const p of sites)smallest=Math.min(smallest,dist(point,p));
 return smallest;
}
function quantile(sorted,p){if(!sorted.length)return null;
 const i=(sorted.length-1)*p,a=Math.floor(i),b=Math.ceil(i);
 return sorted[a]+(sorted[b]-sorted[a])*(i-a);
}
function summary(distances,radii){
 const sorted=distances.slice().sort((a,b)=>a-b);
 return {medianMeters:quantile(sorted,.5),p90Meters:quantile(sorted,.9),
  p95Meters:quantile(sorted,.95),maxSampledMeters:sorted.at(-1),
  estimatedFractionBeyondMeters:Object.fromEntries(radii.map(r=>[r,
   sorted.filter(d=>d>r).length/sorted.length]))};
}
function auditCoverage({bounds,eligible,existingPairs,seed='coverage-baseline',
 sampleCount=2500,radiiMeters=[50,100,150,200],maxHoleCandidates=12}={}){
 assert(Array.isArray(bounds)&&bounds.length===4&&bounds.every(Number.isFinite)
  &&bounds[0]<bounds[2]&&bounds[1]<bounds[3],'Valid lon/lat bounding box required');
 assert(typeof eligible==='function','An eligible point-in-polygon predicate is required');
 assert(Array.isArray(existingPairs)&&existingPairs.length>0,
  'Paired assignment inventory required; not response records');
 assert(Number.isInteger(sampleCount)&&sampleCount>=100&&sampleCount<=20000,
  'Invalid diagnostic sample count');
 assert(Array.isArray(radiiMeters)&&radiiMeters.length>0&&
  radiiMeters.every(v=>Number.isFinite(v)&&v>0),'Invalid radii');
 const valid=p=>Array.isArray(p)&&p.length===2&&p.every(Number.isFinite)&&
  p[0]>=bounds[0]&&p[0]<=bounds[2]&&p[1]>=bounds[1]&&p[1]<=bounds[3]&&eligible(p);
 const A=[],B=[];
 for(const pair of existingPairs){
  const a=pair.A||pair.a,b=pair.B||pair.b;
  assert(valid(a)&&valid(b),'Assigned point outside eligible study area');
  A.push(a);B.push(b);
 }
 const union=[...A,...B],rng=rngFor(seed);
 const [w,s,e,n]=bounds,cosMax=Math.cos(Math.min(Math.abs(s),Math.abs(n))*RAD);
 const samples=[],limit=sampleCount*100;
 for(let i=0;i<limit&&samples.length<sampleCount;i++){
  const p=[w+(e-w)*rng(),s+(n-s)*rng()];
  if(rng()*cosMax>Math.cos(p[1]*RAD)||!eligible(p))continue;
  samples.push({point:p,both:nearest(p,union),A:nearest(p,A),B:nearest(p,B)});
 }
 assert(samples.length===sampleCount,'Cannot sample eligible geography sufficiently');
 // Approximate area fractions and distances, not an exact Voronoi computation.
 const gaps=[];
 for(const sample of samples.slice().sort((a,b)=>b.both-a.both)){
  if(gaps.length>=maxHoleCandidates)break;
  if(gaps.every(x=>dist(x.point,sample.point)>=80))
   gaps.push({point:sample.point,nearestCombinedMeters:sample.both,
    nearestParticipantAMeters:sample.A,nearestParticipantBMeters:sample.B});
 }
 return {method:'seeded-area-sampling',seed:String(seed),samples:sampleCount,
  assignedPairs:existingPairs.length,assignedPointsPerParticipant:existingPairs.length,
  combined:summary(samples.map(x=>x.both),radiiMeters),
  participantA:summary(samples.map(x=>x.A),radiiMeters),
  participantB:summary(samples.map(x=>x.B),radiiMeters),
  largestCoverageGaps:gaps,
  caveat:'Estimated from spatial samples of eligible polygons, including exclusions. Coverage describes assigned locations only, not observed intensity. Gap coordinates must remain private.'};
}
function phasePlan({releasedAdditionalPairs,approvedAdditionalPairs,batchSize=20,
 coverageRepairPairs=40,earlyAdaptivePercent=50,laterAdaptivePercent=75}={}){
 assert(Number.isInteger(releasedAdditionalPairs)&&releasedAdditionalPairs>=0,
  'Released additional pair count required');
 assert(Number.isInteger(approvedAdditionalPairs)&&approvedAdditionalPairs>=0,
  'Administrator-approved additional pair limit required');
 assert(releasedAdditionalPairs<=approvedAdditionalPairs,'Released pairs exceed approved cap');
 assert(Number.isInteger(batchSize)&&batchSize>=1&&batchSize<=30,'Invalid batch size');
 assert(Number.isInteger(coverageRepairPairs)&&coverageRepairPairs>=0,'Invalid coverage-repair phase');
 assert([earlyAdaptivePercent,laterAdaptivePercent].every(x=>Number.isInteger(x)&&x>=0&&x<=100),'Invalid adaptive percentage');
 const early=releasedAdditionalPairs<coverageRepairPairs;
 const remain=approvedAdditionalPairs-releasedAdditionalPairs;
 // Do not let a batch straddle the transition: every frozen batch has
 // one documented, immutable sampling mix.
 const phaseRoom=early?coverageRepairPairs-releasedAdditionalPairs:remain;
 const nextBatchPairs=Math.max(0,Math.min(batchSize,remain,phaseRoom));
 const adaptivePercent=early?earlyAdaptivePercent:laterAdaptivePercent;
 return {phase:early?'coverage-repair':'adaptive-refinement',
  adaptivePercent,coverageDirectedPercent:100-adaptivePercent,
  nextBatchPairs,originalPairsPreserved:100,
  status:nextBatchPairs?'proposal-only':'no-authorized-pairs-remaining',
  requiresTwoParticipantCompletion:true,
  caveat:'Only an administrator can authorize additions; staging and promotion remain separate, private, and transactional.'};
}
module.exports={auditCoverage,phasePlan,dist};
