/* LiminalCreek adaptive spatial sampler, v0.1; no UI, storage or study APIs.
   One mathematical core; experiment-specific adapters supply observations,
   sampling constraints and goals. Personal comparisons are *relative*.
   Model: multiscale radial basis with a sequential Gaussian posterior.
   Ordinal strengths are conditioned as intervals, not equidistant ratings. */
(function(root){
'use strict';
const VERSION='0.3', MAX=152.4, METERS=111195, pi=Math.PI;
const cap=(x,a,b)=>Math.min(b,Math.max(a,x));
const distance=(a,b)=>Math.hypot((a[0]-b[0])*METERS*Math.cos((a[1]+b[1])*pi/360),(a[1]-b[1])*METERS);
function inside(p,geo){
 const g=geo.type==='Feature'?geo.geometry:geo;
 if(g.type==='MultiPolygon')return g.coordinates.some(c=>inside(p,{type:'Polygon',coordinates:c}));
 if(g.type!=='Polygon')return false;
 function ring(r){
  let yes=false;
  for(let i=0,j=r.length-1;i<r.length;j=i++){
   const a=r[i],b=r[j];
   if((a[1]>p[1])!==(b[1]>p[1])&&p[0]<(b[0]-a[0])*(p[1]-a[1])/(b[1]-a[1])+a[0])yes=!yes;
  }return yes;
 }
 return ring(g.coordinates[0])&&!g.coordinates.slice(1).some(ring);
}
function boxOf(geo){
 const g=geo.type==='Feature'?geo.geometry:geo;
 const ps=g.type==='MultiPolygon'?g.coordinates.flat(2):g.coordinates.flat();
 return [Math.min(...ps.map(p=>p[0])),Math.min(...ps.map(p=>p[1])),
         Math.max(...ps.map(p=>p[0])),Math.max(...ps.map(p=>p[1]))];
}
function randomIn(poly,box,random,center,radius){
 for(let i=0;i<1200;i++){
  let p;
  if(center){const t=random()*2*pi,r=Math.sqrt(random())*radius;
   p=[center[0]+r*Math.cos(t)/(METERS*Math.cos(center[1]*pi/180)),center[1]+r*Math.sin(t)/METERS];
  }else p=[box[0]+random()*(box[2]-box[0]),box[1]+random()*(box[3]-box[1])];
  if(inside(p,poly))return p;
 }return null;
}
function centers(poly,box,step){
 const lat=(box[1]+box[3])/2,lon=(box[0]+box[2])/2,cos=Math.cos(lat*pi/180);
 const loX=(box[0]-lon)*METERS*cos,hiX=(box[2]-lon)*METERS*cos;
 const loY=(box[1]-lat)*METERS,hiY=(box[3]-lat)*METERS,a=[];
 for(let x=Math.floor(loX/step)*step;x<=hiX+step;x+=step){
  for(let y=Math.floor(loY/step)*step;y<=hiY+step;y+=step){
   const p=[lon+x/(METERS*cos),lat+y/METERS];
   if(inside(p,poly))a.push(p);
  }
 }return a.length?a:[[lon,lat]];
}
const pdf=x=>Math.exp(-x*x/2)/Math.sqrt(2*pi);
function cdf(x){
 // Abramowitz-Stegun 26.2.17.
 const t=1/(1+.2316419*Math.abs(x));
 const q=((((1.330274429*t-1.821255978)*t+1.781477937)*t-.356563782)*t+.319381530)*t;
 const p=1-pdf(x)*q;return x>=0?p:1-p;
}
class SpatialModel{
 constructor(area,history=[]){
  this.area=area;const box=boxOf(area);
  this.broad=centers(area,box,110);this.fine=centers(area,box,57);
  this.n=1+this.broad.length+this.fine.length;
  this.mu=new Float64Array(this.n);this.C=new Float64Array(this.n*this.n);
  for(let i=0;i<this.n;i++)this.C[i*this.n+i]=i===0?.6:i<=this.broad.length?1.7:1.15;
  this.count=0;
  for(const h of history)this.add(h);
 }
 features(p){
  const v=new Float64Array(this.n);v[0]=1;let pos=1;
  for(const [anchors,sigma,scale] of [[this.broad,118,1],[this.fine,42,.9]]){
   let ss=0;
   for(let i=0;i<anchors.length;i++){const z=distance(p,anchors[i])/sigma,e=Math.exp(-z*z/2);v[pos+i]=e;ss+=e*e}
   const d=Math.max(.25,Math.sqrt(ss));
   for(let i=0;i<anchors.length;i++)v[pos+i]*=scale/d;
   pos+=anchors.length;
  }return v;
 }
 dot(x,y){let v=0;for(let i=0;i<this.n;i++)v+=x[i]*y[i];return v}
 projection(v,noise=0){
  const out=new Float64Array(this.n),N=this.n,C=this.C;
  for(let i=0;i<N;i++){let z=0;for(let j=0;j<N;j++)z+=C[i*N+j]*v[j];out[i]=z}
  return {out,m:this.dot(v,this.mu),s:Math.max(1e-8,this.dot(v,out)+noise)};
 }
 linear(v,value,noise){
  const q=this.projection(v,noise),d=(value-q.m)/q.s,N=this.n;
  for(let i=0;i<N;i++)this.mu[i]+=q.out[i]*d;
  for(let i=0;i<N;i++)for(let j=0;j<N;j++)this.C[i*N+j]-=q.out[i]*q.out[j]/q.s;
 }
 interval(v,lower,upper,noise){
  const q=this.projection(v,noise),sd=Math.sqrt(q.s);
  const a=lower===-Infinity?-Infinity:(lower-q.m)/sd;
  const b=upper===Infinity?Infinity:(upper-q.m)/sd;
  const mass=(upper===Infinity?1:cdf(b))-(lower===-Infinity?0:cdf(a));
  if(mass<1e-7)return;
  const fA=lower===-Infinity?0:pdf(a),fB=upper===Infinity?0:pdf(b);
  const shift=(fA-fB)/mass,curv=((Number.isFinite(a)?a*fA:0)-(Number.isFinite(b)?b*fB:0))/mass;
  const varAfter=Math.max(0,q.s*(1+curv-shift*shift));
  const shrink=cap((q.s-varAfter)/(q.s*q.s),0,1/q.s);
  const N=this.n;
  for(let i=0;i<N;i++)this.mu[i]+=q.out[i]*shift/sd;
  for(let i=0;i<N;i++)for(let j=0;j<N;j++)this.C[i*N+j]-=shrink*q.out[i]*q.out[j];
 }
 add(o){
  if(!o||!inside(o.A,this.area)||!inside(o.B,this.area))return;
  const a=this.features(o.A),b=this.features(o.B);
  if(o.answer==='neither'){
   this.linear(a,-.85,.32);this.linear(b,-.85,.32);
  }else{
   for(let j=0;j<this.n;j++)a[j]-=b[j];
   if(o.answer==='equal')this.linear(a,0,.28);
   else if(o.answer==='A'||o.answer==='B'){
    if(o.answer==='B')for(let j=0;j<this.n;j++)a[j]*=-1;
    // Verbal categories imply ordered *interval constraints*, not assigned scores.
    const intervals={slightly:[0,.7],noticeably:[.7,1.65],much:[1.65,Infinity]};
    const r=intervals[o.magnitude]||[0,Infinity];
    this.interval(a,r[0],r[1],o.magnitude?.38:.8);
   }else return;
  }
  this.count++;
 }
 estimate(p){const q=this.projection(this.features(p));return {mean:q.m,sd:Math.sqrt(Math.max(0,q.s))}}
 compare(a,b){const v=this.features(a),w=this.features(b);for(let j=0;j<this.n;j++)v[j]-=w[j];const q=this.projection(v);return {mean:q.m,sd:Math.sqrt(Math.max(0,q.s))}}
}
class PersonalAdapter{
 constructor(area,options={}){
  this.area=area;this.box=boxOf(area);
  this.maxDistance=options.maxDistance||MAX;this.random=options.random||Math.random;
 }
 rand(center=null,radius=0){return randomIn(this.area,this.box,this.random,center,radius)}
 fit(history,feeling){return new SpatialModel(this.area,history.filter(h=>h.feeling===feeling))}
 propose(history,feeling){
  const rng=this.random,model=this.fit(history,feeling),recent=history.slice(-12).flatMap(h=>[h.A,h.B]);
  const old=history.slice(0,-12).flatMap(h=>[h.A,h.B]);
  const perFeeling=history.filter(h=>h.feeling===feeling).flatMap(h=>[h.A,h.B]);
  const nearest=(p,points)=>points.length?Math.min(...points.map(q=>distance(p,q))):150;
  const valid=(p,relaxed)=>p&&inside(p,this.area)&&nearest(p,recent)>(relaxed?8:18)&&nearest(p,old)>(relaxed?3:6);
  const pool=[];
  for(let i=0;i<125;i++){const p=this.rand();if(valid(p,true))pool.push({p,pred:model.estimate(p),coverage:cap(nearest(p,perFeeling)/100,0,1)})}
  if(!pool.length)throw Error('No test locations available inside the boundary');
  // Smoothly shift from coverage toward refinement as each feeling gains
  // observations AND a discernible gradient; no hard phase boundary.
  const levels=pool.map(x=>x.pred.mean);
  const range=Math.max(...levels)-Math.min(...levels);
  const evidence=cap(range/(range+.75),0,1);
  const readiness=cap(model.count/(model.count+25)*evidence,0,1);
  const shares=[
   ['explore',.75-.49*readiness],
   ['peak',.08+.26*readiness],
   ['gradient',.12+.14*readiness],
   ['valley',.05+.09*readiness]
  ];
  let mode='explore';
  if(model.count>=5){
   let ticket=rng();
   for(const [name,weight] of shares){ticket-=weight;if(ticket<=0){mode=name;break}}
  }
  const ranked=pool.slice().sort((a,b)=>b.pred.mean-a.pred.mean);
  const maxima=[];
  for(const x of ranked){
   if(x.pred.mean>-.1&&maxima.every(t=>distance(x.p,t.p)>85))maxima.push(x);
   if(maxima.length===5)break;
  }
  let bridge=null;
  if(mode==='valley'){
   outer:for(let i=0;i<maxima.length;i++)for(let j=i+1;j<maxima.length;j++){
    const len=distance(maxima[i].p,maxima[j].p);
    if(len>85&&len<250){bridge=[maxima[i],maxima[j]];break outer}
   }
   if(!bridge)mode='explore';
  }
  let seed=null;
  if(mode==='valley'&&bridge){
   const [a,b]=bridge.map(x=>x.p);
   const mid=[(a[0]+b[0])/2,(a[1]+b[1])/2];
   seed=this.rand(mid,18);
   if(!seed)mode='explore';
  }
  if(mode==='peak'){
   const picks=pool.slice().sort((a,b)=>b.pred.mean+.25*b.pred.sd+.15*b.coverage-a.pred.mean-.25*a.pred.sd-.15*a.coverage);
   seed=picks[Math.floor(rng()*Math.min(9,picks.length))].p;
  }
  if(mode==='gradient'){
   const picks=pool.map(x=>{
    let g=0;
    for(let j=0;j<15;j++){
     const y=pool[Math.floor(rng()*pool.length)],len=distance(x.p,y.p);
     if(len>20&&len<120)g=Math.max(g,Math.abs(x.pred.mean-y.pred.mean)/len);
    }return {p:x.p,score:100*g+.3*x.pred.sd+.2*x.coverage};
   }).sort((a,b)=>b.score-a.score);
   seed=picks[Math.floor(rng()*Math.min(8,picks.length))].p;
  }
  if(!seed){
   const picks=pool.slice().sort((a,b)=>b.coverage+.3*b.pred.sd-a.coverage-.3*a.pred.sd);
   seed=picks[Math.floor(rng()*Math.min(10,picks.length))].p;
  }
  let best=null,high=-Infinity;
  for(let i=0;i<240;i++){
   const p=i<75?seed:i<135?this.rand(seed,65):this.rand();
   if(!valid(p,i>150))continue;
   let q;
   if(mode==='valley'&&bridge&&i<160)q=this.rand(bridge[i%2].p,24);
   else{
    const radius=mode==='explore'?65+rng()*this.maxDistance:mode==='peak'?20+rng()*90:30+rng()*120;
    q=this.rand(p,Math.min(radius,this.maxDistance));
   }
   if(!valid(q,i>150))continue;
   const len=distance(p,q);
   if(len<16||len>this.maxDistance)continue;
   const a=model.estimate(p),b=model.estimate(q),diff=model.compare(p,q);
   const coverage=(nearest(p,perFeeling)+nearest(q,perFeeling))/200;
   const info=cap(diff.sd/2,0,1.5),contrast=Math.abs(diff.mean);
   let score=0;
   if(mode==='explore')score=coverage+.65*info+.15*len/this.maxDistance;
   else if(mode==='peak')score=.8*Math.max(a.mean,b.mean)+.45*info+.15*coverage-.004*len;
   else if(mode==='gradient')score=contrast/(.35+len/85)+.4*info+.15*coverage;
   else score=.8*info+.35*contrast+.2*coverage;
   score+=.13*rng();
   if(score>high){high=score;best={p,q,len,diff}}
  }
  if(!best){
   for(let i=0;i<1000&&!best;i++){
    const p=this.rand(),q=p&&this.rand(p,this.maxDistance);
    if(valid(p,true)&&valid(q,true)&&distance(p,q)>=16&&distance(p,q)<=this.maxDistance)
     best={p,q,len:distance(p,q),diff:model.compare(p,q)};
   }
  }
  if(!best)throw Error('Unable to find distinct nearby locations');
  let contourSourceIndex=null;
  // Rare, minimally intrusive follow-up to a *nearby equal* response:
  // sample across (rather than along) its possible intensity contour.
  // Equality alone does NOT prove that a contour or a gradient exists.
  if(mode==='gradient'&&model.count>=10&&rng()<.2){
   const used=new Set(history.slice(-35).map(h=>h.sampling?.contourSourceIndex).filter(Number.isInteger));
   const possible=history.map((h,index)=>({h,index})).slice(-55)
    .filter(({h,index})=>h.feeling===feeling&&h.answer==='equal'&&!used.has(index)
      &&distance(h.A,h.B)>=20&&distance(h.A,h.B)<=110);
   // Only replace an ordinary gradient proposal if both new locations
   // meet all the original spacing, polygon and pair-length requirements.
   for(let trial=0;trial<Math.min(8,possible.length*3);trial++){
    const {h,index}=possible[Math.floor(rng()*possible.length)];
    const mid=[(h.A[0]+h.B[0])/2,(h.A[1]+h.B[1])/2];
    const cos=Math.cos(mid[1]*pi/180);
    const dx=(h.B[0]-h.A[0])*METERS*cos,dy=(h.B[1]-h.A[1])*METERS;
    const len=Math.hypot(dx,dy),theta=(rng()-.5)*.38;
    const nx=(-dy*Math.cos(theta)-dx*Math.sin(theta))/len;
    const ny=(dx*Math.cos(theta)-dy*Math.sin(theta))/len;
    const radius=25+rng()*29;
    const p=[mid[0]+radius*nx/(METERS*cos),mid[1]+radius*ny/METERS];
    const q=[mid[0]-radius*nx/(METERS*cos),mid[1]-radius*ny/METERS];
    const dd=distance(p,q);
    if(!valid(p,false)||!valid(q,false)||dd<16||dd>this.maxDistance)continue;
    if(model.compare(p,q).sd<.3)continue;
    best={p,q,len:dd,diff:model.compare(p,q)};
    mode='contour';contourSourceIndex=index;
    break;
   }
  }
  // A valley-labelled pair is not automatically a peak-to-valley
  // contrast. Require a separately supported midpoint depression and
  // observed coverage near both candidate peaks and the midpoint.
  let peakValleyCalibrationCandidate=false;
  if(mode==='valley'&&bridge&&model.count>=22){
   const first=bridge[0].p,last=bridge[1].p;
   const mid=[(first[0]+last[0])/2,(first[1]+last[1])/2];
   const midMean=model.estimate(mid).mean;
   const crest=Math.min(model.estimate(first).mean,model.estimate(last).mean);
   const drop=crest-midMean;
   const support=(p)=>perFeeling.filter(site=>distance(site,p)<65).length;
   const matches=(a,b)=>(distance(a,mid)<42
     &&(distance(b,first)<45||distance(b,last)<45));
   const contrast=best.diff;
   if(drop>.65&&drop>.6*Math.max(model.compare(first,mid).sd,model.compare(last,mid).sd)
      &&support(mid)>=2&&support(first)>=2&&support(last)>=2
      &&(matches(best.p,best.q)||matches(best.q,best.p))
      &&Math.abs(contrast.mean)>.65+.7*contrast.sd){
    peakValleyCalibrationCandidate=true;
   }
  }
  // Additional, cautiously qualified magnitude calibration opportunity.
  // A well-sampled high/low contrast can be useful even when a true
  // topographic saddle has not yet been demonstrated. Keep this distinct
  // from the stronger, explicit peak–valley classification above.
  const localSupport=p=>perFeeling.filter(q=>distance(q,p)<65).length;
  const spatialContrastCalibrationCandidate=!peakValleyCalibrationCandidate
    &&model.count>=22&&(mode==='gradient'||mode==='valley')
    &&best.len>=45&&Math.abs(best.diff.mean)>=.75&&best.diff.sd<=1.15
    &&localSupport(best.p)>=2&&localSupport(best.q)>=2;
  const swap=rng()<.5;
  return {
   A:swap?best.q:best.p,B:swap?best.p:best.q,referenceIsA:!swap,
   sampling:{
    model:'liminal-multiscale-bayes',version:VERSION,objective:mode,
    distanceMeters:+best.len.toFixed(1),trainingCount:model.count,
    expectedDifference:+Math.abs(best.diff.mean).toFixed(3),
    differenceUncertainty:+best.diff.sd.toFixed(3),
    ...(contourSourceIndex!==null?{contourSourceIndex}:{}),
    ...(peakValleyCalibrationCandidate?{peakValleyCalibrationCandidate:true}:{}),
    ...(spatialContrastCalibrationCandidate?{spatialContrastCalibrationCandidate:true}:{})
   }
  };
 }
}
root.LiminalAdaptive=Object.freeze({VERSION,MAX_PAIR_METERS:MAX,distance,inside,SpatialModel,PersonalAdapter});
})(typeof window!=='undefined'?window:globalThis);
