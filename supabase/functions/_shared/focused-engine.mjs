// Private server-side generation of a FINAL 20-pair geography-focused set.
// No participant responses are used. No selected sites are sent to browsers.
// Source polygons must be supplied by the authorized administrator at activation.
const EARTH = 6371008.8;
const RAD = Math.PI / 180;
const assert = (x, msg) => { if (!x) throw Error(msg); };
export function distance(a,b) {
  return EARTH * Math.hypot((b[0]-a[0])*RAD*Math.cos((a[1]+b[1])*RAD/2),
                            (b[1]-a[1])*RAD);
}
function seeded(seed) {
  let h=2166136261;
  for(const ch of String(seed))h=Math.imul(h ^ ch.charCodeAt(0),16777619);
  return ()=>{h+=0x6D2B79F5;let t=h;t=Math.imul(t ^ t>>>15,t|1);
    t^=t+Math.imul(t ^ t>>>7,t|61);return ((t ^ t>>>14)>>>0)/4294967296};
}
function shuffled(arr,rng) {
  const v=arr.slice();
  for(let i=v.length-1;i>0;i--){const j=Math.floor(rng()*(i+1));
    [v[i],v[j]]=[v[j],v[i]]}
  return v;
}
const validCoord=p=>Array.isArray(p)&&p.length===2&&
  p.every(Number.isFinite)&&p[0]>=-180&&p[0]<=180&&p[1]>=-90&&p[1]<=90;
