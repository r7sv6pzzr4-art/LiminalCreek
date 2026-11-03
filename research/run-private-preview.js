'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {prepareSharedPreview}=require('./shared-coordinator.js');
function check(v,m){if(!v)throw Error(m);}
function parseExport(raw){
 let t=String(raw).replace(/^\uFEFF/,'').trim().replace(/^"?snapshot_json"?\r?\n/i,'').trim();
 if(t.startsWith('"{')&&t.endsWith('"'))t=t.slice(1,-1).replace(/""/g,'"');
 let s=JSON.parse(t);if(Array.isArray(s)&&s.length===1)s=s[0];
 if(s?.snapshot_json!==undefined)s=typeof s.snapshot_json==='string'?JSON.parse(s.snapshot_json):s.snapshot_json;
 return s;
}
function previewFromSnapshot(s){
 check(s?.schemaVersion===1&&s.studyId&&s.polygons,'Invalid snapshot');
 check(s.participantCount===2&&s.originalPairCount===100&&s.incompleteOriginalPairs===0,'Invalid initial pair inventory');
 check(s.assignedOriginal?.A===100&&s.assignedOriginal?.B===100,'Original assignment count invalid');
 check(s.originalPairs?.length===100&&s.observations?.length===s.responseCount,'Snapshot data count inconsistent');
 const pairs=new Map(s.originalPairs.map(p=>[p.id,p])),seen=new Set(),counts={A:0,B:0};
 check(pairs.size===100,'Duplicate pair ids');
 for(const o of s.observations){
  const p=pairs.get(o.pairId),side=o.participant;
  check(p&&['A','B'].includes(side),'Unknown response');
  check(o.point?.length===2&&o.point.every((v,i)=>v===p[side][i]),'Response location mismatch');
  check(!seen.has(o.pairId+side),'Duplicate response');
  check(['good','bad','mixed','neutral'].includes(o.valence),'Invalid response');
  check(o.valence==='neutral'?o.strength===null:Number.isInteger(o.strength)&&o.strength>=1&&o.strength<=4,'Invalid strength');
  seen.add(o.pairId+side);counts[side]++;
 }
 check(s.completion?.A===counts.A&&s.completion?.B===counts.B,'Completion totals inconsistent');
 const hash=crypto.createHash('sha256').update(JSON.stringify(s)).digest('hex');
 const result=prepareSharedPreview({polygons:s.polygons,originalPairs:s.originalPairs,
  observations:s.observations,completion:counts,seed:'private-'+hash.slice(0,24),
  approvedAdditionalPairs:20,releasedAdditionalPairs:0,batchIndex:1});
 return {format:'liminal-private-preview-v1',capturedAt:s.capturedAt,
  sourceDigest:hash,observedResponses:s.responseCount,...result};
}
function outsideRepo(p){
 const full=path.resolve(p),relative=path.relative(path.resolve(__dirname,'..'),full);
 check(path.isAbsolute(p)&&(relative==='..'||relative.startsWith('..'+path.sep)),'Private files must be outside public repository');
 return full;
}
function main(argv){
 check(argv.length===4&&argv[0]==='--input'&&argv[2]==='--out','Expected --input /absolute/file.csv --out /absolute/file.json');
 const input=outsideRepo(argv[1]),output=outsideRepo(argv[3]);
 check(input!==output,'Input and output must differ');
 const r=previewFromSnapshot(parseExport(fs.readFileSync(input,'utf8')));
 fs.writeFileSync(output,JSON.stringify(r,null,2),{flag:'wx',mode:0o600});
 console.log('Private local preview generated; no Supabase access');
 console.log('Responses:',r.observedResponses,'Completion A/B:',r.completion.A,r.completion.B);
 console.log('New pairs:',r.batch.count,'Coverage:',r.batch.pairs.filter(p=>p.mode==='broad').length);
 console.log('Release eligible:',r.releaseEligible);
}
if(require.main===module){try{main(process.argv.slice(2));}catch(e){console.error(e.message);process.exitCode=1;}}
module.exports={parseExport,previewFromSnapshot};