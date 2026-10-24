/*
 * LiminalCreek personal mapping / reveal gate — DRAFT, INACTIVE.
 * This pure planning code never queries Supabase or modifies study state.
 * Only supply the authenticated individual's OWN original observations.
 */
'use strict';
const EARTH=6371008.8,RAD=Math.PI/180;
function assert(ok,msg){if(!ok)throw Error(msg)}
function distance(a,b){
  return EARTH*Math.hypot((a[0]-b[0])*RAD*Math.cos((a[1]+b[1])*RAD/2),
    (a[1]-b[1])*RAD);
}
function pointNear(p,angle,metres){
  const lat=p[1]+Math.sin(angle)*metres/(EARTH*RAD);
  return [p[0]+Math.cos(angle)*metres/(EARTH*RAD*Math.cos((p[1]+lat)*RAD/2)),lat];
}
function random(seed){
  let h=2166136261;for(const c of String(seed))h=Math.imul(h^c.charCodeAt(0),16777619);
  return ()=>{h+=0x6D2B79F5;let z=h;z=Math.imul(z^z>>>15,z|1);z^=z+Math.imul(z^z>>>7,z|61);return ((z^z>>>14)>>>0)/4294967296;};
}
function shuffle(values,rng){
  const a=values.slice();for(let i=a.length-1;i>0;i--){let j=Math.floor(rng()*(i+1));[a[i],a[j]]=[a[j],a[i]];}
  return a;
}
function summarizePersonalRegions({observations,eligible,seed,sitesPerRegion=8,
  maxRegions=4,minimumSpacingMeters=20}){
  assert(Array.isArray(observations)&&typeof eligible==='function','Private observations and eligible predicate required');
  assert(seed!=null,'A reproducible seed is required');
  assert(Number.isInteger(sitesPerRegion)&&sitesPerRegion>=1&&sitesPerRegion<=40,'Invalid site count');
  const rng=random(seed),strong=[];
  for(const o of observations){
    assert(Array.isArray(o.point)&&o.point.length===2&&o.point.every(Number.isFinite),'Invalid observation point');
    if(o.valence==='neutral')continue;
    const strength=Number(o.strength);
    if(strength>=3&&strength<=4)strong.push(o);
  }
  // Form candidate regions from the individual's own strong impressions.
  // Singletons can be candidates: one strong response is never "confirmed".
  const clusters=[];
  for(const o of strong){
    const connections=clusters.filter(c=>c.some(p=>distance(o.point,p.point)<=230));
    if(!connections.length){clusters.push([o]);continue;}
    const merged=connections.flat();merged.push(o);
    for(const c of connections){const idx=clusters.indexOf(c);if(idx>=0)clusters.splice(idx,1);}
    clusters.push(merged);
  }
  clusters.sort((a,b)=>b.length-a.length);
  const result=[], prior=observations.map(o=>o.point),generated=[];
  for(const group of clusters.slice(0,maxRegions)){
    const avg=[group.reduce((n,o)=>n+o.point[0],0)/group.length,
      group.reduce((n,o)=>n+o.point[1],0)/group.length];
    const jitter=pointNear(avg,2*Math.PI*rng(),70+70*rng());
    // Deliberately broad region that does not outline earlier responses.
    const span=Math.max(...group.map(o=>distance(avg,o.point)),0);
    const radius=Math.min(650,Math.max(180,span+140));
    const labels=new Map();
    for(const o of group){
      for(const label of Array.isArray(o.descriptions)?o.descriptions:[]){
        const trimmed=String(label).trim();
        if(trimmed&&trimmed.length<=250)labels.set(trimmed,(labels.get(trimmed)||0)+1);
      }
    }
    const feelings=shuffle([...labels].sort((a,b)=>b[1]-a[1]).slice(0,3).map(([k])=>k),rng);
    const sites=[];
    for(let i=0;i<sitesPerRegion;i++){
      let chosen=null;
      for(let attempt=0;attempt<1500;attempt++){
        const d=radius*Math.sqrt(rng());
        const p=pointNear(jitter,rng()*Math.PI*2,d);
        if(!eligible(p))continue;
        if(prior.some(z=>distance(z,p)<minimumSpacingMeters))continue;
        if(generated.some(z=>distance(z,p)<minimumSpacingMeters))continue;
        chosen=p;break;
      }
      if(!chosen)break;
      generated.push(chosen);
      sites.push({id:'personal-'+(result.length+1)+'-'+(i+1),point:chosen});
    }
    if(sites.length){
      result.push({id:'region-'+(result.length+1),approximateArea:{
        // Rounded center avoids sharing an earlier exact study coordinate.
        center:jitter.map(v=>Math.round(v*1000)/1000),radiusMeters:radius
      },suggestedFeelings:feelings,sites});
    }
  }
  return {version:1,seed:String(seed),regions:result,
    // Contains no source observations, original scores, timestamps, notes,
    // original point coordinates, or other participant's information.
    personal:true};
}
function addFeeling(current,newLabel){
  assert(Array.isArray(current),'current labels required');
  const label=String(newLabel||'').trim().replace(/\s+/g,' ');
  assert(label.length>=2&&label.length<=120,'Describe a new feeling in 2–120 characters');
  const matching=current.find(s=>s.toLocaleLowerCase()===label.toLocaleLowerCase());
  return {labels:matching?current.slice():current.concat(label),selected:matching||label};
}
/*
 * Personal-study responses are purely comparative. Original 1–4 strengths
 * are used only upstream to identify candidate regions, NEVER as intensity
 * priors, ranks, weights, or training labels in this phase.
 */
