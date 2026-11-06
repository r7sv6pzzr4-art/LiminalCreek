'use strict';
// Private, LOCAL-ONLY preflight: accepts only an absolute path outside GitHub repo.
// Never prints coordinates, participant IDs, responses or notes; never calls network.
const fs=require('node:fs'),path=require('node:path');
const {parseExport}=require('../research/run-private-preview.js');
const {geometryMask}=require('../research/shared-coordinator.js');
const {distance}=require('../research/adaptive-engine.js');
function stop(message){throw Error(message)}
const filename=process.argv[2];
if(process.argv.length!==3||!filename||!path.isAbsolute(filename))
 stop('Usage: node release/check-private-geometry.cjs /absolute/path/to/private-snapshot.csv');
const repo=path.resolve(__dirname,'..');
const full=path.resolve(filename),relative=path.relative(repo,full);
if(!(relative==='..'||relative.startsWith('..'+path.sep)))
 stop('Private snapshot must be OUTSIDE the public repository');
try{
 const s=parseExport(fs.readFileSync(full,'utf8'));
 if(s?.schemaVersion!==1||s?.participantCount!==2||s?.originalPairCount!==100||
    s?.incompleteOriginalPairs!==0||s?.originalPairs?.length!==100)
  stop('Private snapshot lacks the complete original two-participant study');
 const {eligible,bounds}=geometryMask(s.polygons);
 const issues={outside:0,separation:0,malformed:0};
 for(const p of s.originalPairs){
  if(!Array.isArray(p.A)||!Array.isArray(p.B)||p.A.length!==2||p.B.length!==2||
     [...p.A,...p.B].some(v=>!Number.isFinite(v))){
    issues.malformed++;continue;
  }
  if(!eligible(p.A))issues.outside++;
  if(!eligible(p.B))issues.outside++;
  if(distance(p.A,p.B)>60.97)issues.separation++;
 }
 console.log('PRIVATE LOCAL GEOMETRY CHECK (no coordinates or responses printed)');
 console.log('Snapshot age (UTC):',s.capturedAt||'not provided');
 console.log('Original matched pairs:',s.originalPairs.length);
 console.log('Eligible polygon bounding box exists:',bounds.every(Number.isFinite));
 console.log('Original assignment points outside eligible geometry:',issues.outside);
 console.log('Original pairs exceeding 200-foot separation:',issues.separation);
 console.log('Malformed original pairs:',issues.malformed);
 if(Object.values(issues).some(n=>n!==0)){
  console.error('NOT READY: investigate geometry mismatch privately; do not activate on live system');
  process.exitCode=1;
 }else console.log('PASS: all 200 original assignment points are in the stored eligible area');
}catch(err){console.error('CHECK FAILED:',err?.message||String(err));process.exitCode=1}
