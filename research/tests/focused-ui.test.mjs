import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
const admin=fs.readFileSync("admin-adaptive.html","utf8");
const stage=fs.readFileSync("research/staging/admin-final-focused.STAGING-ONLY.html","utf8");
const server=fs.readFileSync("supabase/functions/liminal-auto-activate/index.ts","utf8");
function script(html){
 return html.match(/<script type="module">([\s\S]*?)<\/script>/)?.[1];
}
test("the production admin UI adds final upload without changing normal ratios",()=>{
 assert.match(admin,/id="focusFile"/);
 assert.match(admin,/id="focusActivate"/);
 assert.match(admin,/activateFocused/);
 assert.match(admin,/pairCount/);
 assert.match(admin,/adaptivePercent/);
 assert.match(admin,/finalFocused/);
 assert.match(admin,/No further batch|no further batch|future batch activation/i);
 assert.match(admin,/from '.\/backend\/supabase-config.js'/);
 const js=script(admin);
 assert(js);
 new vm.Script(js.replace(/^import\s+.*;\s*$/m,""));
});
test("only the staging preview imports synthetic staging credentials",()=>{
 assert.match(stage,/mrelwvpixalfycfdarjf.supabase.co/);
 assert.match(stage,/staging-admin@example.invalid/);
 assert.doesNotMatch(stage,/fwdsoluixqeycapncecl/);
 assert.doesNotMatch(stage,/backend\/supabase-config.js/);
 assert.doesNotMatch(admin,/staging-admin@example.invalid|mrelwvpixalfycfdarjf/);
 new vm.Script(script(stage));
});
test("server keeps final focus candidates private and requires authorized caller",()=>{
 assert.match(server,/getUser\(token\)/);
 assert.match(server,/eq\("is_admin",true\)/);
 assert.match(server,/generateFocusedBatch/);
 assert.match(server,/liminal_admin_commit_focused_batch/);
 assert.match(server,/action==="activateFocused"/);
 assert.doesNotMatch(server,/reply\(\{[^}]*requestedRows[^}]*\}/);
});