const COMPARISON_CHOICES=Object.freeze([
  'A','B','equal','neither','different'
]);
function validateComparisonAnswer({feeling,choice,note=''},{allowedFeelings=[]}={}){
  assert(allowedFeelings.includes(feeling),'Choose one of the listed or newly added feelings');
  assert(COMPARISON_CHOICES.includes(choice),'Invalid comparison answer');
  assert(typeof note==='string'&&note.length<=4000,'Invalid note');
  return {feeling,choice,note};
}
function createRelativeQuestion({region,referencePoints,eligible,seed,
  previousComparisons=[],minimumSpacingMeters=20}){
  assert(region&&region.approximateArea&&Array.isArray(region.suggestedFeelings),
    'A personal region is required');
  assert(Array.isArray(referencePoints)&&referencePoints.length>0,
    'Private reference coordinates are required');
  assert(Array.isArray(previousComparisons),'Comparisons must be an array');
  assert(typeof eligible==='function'&&seed!=null,'Eligibility and fixed seed required');
  const rng=random(seed),feelingList=region.suggestedFeelings;
  assert(feelingList.length>0,'At least one feeling is required');
  // Select category without using original response intensity or counts.
  const feeling=feelingList[Math.floor(rng()*feelingList.length)];
  // Reference coordinates are supplied by the private backend; the output
  // NEVER labels the original versus newly proposed site.
  const references=referencePoints.filter(p=>Array.isArray(p)&&p.length===2&&p.every(Number.isFinite));
  assert(references.length>0,'No valid reference point');
  const reference=references[Math.floor(rng()*references.length)];
  const {center,radiusMeters}=region.approximateArea;
  assert(Array.isArray(center)&&center.length===2&&Number.isFinite(radiusMeters),
    'Invalid approximate exploration region');
  const already=previousComparisons.flatMap(c=>[c.pointA,c.pointB].filter(Boolean));
  let newPoint=null;
  for(let i=0;i<1800;i++){
    // Use only the previous *relative comparisons* to shift proposals toward
    // earlier comparison areas. Original 1–4 strength scores are excluded.
    const anchors=previousComparisons.length?
      previousComparisons.flatMap(c=>[c.pointA,c.pointB].filter(Boolean)): [];
    const focus=anchors.length&&rng()<0.6?anchors[Math.floor(rng()*anchors.length)]:center;
    const travel=focus===center?radiusMeters*Math.sqrt(rng()):25+95*Math.sqrt(rng());
    const candidate=pointNear(focus,2*Math.PI*rng(),travel);
    if(distance(candidate,center)>radiusMeters||!eligible(candidate))continue;
    if(distance(candidate,reference)<minimumSpacingMeters)continue;
    if(referencePoints.some(p=>distance(candidate,p)<minimumSpacingMeters))continue;
    if(already.some(p=>distance(candidate,p)<minimumSpacingMeters))continue;
    newPoint=candidate;break;
  }
  assert(newPoint,'Could not find a new eligible comparison site');
  const referenceIsA=rng()<0.5;
  return {version:2,context:'This area may be associated with the following feeling: '+feeling+'.',
    question:'At which location is this feeling stronger?',
    feeling,pointA:referenceIsA?reference.slice():newPoint,
    pointB:referenceIsA?newPoint:reference.slice(),
    choices:COMPARISON_CHOICES.slice(),
    // This client-facing shape deliberately omits source, history,
    // original descriptions, original strength, and original comments.
    personal:true};
}
function canReleaseResults({study,participants,actingUserId}){
  // Pure UI/server validation helper, not an authorization mechanism by itself.
  // The eventual Supabase RPC must repeat these checks in a transaction.
  if(!study||study.samplingPlanClosed!==true||study.revealedAt!=null)return false;
  if(!Array.isArray(participants)||participants.length!==2)return false;
  if(!participants.some(p=>p.userId===actingUserId&&p.isAdmin===true))return false;
  if(!Number.isInteger(study.finalPairCount)||study.finalPairCount<100)return false;
  return participants.every(p=>p.completedSharedPairs>=study.finalPairCount &&
    ['completed','skipped'].includes(p.personalStatus));
}
const api={summarizePersonalRegions,addFeeling,validateComparisonAnswer,createRelativeQuestion,canReleaseResults};
if(typeof module!=='undefined'&&module.exports)module.exports=api;
