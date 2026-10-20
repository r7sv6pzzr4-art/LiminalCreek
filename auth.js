/* LiminalCreek account login only. Prototype impressions remain local until study activation. */
(()=>{
'use strict';
const URL='https://fwdsoluixqeycapncecl.supabase.co';
const KEY='sb_publishable_qoZbnqS3AfGmezZBdYo_vQ_Y4rH1a_6';
const $=id=>document.getElementById(id);
const status=s=>{$('authStatus').textContent=s};
if(!window.supabase?.createClient){status('Authentication library could not load. Refresh while online.');return;}
const client=window.supabase.createClient(URL,KEY,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});
function render(session){
 const user=session?.user;
 $('authEmail').hidden=!!user;
 $('authSend').hidden=!!user;
 $('authSignOut').hidden=!user;
 $('authIdentity').textContent=user?'Signed in: '+user.email:'Not signed in';
 status(user?'Account connected. The shared study is not initialized; impressions still stay on this device.':'Enter your email to receive a sign-in link.');
}
$('authSend').addEventListener('click',async()=>{
 const email=$('authEmail').value.trim();
 if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)){status('Enter a valid email address.');return;}
 $('authSend').disabled=true;status('Requesting sign-in email…');
 try{
  const {error}=await client.auth.signInWithOtp({email,options:{emailRedirectTo:location.origin+location.pathname}});
  status(error?'Could not send sign-in email: '+error.message:'Check your inbox for a sign-in link. If you do not see it, check spam.');
 }catch(e){status('Sign-in request failed: '+e.message)}
 finally{$('authSend').disabled=false}
});
$('authSignOut').addEventListener('click',async()=>{const {error}=await client.auth.signOut();if(error)status(error.message)});
client.auth.onAuthStateChange((_event,session)=>render(session));
client.auth.getSession().then(({data,error})=>error?status(error.message):render(data.session)).catch(e=>status(e.message));
})();
