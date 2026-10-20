/* Spatially balanced, reproducible study-point generator (prototype).
 * Candidate centers are drawn uniformly across eligible geographic area.
 * A randomized maximin selection improves coverage without making a grid.
 * Each companion point is sampled within the exact maximum geodesic separation.
 */
window.LiminalSampling=(()=>{
const R=6371008.8, rad=Math.PI/180;
function dist(a,b){const x=(b[0]-a[0])*rad*Math.cos((a[1]+b[1])*rad/2),y=(b[1]-a[1])*rad;return R*Math.hypot(x,y)}
function companion(a,maxMeters,eligible){
 if(maxMeters===0)return eligible(a)?a.slice():null;
 for(let k=0;k<250;k++){
  const angle=Math.random()*Math.PI*2,metres=maxMeters*Math.sqrt(Math.random());
  const lat=a[1]+metres*Math.sin(angle)/(R*rad);
  const lng=a[0]+metres*Math.cos(angle)/(R*rad*Math.cos((a[1]+lat)*rad/2));
  const b=[lng,lat];
  if(eligible(b)&&dist(a,b)<=maxMeters+0.001)return b;
 }
 return null;
}
function generate({count,bounds,eligible,maxSeparationMeters,report}){
 const [w,s,e,n]=bounds,latMid=(s+n)/2,cos=Math.cos(latMid*rad);
 if(!Number.isFinite(cos)||cos<=0||e<=w||n<=s)throw Error('Invalid area bounds.');
 const candidates=[],target=Math.min(20000,Math.max(800,count*14)),attempts=Math.max(50000,target*60);
 for(let k=0;k<attempts&&candidates.length<target;k++){
  const lat=s+Math.random()*(n-s),lng=w+Math.random()*(e-w);
  if(Math.random()>Math.cos(lat*rad)/cos*0.999)continue;
  const a=[lng,lat];if(!eligible(a))continue;
  const b=companion(a,maxSeparationMeters,eligible);if(!b)continue;
  candidates.push({A:a,B:b,nearest:Infinity});
 }
 if(!candidates.length)throw Error('No eligible pairs found. Check polygons and separation setting.');
 const chosen=[],used=new Set();
 for(let i=0;i<Math.min(count,candidates.length);i++){
  let best=-1,score=-Infinity;
  // Randomized maximin candidate selection with a small candidate shortlist.
  // Every unused candidate remains eligible; a random fraction is considered per step.
  const draw=Math.min(candidates.length,Math.max(45,Math.min(250,Math.ceil(candidates.length*.045))));
  for(let j=0;j<draw;j++){
   let idx=Math.floor(Math.random()*candidates.length);
   if(used.has(idx))continue;
   const c=candidates[idx],val=i===0?Math.random():c.nearest*(.86+.28*Math.random());
   if(val>score){score=val;best=idx}
  }
  if(best<0){best=candidates.findIndex((_,idx)=>!used.has(idx));if(best<0)break}
  used.add(best);const choice=candidates[best];chosen.push({id:i+1,A:choice.A,B:choice.B});
  for(let k=0;k<candidates.length;k++){
   if(used.has(k))continue;
   const c=candidates[k],d=dist(c.A,choice.A);if(d<c.nearest)c.nearest=d;
  }
 }
 if(report)report({candidateCount:candidates.length,selected:chosen.length});
 return chosen;
}
return {generate,distanceMeters:dist};
})();