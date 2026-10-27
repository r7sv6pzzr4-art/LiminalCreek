/*
 * LiminalCreek / adaptive sampling — DRAFT, INACTIVE.
 *
 * Pure, deterministic planning library. This module is intentionally NOT loaded
 * by index.html, and NEVER reads or writes Supabase. Run it only in a trusted
 * administrative environment, with private observations supplied by the server.
 *
 * Inputs use [longitude, latitude] coordinates; lengths are in metres.
 */
'use strict';

const EARTH=6371008.8, RAD=Math.PI/180;
const DEFAULT_MODES=Object.freeze({
  interesting:0.35, uncertain:0.25, quiet:0.15, broad:0.25
});

function assert(ok,message){if(!ok)throw new Error(message)}
// Within the adaptive portion, retain all three investigative modes.
const ADAPTIVE_SUBMODES=Object.freeze({interesting:0.47,uncertain:0.33,quiet:0.20});
function modesForPercentage(adaptivePercent){
  assert(Number.isInteger(adaptivePercent)&&adaptivePercent>=0&&adaptivePercent<=100,
    'Adaptive percentage must be a whole number from 0 to 100');
  const fraction=adaptivePercent/100;
  return Object.freeze({
    interesting:fraction*ADAPTIVE_SUBMODES.interesting,
    uncertain:fraction*ADAPTIVE_SUBMODES.uncertain,
    quiet:fraction*ADAPTIVE_SUBMODES.quiet,
    broad:1-fraction
  });
}

