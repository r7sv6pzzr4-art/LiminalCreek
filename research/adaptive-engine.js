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
  const groups=new Map();
  for(const o of observations){
    const d=distance(candidate,o.point);
    if(d>750)continue;
    const w=Math.exp(-0.5*(d/190)**2);
    total+=w;high+=w*o.intensity;quiet+=w*(1-o.intensity);
    if(o.intensity>=0.75)closestStrong=Math.min(closestStrong,d);
    if(o.intensity<=0.25)closestQuiet=Math.min(closestQuiet,d);
    const k=o.participant||'?';
    const prev=groups.get(k)||{w:0,sum:0};
    prev.w+=w;prev.sum+=w*o.intensity;groups.set(k,prev);
    low+=w*(o.intensity<=0.25?1:0);
  }
  const interest=total?high/total:0;
  const neutral=total?quiet/total:0;
  const support=1-Math.exp(-total/2);
  const means=[...groups.values()].filter(g=>g.w>0.25).map(g=>g.sum/g.w);
  const disagreement=means.length>=2?Math.abs(means[0]-means[1]):0;
  const mixed=total?Math.min(high,low)/total:0;
  // Prefer the periphery of strong responses, not their precise centers.
  const peripheral=Number.isFinite(closestStrong)
    ?Math.exp(-0.5*((closestStrong-85)/65)**2):0;
  return {interest,neutral,support,disagreement,mixed,peripheral,
    closestStrong,closestQuiet,localWeight:total};
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
  const anchorOrder=shuffled(observations,rng);
  for(const o of anchorOrder){
    for(let i=0;i<30;i++){
      const metres=25+225*Math.sqrt(rng());
      accept(offset(o.point,2*Math.PI*rng(),metres));
    }
  }
  assert(pool.length>=count,'Insufficient eligible candidate sites for batch');
  return pool;
}
function priority(mode,site){
  const e=site.evidence;
  if(mode==='interesting')return 0.08+1.7*e.peripheral*(0.25+e.interest)+0.2*e.interest;
  if(mode==='uncertain')return 0.1+0.9*(1-e.support)*Math.min(1,e.localWeight+0.3)
    +0.7*e.mixed+0.7*e.disagreement;
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
    seed,maxSeparationMeters=60.96,modes=DEFAULT_MODES}=options||{};
  assert(Number.isInteger(count)&&count>0&&count<=100,'count must be 1–100');
  assert(Array.isArray(bounds)&&bounds.length===4&&bounds.every(Number.isFinite)
    &&bounds[2]>bounds[0]&&bounds[3]>bounds[1],'Invalid bounds');
  assert(typeof eligible==='function','eligible(point) must be provided by trusted caller');
  assert(typeof seed==='string'||Number.isInteger(seed),'Provide a fixed audit seed');
  assert(Number.isInteger(batchIndex)&&batchIndex>=1,'batchIndex must be positive');
  assert(maxSeparationMeters>0&&maxSeparationMeters<=60.96,'Maximum separation must be at most 200 ft');
  assert(Object.keys(modes).length===4 &&
    ['interesting','uncertain','quiet','broad'].every(m=>Number.isFinite(modes[m])&&modes[m]>=0)
    &&Math.abs(Object.values(modes).reduce((a,b)=>a+b,0)-1)<1e-8,'Invalid mode weights');
  const obs=normalizedObservations(observations);
  const used=previousPoints(existingPairs);
  const rng=rngFor(seed);
  const pool=buildPool({bounds,eligible,observations:obs,existingPoints:used,count,rng});
  const output=[], slots=shuffled(modeCounts(count,modes)
    .flatMap(({mode,count:n})=>Array(n).fill(mode)),rng);
  for(let j=0;j<slots.length;j++){
    const mode=slots[j];
    let chosen=null,best=-Infinity;
    for(const item of pool){
      if(item.taken)continue;
      const minUsed=used.length?Math.min(...used.map(p=>distance(item.point,p))):Infinity;
      if(minUsed<12)continue;
      const minNew=output.length?Math.min(...output.map(p=>distance(item.point,p.A))):Infinity;
      if(minNew<25)continue;
      // Broad sites are spatial controls: prefer novel, well-spaced coverage.
      const spread=Math.min(1,(Math.min(minUsed,minNew))/240);
      const score=mode==='broad'?spread+0.3*rng():
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
  return {version:1,batchIndex,seed:String(seed),count:output.length,
    modes:{...modes},pairs:output,
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
const api={generateBatch,recommendExtension,distance,DEFAULT_MODES};
if(typeof module!=='undefined'&&module.exports)module.exports=api;
