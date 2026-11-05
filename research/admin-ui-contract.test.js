'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm');
const page=fs.readFileSync('admin-adaptive.html','utf8');
const participant=fs.readFileSync('index.html','utf8');
const server=fs.readFileSync('supabase/functions/liminal-auto-activate/index.ts','utf8');
const config=fs.readFileSync('admin-adaptive-config.js','utf8');
const sql=fs.readFileSync('research/drafts/auto-activation.DO-NOT-RUN.sql','utf8');

test('administrator page has 10–40 dropdown and ratio presets with recoverable requests',()=>{
 assert.match(page,/id="pairCount"/);
 assert.match(page,/id="adaptivePercent"/);
 assert.match(page,/value="10"/);
 assert.match(page,/value="20"/);
 assert.match(page,/value="30"/);
 assert.match(page,/value="40"/);
 assert.match(page,/value="50"/);
 assert.match(page,/value="75"/);
 assert.match(page,/id="activate"/);
 assert.match(page,/sessionStorage\.setItem\(pendingKey/);
 assert.match(page,/action:'check'/);
 assert.match(page,/window\.confirm\(/);
 const script=page.match(/<script type="module">([\s\S]*?)<\/script>/)?.[1];
 assert(script,'Expected standalone admin page module');
 new vm.Script(script.replace(/^import\s+.*;\s*$/m,''),{filename:'admin-adaptive.html'});
});

test('participant UI retains existing observations and hides admin controls',()=>{
 assert.match(participant,/<a id="adminToolsLink"[^>]+hidden/);
 assert.match(participant,/rpc\('liminal_admin_auto_status'\)/);
 assert.match(participant,/id="present"/);
 assert.match(participant,/id="valence"/);
 assert.match(participant,/id="authPanel"/);
 assert.doesNotMatch(participant,/liminal_admin_commit_auto_batch/);
 assert.doesNotMatch(participant,/generateBatch/);
});

test('browser cannot submit site coordinates; server verifies authenticated owner',()=>{
 assert.match(server,/auth\.getUser\(token\)/);
 assert.match(server,/\.eq\("is_admin",true\)/);
 assert.match(server,/generateBatch\(/);
 assert.match(server,/await admin\.rpc\("liminal_admin_commit_auto_batch"/);
 assert.doesNotMatch(server,/await caller\.rpc\("liminal_admin_commit_auto_batch"/);
 assert.match(sql,/auth\.role\(\) IS DISTINCT FROM 'service_role'/);
 assert.match(sql,/TO service_role;/);
 assert.doesNotMatch(sql,/GRANT EXECUTE ON FUNCTION public\.liminal_admin_commit_auto_batch[^\n]+TO authenticated/);
});

test('live collection functions are not altered by branch-only drafts',()=>{
 assert.match(sql,/DEVELOPMENT DRAFT ONLY/);
 assert.doesNotMatch(sql,/CREATE OR REPLACE FUNCTION public\.next_liminal_place/);
 assert.doesNotMatch(sql,/CREATE OR REPLACE FUNCTION public\.submit_impression/);
});

test('development administrator screen is disconnected from production by default',()=>{
 assert.match(page,/\.\/admin-adaptive-config\.js/);
 assert.doesNotMatch(page,/\.\/backend\/supabase-config\.js/);
 assert.match(page,/if\(!client\)throw Error/);
 assert.match(config,/ADMIN_SUPABASE_URL\s*=\s*'https:\/\/mrelwvpixalfycfdarjf\.supabase\.co'/);
 assert.match(config,/ADMIN_SUPABASE_PUBLISHABLE_KEY\s*=\s*''/);
});
