'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const adaptive=require('./adaptive-engine.js');
const personal=require('./personal-mapping.js');

const bounds=[-74.18,40.31,-74.15,40.34];
const eligible=p=>p[0]>=bounds[0]&&p[0]<=bounds[2]&&p[1]>=bounds[1]&&p[1]<=bounds[3];
const coords=i=>[-74.178+(i%10)*0.0025,40.312+Math.floor(i/10)*0.0025];
const original=Array.from({length:100},(_,i)=>({
  id:'original-'+i,A:coords(i),B:[coords(i)[0]+0.00025,coords(i)[1]+0.0002]
}));
const observations=original.slice(0,100).flatMap((p,i)=>[
  {point:p.A,participant:'A',pairId:p.id,valence:i%5?'good':'neutral',
    strength:i%5?i%6===0?4:2:null},
  {point:p.B,participant:'B',pairId:p.id,valence:i%7?'bad':'neutral',
    strength:i%7?i%9===0?4:1:null}
]);
test('staged pairs are deterministic, eligible, paired, and do not mutate originals',()=>{
  const input={count:12,seed:'study1-batch1',bounds,eligible,
    observations,existingPairs:original,batchIndex:1};
  const snapshot=JSON.stringify({original,observations});
  const first=adaptive.generateBatch(input);
  const second=adaptive.generateBatch(input);
  assert.deepEqual(first,second);
  assert.equal(first.pairs.length,12);
  assert.equal(first.staged,true);
  assert.deepEqual(JSON.stringify({original,observations}),snapshot);
  assert.deepEqual(first.pairs.reduce((a,p)=>(a[p.mode]=(a[p.mode]||0)+1,a),{}),
    {interesting:4,uncertain:3,quiet:2,broad:3});
  for(const p of first.pairs){
    assert(eligible(p.A)&&eligible(p.B));
    assert(adaptive.distance(p.A,p.B)<=p.maximumSeparationMeters+0.01);
    assert(p.maximumSeparationMeters<=60.96);
    assert(original.every(o=>adaptive.distance(p.A,o.A)>=12&&adaptive.distance(p.A,o.B)>=12));
  }
  assert.equal(new Set(first.pairs.map(p=>p.id)).size,12);
});
test('invalid input cannot silently exceed original 200-foot pair separation',()=>{
  assert.throws(()=>adaptive.generateBatch({count:2,seed:1,bounds,eligible,
    maxSeparationMeters:70}),/Maximum separation/);
});
test('planning budget is a recommendation, not automatic extension',()=>{
  const r=adaptive.recommendExtension({observations,remainingPairs:20});
  assert.equal(r.status,'planning-estimate-only');
  assert(r.preliminaryAdditionalPairs>=0);
});
test('personal planning contains no original response records or notes',()=>{
  const own=[
    {point:[-74.170,40.320],valence:'bad',strength:4,
      descriptions:['Unease','Creepy'],note:'private original note'},
    {point:[-74.1705,40.3203],valence:'mixed',strength:3,
      descriptions:['Melancholy'],note:'another private note'},
    {point:[-74.16,40.33],valence:'neutral',strength:null,
      descriptions:['None'],note:'not part of hotspot'}
  ];
  const plan=personal.summarizePersonalRegions({observations:own,eligible,seed:'private',sitesPerRegion:6});
  assert.equal(plan.personal,true);
  assert.equal(plan.regions.length,1);
  assert.equal(plan.regions[0].sites.length,6);
  const json=JSON.stringify(plan);
  assert(!json.includes('private original note')&&!json.includes('another private note'));
  for(const o of own)assert(!json.includes(JSON.stringify(o.point)));
  for(const s of plan.regions[0].sites)assert(eligible(s.point));
});
test('new feelings become reusable participant choices, with no duplication',()=>{
  const one=personal.addFeeling(['Unease','Peace'], '  Mysterious   stillness ');
  assert.equal(one.selected,'Mysterious stillness');
  assert(one.labels.includes(one.selected));
  const two=personal.addFeeling(one.labels,'mysterious stillness');
  assert.equal(two.labels.length,3);
  assert.equal(two.selected,'Mysterious stillness');
  assert.deepEqual(personal.validatePersonalAnswer({feeling:one.selected,intensity:8},
    {allowedFeelings:one.labels}),{feeling:one.selected,intensity:8,note:''});
  assert.throws(()=>personal.validatePersonalAnswer({feeling:'Unknown',intensity:8},
    {allowedFeelings:one.labels}));
});
test('results release remains locked until plan closes and both finish both phases',()=>{
  const study={samplingPlanClosed:true,finalPairCount:200,revealedAt:null};
  const people=[
    {userId:'a',isAdmin:true,completedSharedPairs:200,personalStatus:'completed'},
    {userId:'b',isAdmin:false,completedSharedPairs:200,personalStatus:'skipped'}
  ];
  assert(personal.canReleaseResults({study,participants:people,actingUserId:'a'}));
  assert(!personal.canReleaseResults({study,participants:people,actingUserId:'b'}));
  assert(!personal.canReleaseResults({study:{...study,samplingPlanClosed:false},
    participants:people,actingUserId:'a'}));
  assert(!personal.canReleaseResults({study,participants:people.map((p,i)=>i?{...p,personalStatus:'active'}:p),
    actingUserId:'a'}));
  assert(!personal.canReleaseResults({study,participants:people.map((p,i)=>i?{...p,completedSharedPairs:199}:p),
    actingUserId:'a'}));
});