function distance(a,b){
  const x=(b[0]-a[0])*RAD*Math.cos((a[1]+b[1])*RAD/2);
  const y=(b[1]-a[1])*RAD;
  return EARTH*Math.hypot(x,y);
}
function offset(point,bearing,metres){
  const lat=point[1]+metres*Math.sin(bearing)/(EARTH*RAD);
  const lon=point[0]+metres*Math.cos(bearing)/(EARTH*RAD*Math.cos((point[1]+lat)*RAD/2));
  return [lon,lat];
}
function seedNumber(seed){
  const s=String(seed);let h=2166136261;
  for(let i=0;i<s.length;i++){h=Math.imul(h^s.charCodeAt(i),16777619)}
  return h>>>0;
}
function rngFor(seed){
  let t=seedNumber(seed);
  return ()=>{t+=0x6D2B79F5;let x=t;x=Math.imul(x^x>>>15,x|1);
    x^=x+Math.imul(x^x>>>7,x|61);return ((x^x>>>14)>>>0)/4294967296};
}
function shuffled(items,rng){
  const out=items.slice();for(let i=out.length-1;i>0;i--){
    const j=Math.floor(rng()*(i+1));[out[i],out[j]]=[out[j],out[i]];
  }return out;
}
function validPoint(p){return Array.isArray(p)&&p.length===2&&p.every(Number.isFinite)&&Math.abs(p[0])<=180&&Math.abs(p[1])<=90}
function responseStrength(obs){
  if(obs.valence==='neutral')return 0;
  const x=Number(obs.strength);
  assert(Number.isInteger(x)&&x>=1&&x<=4,'Nonneutral response strength must be 1–4');
  return x/4;
}
function normalizedObservations(observations){
  assert(Array.isArray(observations),'observations must be an array');
  return observations.map((o,i)=>{
    assert(validPoint(o.point),'Invalid response point at index '+i);
    assert(['good','bad','mixed','neutral'].includes(o.valence),'Invalid valence');
    return {point:o.point.slice(),intensity:responseStrength(o),participant:String(o.participant||''),
      pairId:o.pairId==null?null:String(o.pairId),valence:o.valence};
  });
}
function previousPoints(pairs){
  assert(Array.isArray(pairs),'existingPairs must be an array');
  const points=[];
  for(const p of pairs){
    const a=p.A||p.a, b=p.B||p.b;
    assert(validPoint(a)&&validPoint(b),'Each previous pair requires A and B coordinates');
    points.push(a,b);
  }
  return points;
}
function siteEvidence(candidate,observations){
  // Intentionally descriptive, not a probability of paranormal phenomena.
  // Local kernels give strong and neutral observations comparable opportunity
  // to influence additional sampling.
  let total=0,high=0,quiet=0,low=0;
  let closestStrong=Infinity,closestQuiet=Infinity;
  let localStrong=0,localSites=0;
  const pairs=new Map();
  for(const o of observations){
    const d=distance(candidate,o.point);
    if(d>750)continue;
    const w=Math.exp(-0.5*(d/190)**2);
    total+=w;high+=w*o.intensity;quiet+=w*(1-o.intensity);
    if(o.intensity>=0.75)closestStrong=Math.min(closestStrong,d);
    if(o.intensity<=0.25)closestQuiet=Math.min(closestQuiet,d);
    // A strong response at one location must not be erased by many distant
    // neutral responses inside the much broader 190 m neighborhood.
    localStrong=Math.max(localStrong,o.intensity*Math.exp(-0.5*(d/65)**2));
    if(d<=85)localSites++;
    if(o.pairId!=null&&d<=145){
     if(!pairs.has(o.pairId))pairs.set(o.pairId,[]);
     pairs.get(o.pairId).push(o);
    }
    low+=w*(o.intensity<=0.25?1:0);
  }
  const interest=total?high/total:0;
  const neutral=total?quiet/total:0;
  const support=1-Math.exp(-total/2);
  // "Uncertainty" uses nearby matched-pair contrasts, not differences
  // between smoothed observer averages from geographically separated sites.
  // Because the two sites are offset, contrast can reflect a true local
  // gradient; do NOT label it proof of disagreement between people.
  let pairedContrast=0;
  for(const pair of pairs.values()){
   if(pair.length<2||pair[0].participant===pair[1].participant)continue;
   if(distance(pair[0].point,pair[1].point)>60.97)continue;
   const midpoint=[(pair[0].point[0]+pair[1].point[0])/2,
                   (pair[0].point[1]+pair[1].point[1])/2];
   pairedContrast=Math.max(pairedContrast,Math.abs(pair[0].intensity-pair[1].intensity)
     *Math.exp(-0.5*(distance(candidate,midpoint)/90)**2));
  }
  const mixed=total?Math.min(high,low)/total:0;
  // Prefer the periphery of strong responses, not their precise centers.
  const peripheral=Number.isFinite(closestStrong)
    ?Math.exp(-0.5*((closestStrong-85)/65)**2):0;
  return {interest,neutral,support,pairedContrast,localStrong,localSites,
    mixed,peripheral,closestStrong,closestQuiet,localWeight:total};
}
function pointInBounds(point,bounds){
  return point[0]>=bounds[0]&&point[0]<=bounds[2]&&point[1]>=bounds[1]&&point[1]<=bounds[3];
}
function randomInBounds(bounds,rng){
  const [w,s,e,n]=bounds;
  // Area-correct enough for this small midlatitude geographic footprint:
  // rejection weighting by cos(latitude).
  const cosMax=Math.cos(Math.min(Math.abs(s),Math.abs(n))*RAD);
  for(let i=0;i<30;i++){
    const lat=s+(n-s)*rng(),lng=w+(e-w)*rng();
    if(rng()*cosMax<=Math.cos(lat*RAD))return [lng,lat];
  }
  return [w+(e-w)*rng(),s+(n-s)*rng()];
}
function buildPool({bounds,eligible,observations,existingPoints,count,rng}){
  const pool=[], target=Math.max(1100,count*110);
  const accept=point=>{
    if(!validPoint(point)||!pointInBounds(point,bounds)||!eligible(point))return;
    if(existingPoints.some(p=>distance(p,point)<12))return;
    pool.push({point, evidence:siteEvidence(point,observations)});
  };
  for(let i=0;i<target*35&&pool.length<target;i++)accept(randomInBounds(bounds,rng));
  // Seed additional proposals around observations to avoid missing a tiny
  // hotspot in a very large eligible landscape.
  const anchorOrder=shuffled(observations.filter(o=>o.intensity>=.75),rng);
  for(const o of anchorOrder){
    for(let i=0;i<18;i++){
      const metres=15+115*Math.sqrt(rng());
      accept(offset(o.point,2*Math.PI*rng(),metres));
    }
  }
  assert(pool.length>=count,'Insufficient eligible candidate sites for batch');
  return pool;
}
function priority(mode,site){
  const e=site.evidence;
  if(mode==='interesting')return 0.08+1.5*e.peripheral*(0.25+e.interest)
    +1.2*e.localStrong+0.18*e.interest;
  if(mode==='uncertain')return 0.1+0.8*(1-e.support)*Math.min(1,e.localWeight+0.3)
    +0.5*e.mixed+0.95*e.pairedContrast
    +0.25*e.localStrong*(e.localSites<=1?1:0);
  if(mode==='quiet')return 0.08+1.1*e.neutral*e.support
    *(1-Math.min(1,e.interest))+(Number.isFinite(e.closestQuiet)?0.25:0);
  return 1;
}
function modeCounts(count,modes){
  const list=Object.entries(modes).map(([mode,fraction])=>({mode,
    count:Math.floor(count*fraction),remainder:count*fraction-Math.floor(count*fraction)}));
  let leftover=count-list.reduce((a,b)=>a+b.count,0);
  for(const x of list.slice().sort((a,b)=>b.remainder-a.remainder)){
    if(leftover--<=0)break;
    list.find(z=>z.mode===x.mode).count++;
  }
  return list;
}
function companion(point,maxMeters,eligible,rng){
  // Choose a location within the eligible region; never relax containment.
  for(let i=0;i<350;i++){
    const metres=Math.sqrt(rng())*maxMeters;
    const p=offset(point,rng()*Math.PI*2,metres);
    if(eligible(p)&&distance(p,point)<=maxMeters+0.01)return p;
  }
  return null;
}
function separationFor(mode,evidence,maxMeters){
  // Broad and quiet locations retain the original maximum separation.
  // Fine-scale follow-up can tighten pairs without forcing co-location.
  if(mode==='broad'||mode==='quiet')return maxMeters;
  if(mode==='uncertain')return Math.min(maxMeters,40);
  if(evidence.interest>0.5)return Math.min(maxMeters,24);
  return Math.min(maxMeters,40);
}
function generateBatch(options){
  const {count,bounds,eligible,observations=[],existingPairs=[],batchIndex=1,
    seed,maxSeparationMeters=60.96,modes,adaptivePercent}=options||{};
  assert(modes===undefined||adaptivePercent===undefined,
    'Specify either adaptivePercent or explicit modes, not both');
  const effectiveModes=adaptivePercent===undefined?(modes||DEFAULT_MODES):modesForPercentage(adaptivePercent);
  assert(Number.isInteger(count)&&count>0&&count<=100,'count must be 1–100');
  assert(Array.isArray(bounds)&&bounds.length===4&&bounds.every(Number.isFinite)
    &&bounds[2]>bounds[0]&&bounds[3]>bounds[1],'Invalid bounds');
  assert(typeof eligible==='function','eligible(point) must be provided by trusted caller');
  assert(typeof seed==='string'||Number.isInteger(seed),'Provide a fixed audit seed');
  assert(Number.isInteger(batchIndex)&&batchIndex>=1,'batchIndex must be positive');
  assert(maxSeparationMeters>0&&maxSeparationMeters<=60.96,'Maximum separation must be at most 200 ft');
  assert(Object.keys(effectiveModes).length===4 &&
    ['interesting','uncertain','quiet','broad'].every(m=>Number.isFinite(effectiveModes[m])&&effectiveModes[m]>=0)
    &&Math.abs(Object.values(effectiveModes).reduce((a,b)=>a+b,0)-1)<1e-8,'Invalid mode weights');
  const obs=normalizedObservations(observations);
  const used=previousPoints(existingPairs);
  // Generate all broad/coverage-control locations BEFORE response-informed
  // locations, from a completely independent candidate pool and RNG.
  // For the same prior assignment geometry and seed, broad sites therefore
  // cannot move when an observation's valence or intensity changes.
  const broadRng=rngFor(String(seed)+'-coverage');
  const adaptiveRng=rngFor(String(seed)+'-adaptive');
  const totals=modeCounts(count,effectiveModes);
  const broadCount=totals.find(x=>x.mode==='broad').count;
  const controlPool=broadCount?buildPool({
    bounds,eligible,observations:[],existingPoints:used,count,rng:broadRng}):[];
  const adaptivePool=broadCount<count?buildPool({
    bounds,eligible,observations:obs,existingPoints:used,count,rng:adaptiveRng}):[];
  const adaptiveSlots=shuffled(totals.filter(x=>x.mode!=='broad')
    .flatMap(({mode,count:n})=>Array(n).fill(mode)),adaptiveRng);
  const slots=[...Array(broadCount).fill('broad'),...adaptiveSlots];
  const output=[];
  for(let j=0;j<slots.length;j++){
    const mode=slots[j],isControl=mode==='broad';
    const pool=isControl?controlPool:adaptivePool;
    const rng=isControl?broadRng:adaptiveRng;
    let chosen=null,best=-Infinity;
    for(const item of pool){
      if(item.taken)continue;
      const minUsed=used.length?Math.min(...used.map(p=>distance(item.point,p))):Infinity;
      if(minUsed<12)continue;
      const minNew=output.length?Math.min(...output.map(p=>distance(item.point,p.A))):Infinity;
      if(minNew<25)continue;
      // Broad sites are spatial controls: prefer novel, well-spaced coverage.
      const gapDistance=Math.min(minUsed,minNew);
      const spread=Math.min(1,gapDistance/240);
      // Coverage-directed controls are RESPONSE-BLIND, not uniformly random.
      // Do not cap the hole score at 240 m: larger unsampled gaps should
      // remain distinguishable. Random jitter avoids rigid grids.
      const score=isControl?Math.log1p(Math.min(gapDistance,2000)/90)+0.10*rng():
        priority(mode,item)*(0.45+0.55*spread)*(0.88+0.24*rng());
      if(score>best){best=score;chosen=item;}
    }
    assert(chosen,'Could not select a distinct location for all requested pairs');
    const maxDist=separationFor(mode,chosen.evidence,maxSeparationMeters);
    const b=companion(chosen.point,maxDist,eligible,rng);
    assert(b,'Could not generate an eligible companion within separation limit');
    chosen.taken=true;
    output.push({id:'adaptive-'+batchIndex+'-'+(j+1),batchIndex,mode,
      A:chosen.point.slice(),B:b,maximumSeparationMeters:maxDist});
    used.push(chosen.point,b);
  }
  // Interleave controls with response-informed sites in a deterministic
  // private order. Selection was separated to protect controls from bias.
  const pairs=shuffled(output,rngFor(String(seed)+'-presentation'))
    .map((p,i)=>({...p,id:'adaptive-'+batchIndex+'-'+(i+1)}));
  return {version:2,batchIndex,seed:String(seed),count:pairs.length,
    modes:{...effectiveModes},adaptivePercent:adaptivePercent??null,pairs,
    // A trusted staging service persists these rows atomically and permanently.
    // Never overwrite a staged batch or write to the live assignments table here.
    staged:true};
}
function recommendExtension({observations,remainingPairs=0,maxAdditional=100}){
  const obs=normalizedObservations(observations);
  const strong=obs.filter(o=>o.intensity>=0.75);
  const clusters=[];
  for(const o of strong){
    const same=clusters.find(c=>c.some(p=>distance(o.point,p.point)<250));
    if(same)same.push(o);else clusters.push([o]);
  }
  // Planning heuristic, explicitly NOT a statistical stopping rule.
  // Re-assess after each frozen batch and do not silently raise the study target.
  const estimated=clusters.length*12 + Math.ceil(obs.length*0.12)+25;
  return {candidateRegions:clusters.length,preliminaryAdditionalPairs:
    Math.min(maxAdditional,Math.max(0,estimated-remainingPairs)),
    status:'planning-estimate-only',
    caveat:'A final study target and plan closure require explicit administrative approval.'};
}
const api={generateBatch,recommendExtension,distance,DEFAULT_MODES,modesForPercentage};
if(typeof module!=='undefined'&&module.exports)module.exports=api;
