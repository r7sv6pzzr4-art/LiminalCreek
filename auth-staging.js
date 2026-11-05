/* STAGING PARTICIPANT PREVIEW ONLY. Never reads production keys or URLs. */
(()=>{
'use strict';
const STAGING_URL='https://mrelwvpixalfycfdarjf.supabase.co';
const TEST_ACCOUNTS=new Set(['staging-admin@example.invalid','staging-participant@example.invalid']);
const $=id=>document.getElementById(id);
function status(value){$('authStatus').textContent=value}
let client=null;
function render(session){
 const user=session?.user||null;
 $('authSend').hidden=!!user;
 $('authSignOut').hidden=!user;
 $('authIdentity').textContent=user?'STAGING · '+user.email:'Not signed in';
 status(user?'Connected to the synthetic staging study.':'Use a synthetic staging account.');
 window.dispatchEvent(new CustomEvent('liminal-auth',{detail:{user}}));
}
function initialize(){
 const key=$('stagingKey').value.trim();
 if(!/^sb_publishable_[A-Za-z0-9_-]+$/.test(key))throw Error('Use only the STAGING publishable API key (sb_publishable_...).');
 if(!window.supabase?.createClient)throw Error('Supabase client library did not load');
 if(!client){
   client=window.supabase.createClient(STAGING_URL,key,{
     auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}
   });
   window.liminalClient=client;
   client.auth.onAuthStateChange((_event,session)=>render(session));
 }
 return client;
}
$('authSend').addEventListener('click',async()=>{
 const email=$('authEmail').value.trim().toLowerCase();
 const password=$('stagingPassword').value;
 if(!TEST_ACCOUNTS.has(email)){status('Choose one of the two synthetic staging emails.');return}
 if(!password){status('Enter the synthetic staging account password.');return}
 $('authSend').disabled=true;
 try{
  const api=initialize();
  const {data,error}=await api.auth.signInWithPassword({email,password});
  if(error)throw Error(error.message);
  $('stagingPassword').value='';
  render(data.session);
 }catch(err){status('Staging sign-in failed: '+(err?.message||String(err)))}
 finally{$('authSend').disabled=false}
});
$('authSignOut').addEventListener('click',async()=>{
 if(client){const {error}=await client.auth.signOut();if(error)status(error.message)}
});
status('STAGING ONLY. Enter the staging public key, test account email and password.');
})();