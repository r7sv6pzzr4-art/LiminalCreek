require('./adaptive-sampling-engine.js');
/* Run with: node adaptive-sampling-engine.test.js
   Synthetic regression tests; never calls the active LiminalCreek study. */
'use strict';
const assert=(condition,message)=>{if(!condition)throw Error(message)};
const API=globalThis.LiminalAdaptive;
assert(API,'Engine must be loaded before tests');
let seed=27;const random=()=>((seed=(seed*1664525+1013904223)>>>0)/4294967296);
const area={type:'Polygon',coordinates:[[[-74.1678,40.347],[-74.1678,40.351],[-74.1625,40.351],[-74.1625,40.347],[-74.1678,40.347]]]};
const adapter=new API.PersonalAdapter(area,{random});
const hotspot=[-74.1653,40.3482],history=[],counts={};
for(let i=0;i<110;i++){
 const pair=adapter.propose(history,'creepy');
 const d=API.distance(pair.A,pair.B);
 assert(API.inside(pair.A,area)&&API.inside(pair.B,area),'Out-of-polygon point');
 assert(d>=16&&d<=152.400001,'Pair outside allowed distance range: '+d);
 const a=Math.exp(-.5*(API.distance(pair.A,hotspot)/60)**2);
 const b=Math.exp(-.5*(API.distance(pair.B,hotspot)/60)**2);
 const answer=a<.06&&b<.06?'neither':Math.abs(a-b)<.015?'equal':a>b?'A':'B';
 const magnitude=(i%11===5&&(answer==='A'||answer==='B'))?'noticeably':null;
 history.push({...pair,answer,feeling:'creepy',magnitude});
 counts[pair.sampling.objective]=(counts[pair.sampling.objective]||0)+1;
}
assert(counts.explore>0,'Exploration was never used');
assert(counts.peak>0,'Peak refinement was never used');
assert(counts.gradient>0,'Gradient probes were never used');
assert(counts.valley>0,'Ridge/valley probes were never used');
const model=adapter.fit(history,'creepy');
const crest=model.estimate(hotspot).mean;
const field=model.estimate([-74.1675,40.3505]).mean;
assert(crest>field,'Model failed to recover the synthetic hotspot');
for(let k=0;k<12;k++){
 const x=adapter.rand();const e=model.estimate(x);
 assert(Number.isFinite(e.mean)&&Number.isFinite(e.sd)&&e.sd>=0,'Invalid estimate');
}
const empty=new API.SpatialModel(area,[{A:hotspot,B:[-74.165,40.348],answer:'equal'}]);
assert(empty.count===1,'Tie response was not ingested');
const absent=new API.SpatialModel(area,[{A:hotspot,B:[-74.165,40.348],answer:'neither'}]);
assert(absent.estimate(hotspot).mean<0,'Neither did not lower estimated association');
console.log('PASS:',history.length,'comparisons, 500-ft limit, area boundary,');
console.log('adaptive objectives',counts,'hotspot recovered');

/* Conservative contour refinement: equality is a directional constraint,
   not proof of a peak, and any follow-up must stay perpendicular and legal. */
const contourArea={type:'Polygon',coordinates:[[[-74.16754,40.34708],[-74.1677,40.3482],[-74.1672,40.3494],[-74.1653,40.3505],[-74.163,40.35065],[-74.16255,40.348],[-74.16754,40.34708]]]};
let contourSeed=1804;
const contourRng=()=>((contourSeed=(contourSeed*1664525+1013904223)>>>0)/4294967296);
const contourAdapter=new API.PersonalAdapter(contourArea,{random:contourRng});
const contourHistory=[];
for(let i=0;i<34;i++){
 const A=contourAdapter.rand(),B=contourAdapter.rand(A,40);
 contourHistory.push({A,B,answer:i%3===0?'equal':i%3===1?'A':'neither',feeling:'test'});
}
let contourCount=0;
for(let i=0;i<95;i++){
 const pair=contourAdapter.propose(contourHistory,'test'),sep=API.distance(pair.A,pair.B);
 assert(API.inside(pair.A,contourArea)&&API.inside(pair.B,contourArea)&&sep<=152.400001,'Invalid contour sampling geometry');
 assert(!pair.sampling.peakValleyCalibrationCandidate||pair.sampling.objective==='valley','Calibration qualification leaked into unrelated sampling');
 if(pair.sampling.objective==='contour'){
  contourCount++;
  const original=contourHistory[pair.sampling.contourSourceIndex];
  assert(original&&original.answer==='equal','Contour probe missing its original equal response');
  const lat=(original.A[1]+original.B[1])/2,cos=Math.cos(lat*Math.PI/180);
  const u=[(original.B[0]-original.A[0])*cos,original.B[1]-original.A[1]];
  const v=[(pair.B[0]-pair.A[0])*cos,pair.B[1]-pair.A[1]];
  const projection=Math.abs((u[0]*v[0]+u[1]*v[1])/(Math.hypot(...u)*Math.hypot(...v)));
  assert(projection<.3,'Contour candidate not approximately perpendicular');
 }
}
assert(contourCount>0,'No contour probes offered for nearby equal responses');
console.log('PASS:',contourCount,'conservative perpendicular contour probes');
