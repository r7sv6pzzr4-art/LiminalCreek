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