function inRing(p,ring) {
  let inShape=false;
  for(let i=0,j=ring.length-1;i<ring.length;j=i++){
    const a=ring[i],b=ring[j];
    if((a[1]>p[1])!==(b[1]>p[1]) &&
       p[0]<(b[0]-a[0])*(p[1]-a[1])/(b[1]-a[1])+a[0])
       inShape=!inShape;
  }
  return inShape;
}
export function pointInPolygon(point,rings){
  return inRing(point,rings[0]) && !rings.slice(1).some(r=>inRing(point,r));
}
function segmentCross(a,b,c,d) {
  const cross=(p,q,r)=>(q[0]-p[0])*(r[1]-p[1])-(q[1]-p[1])*(r[0]-p[0]);
  const x=cross(a,b,c), y=cross(a,b,d), z=cross(c,d,a), w=cross(c,d,b);
  // Strict crossing. Adjacent edges are handled by caller.
  return (x*y<0)&&(z*w<0);
}
function cleanRing(ring){
  assert(Array.isArray(ring)&&ring.length>=4&&ring.length<=250,
    "Each focus boundary must have 3–249 distinct vertices");
  assert(ring.every(validCoord),"Invalid focus coordinate");
  const last=ring.at(-1),first=ring[0];
  assert(first[0]===last[0]&&first[1]===last[1],
    "Each focus boundary must close exactly");
  for(let i=1;i<ring.length;i++)
    assert(distance(ring[i-1],ring[i])>0.1,"Repeated or degenerate focus boundary edge");
  let signed=0;
  for(let i=0;i<ring.length-1;i++){
    const a=ring[i],b=ring[i+1];signed+=a[0]*b[1]-b[0]*a[1];
    for(let j=i+2;j<ring.length-1;j++){
      if(i===0&&j===ring.length-2)continue;
      assert(!segmentCross(a,b,ring[j],ring[j+1]),"Self-crossing focus polygon");
    }
  }
  assert(Math.abs(signed)>1e-9,"Focus polygon area is too small");
  return ring.map(p=>p.slice());
}
export function normalizeFocusPolygons(input) {
  // Supports the old prototype export {polygons: FeatureCollection} and GeoJSON.
  const geo=input?.polygons||input;
  assert(geo&&geo.type==="FeatureCollection"&&Array.isArray(geo.features)
    &&geo.features.length===2,"Upload exactly two focus polygons");
  const polygons=geo.features.map((feature,i)=>{
    const g=feature?.geometry;
    assert(g?.type==="Polygon"&&Array.isArray(g.coordinates)&&
      g.coordinates.length===1,"Each focus area must be one simple polygon without holes");
    const outer=cleanRing(g.coordinates[0]);
    return outer;
  });
  return {
    geojson:{type:"FeatureCollection",features:polygons.map(r=>({
      type:"Feature",properties:{},geometry:{type:"Polygon",coordinates:[r]}
    }))},
    polygons
  };
}
function bounds(ring){
  return [Math.min(...ring.map(p=>p[0])),Math.min(...ring.map(p=>p[1])),
          Math.max(...ring.map(p=>p[0])),Math.max(...ring.map(p=>p[1]))];
}
function offset(point,bearing,metres){
  const lat=point[1]+metres*Math.sin(bearing)/(EARTH*RAD);
  const lon=point[0]+metres*Math.cos(bearing)/(EARTH*RAD*Math.cos((point[1]+lat)*RAD/2));
  return [lon,lat];
}
function candidatePool({ring,allowed,oldPoints,rng,size=3800}) {
  const [w,s,e,n]=bounds(ring),pool=[];
  for(let i=0;i<150000 && pool.length<size;i++){
    const p=[w+(e-w)*rng(),s+(n-s)*rng()];
    if(!pointInPolygon(p,[ring])||!allowed(p))continue;
    let nearest=Infinity;
    for(const old of oldPoints)nearest=Math.min(nearest,distance(p,old));
    if(nearest<22)continue;
    pool.push({p,oldDistance:nearest});
  }
  assert(pool.length>=250,"Insufficient eligible space in one focus polygon; do not widen boundaries");
  return pool;
}
function companion({center,ring,allowed,oldPoints,otherCenters,rng}){
  for(let j=0;j<130;j++){
    const p=offset(center,2*Math.PI*rng(),10+9*rng());
    if(!pointInPolygon(p,[ring])||!allowed(p))continue;
    if(oldPoints.some(old=>distance(p,old)<20))continue;
    if(otherCenters.some(old=>distance(p,old)<45))continue;
    return p;
  }
  return null;
}
// Generate two private independently randomized 10-pair groups, then
// interleave group membership in an independent 20-pair presentation order.
export function generateFocusedBatch({focusPolygons,eligible,existingPairs,seed,
  countPerArea=10}={}){
  assert(typeof eligible==="function","Study eligibility predicate is required");
  assert(typeof seed==="string"&&seed.length>=12,"A private audit seed is required");
  assert(countPerArea===10,"Final focused set is exactly 10 pairs per area");
  assert(Array.isArray(existingPairs),"Existing paired inventory is required");
  const {geojson,polygons}=normalizeFocusPolygons(focusPolygons);
  const oldPoints=[];
  for(const pair of existingPairs){
    assert(validCoord(pair.A)&&validCoord(pair.B),"Prior pair is invalid");
    oldPoints.push(pair.A,pair.B);
  }
  const groups=[];
  for(let area=0;area<2;area++){
    const rng=seeded(seed+"-area-"+area),ring=polygons[area];
    const pool=candidatePool({ring,allowed:eligible,oldPoints,rng});
    const selected=[];
    const centers=[];
    for(let i=0;i<countPerArea;i++){
      const ranked=[];
      for(const c of pool){
        if(c.used)continue;
        let nearest=Infinity;
        for(const other of centers)nearest=Math.min(nearest,distance(c.p,other));
        if(nearest<57)continue;
        // Prefer broad spatial dispersion but keep selections randomized.
        // The capped historical-distance term prevents past sites from
        // pushing every new location toward the boundary.
        const spacing=i===0?125:Math.min(nearest,250);
        const oldBonus=Math.min(c.oldDistance,95)*0.25;
        const score=spacing+oldBonus+25*rng();
        ranked.push({c,score});
      }
      ranked.sort((a,b)=>b.score-a.score);
      // Find a viable interior companion, trying the best random candidates.
      let picked=null,secondary=null;
      for(const {c} of ranked.slice(0,180)){
        const q=companion({center:c.p,ring,allowed:eligible,
          oldPoints,otherCenters:centers,rng});
        if(q){picked=c;secondary=q;break}
      }
      assert(picked&&secondary,
        "Could not fit 10 separated matched pairs in focus area "+(area+1));
      picked.used=true;
      const swap=rng()>.5;
      const A=swap?secondary:picked.p;
      const B=swap?picked.p:secondary;
      assert(distance(A,B)<=60.96 && distance(A,B)>=2,
        "Focused pair distance invalid");
      assert(pointInPolygon(A,[ring])&&pointInPolygon(B,[ring])&&eligible(A)&&eligible(B),
        "Focused endpoint outside a requested or eligible polygon");
      selected.push({area:area+1,mode:"focused",A,B});
      centers.push(picked.p);
    }
    groups.push(...selected);
  }
  const order=shuffled(groups,seeded(seed+"-presentation"));
  return {algorithmVersion:"focused-spaced-v1",count:20,perArea:10,
    focusPolygons:geojson,pairs:order};
}
