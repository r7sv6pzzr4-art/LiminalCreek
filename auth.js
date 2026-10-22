/* LiminalCreek account login only. Prototype impressions remain local until study activation. */
(()=>{
'use strict';
const URL='https://fwdsoluixqeycapncecl.supabase.co';
const KEY='sb_publishable_qoZbnqS3AfGmezZBdYo_vQ_Y4rH1a_6';
const $=id=>document.getElementById(id);
const status=s=>{$('authStatus').textContent=s};
if(!window.supabase?.createClient){status('Authentication library could not load. Refresh while online.');return;}
const client=window.supabase.createClient(URL,KEY,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});
window.liminalClient=client;
function render(session){
 window.dispatchEvent(new CustomEvent('liminal-auth',{detail:{user:session?.user||null}}));
 const user=session?.user;
 $('authEmail').hidden=!!user;
 $('authSend').hidden=!!user;
 $('authSignOut').hidden=!user;
 $('authCodeRow').hidden=!!user;
 $('authIdentity').textContent=user?'Signed in: '+user.email:'Not signed in';
 status(user?'Account connected. The shared study is not initialized; impressions still stay on this device.':'Enter your email for a sign-in link. You can also enter a code if your email contains one.');
}
$('authSend').addEventListener('click',async()=>{
 const email=$('authEmail').value.trim();
 if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)){status('Enter a valid email address.');return;}
 $('authSend').disabled=true;status('Requesting sign-in email…');
 try{
  const {error}=await client.auth.signInWithOtp({email,options:{emailRedirectTo:location.origin+location.pathname}});
  status(error?'Could not send sign-in email: '+error.message:'Check your inbox for a sign-in link or code (if enabled in the email template). Check spam if needed.');
 }catch(e){status('Sign-in request failed: '+e.message)}
 finally{$('authSend').disabled=false}
});
$('authVerify').addEventListener('click',async()=>{
 const email=$('authEmail').value.trim(),token=$('authCode').value.trim();
 if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)){status('Enter the same email address you requested the sign-in email for.');return;}
 if(!/^\d{6}$/.test(token)){status('Enter the six-digit code from your sign-in email.');return;}
 $('authVerify').disabled=true;status('Verifying code…');
 try{
  const {error}=await client.auth.verifyOtp({email,token,type:'email'});
  if(error)status('Code not accepted: '+error.message);
  else {$('authCode').value='';status('Signed in successfully.');}
 }catch(e){status('Code verification failed: '+e.message)}
 finally{$('authVerify').disabled=false}
});
$('authSignOut').addEventListener('click',async()=>{const {error}=await client.auth.signOut();if(error)status(error.message)});
client.auth.onAuthStateChange((_event,session)=>render(session));
client.auth.getSession().then(({data,error})=>error?status(error.message):render(data.session)).catch(e=>status(e.message));
})();
