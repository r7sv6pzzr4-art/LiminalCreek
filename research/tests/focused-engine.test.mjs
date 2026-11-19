import test from "node:test";
import assert from "node:assert/strict";
import {generateFocusedBatch,normalizeFocusPolygons,distance,pointInPolygon}
  from "../../supabase/functions/_shared/focused-engine.mjs";

const rectangle=(w,s,e,n)=>[[w,s],[e,s],[e,n],[w,n],[w,s]];
const feature=ring=>({type:"Feature",properties:{},geometry:{
  type:"Polygon",coordinates:[ring]}});
const p1=rectangle(-74.190,40.350,-74.184,40.354);
const p2=rectangle(-74.182,40.356,-74.176,40.360);
const exported={polygons:{type:"FeatureCollection",features:[
  feature(p1),feature(p2)]},pairs:[],responses:[]};
const original=[];
for(let i=0;i<120;i++){
 const a=[-74.18+(i%20)*0.00015,40.346-(i%6)*0.00015];
 original.push({A:a,B:[a[0]+0.00006,a[1]+0.00005]});
}
const holes=[rectangle(-74.1895,40.3504,-74.1885,40.3512)];
const allowed=p=>!pointInPolygon(p,holes);
function batch(seed="test-seed-76d6b7f1"){
 return generateFocusedBatch({focusPolygons:exported,eligible:allowed,existingPairs:original,seed});
}
test("20 pairs, exact split, boundary/hole/previous-site safety",()=>{
 const r=batch();
 assert.equal(r.algorithmVersion,"focused-spaced-v1");
 assert.equal(r.count,20);
 assert.equal(r.pairs.filter(p=>p.area===1).length,10);
 assert.equal(r.pairs.filter(p=>p.area===2).length,10);
 const prior=original.flatMap(p=>[p.A,p.B]);
 for(const pair of r.pairs){
  assert.equal(pair.mode,"focused");
  const ring=pair.area===1?p1:p2;
  for(const p of [pair.A,pair.B]){
   assert(pointInPolygon(p,[ring]),"endpoint inside its exact requested polygon");
   assert(allowed(p),"endpoint outside the official exclusion");
   assert(prior.every(q=>distance(q,p)>=19.5),"no repetition of old location");
  }
  assert(distance(pair.A,pair.B)>=2&&distance(pair.A,pair.B)<=60.96);
 }
});
test("fixed seed is repeatable, different seed selects new irregular sites",()=>{
 assert.deepEqual(batch(),batch());
 assert.notDeepEqual(batch(),batch("another-test-seed-10a572ac"));
});
test("reject malformed or changed user export, rather than widening polygons",()=>{
 assert.equal(normalizeFocusPolygons(exported).polygons.length,2);
 assert.throws(()=>normalizeFocusPolygons({polygons:{type:"FeatureCollection",features:[feature(p1)]}}));
 assert.throws(()=>normalizeFocusPolygons({polygons:{type:"FeatureCollection",features:[
  feature(p1),feature([[0,0],[1,0],[1,1]])]}}));
 assert.throws(()=>generateFocusedBatch({
  focusPolygons:exported,eligible:()=>false,existingPairs:original,seed:"blocked-seed-1234"
 }),/Insufficient eligible space/);
});
test("does not require or use any submitted responses",()=>{
 const r=batch("private-seed-92efab82");
 assert.equal(Object.keys(r).includes("observations"),false);
 assert.equal(r.pairs.every(p=>!Object.hasOwn(p,"score")),true);
});
