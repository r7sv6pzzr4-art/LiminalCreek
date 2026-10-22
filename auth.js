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
 $('authLinkRow').hidden=!!user;
 $('authLinkHelp').hidden=!!user;
 $('authIdentity').textContent=user?'Signed in: '+user.email:'Not signed in';
 status(user?'Account connected. The shared study is not initialized; impressions still stay on this device.':'You can open the email link in Safari, or copy and paste it below to sign in inside this Home Screen app.');
}
$('authSend').addEventListener('click',async()=>{
 const email=$('authEmail').value.trim();
 if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)){status('Enter a valid email address.');return;}
 $('authSend').disabled=true;status('Requesting sign-in email…');
 try{
  const {error}=await client.auth.signInWithOtp({email,options:{emailRedirectTo:location.origin+location.pathname}});
  status(error?'Could not send sign-in email: '+error.message:'Check your inbox for a sign-in link. For Home Screen use, copy the link instead of opening it, then paste below.');
 }catch(e){status('Sign-in request failed: '+e.message)}
 finally{$('authSend').disabled=false}
});
$('authUseLink').addEventListener('click',async()=>{
 const raw=$('authPasteLink').value.trim();
 if(!raw){status('Paste your sign-in link from the email first.');return;}
 // Some mail clients paste a link surrounded by prose, quotes or angle brackets.
 // Never display or log the secret URL.
 const normalized=raw.replace(/&amp;/gi,'&').replace(/\\u0026/gi,'&');
 const match=normalized.match(/https?:\\/\\/[^\\s<>"']+/i);
 let u;
 if(match){try{u=new URL(match[0].replace(/[).,;]+$/,''))}catch(e){}}
 if(!u){
  const looksLikeUrl=/https?:\\/\\//i.test(raw);
  status(looksLikeUrl?'The copied text contains an incomplete or malformed URL. In Mail, press and hold the actual sign-in button and choose Copy Link.':'It looks like Mail copied the button text, not its URL. Press and hold the sign-in button in the email, then choose Copy Link.');
  return;
 }
 // Only accept the project’s own Supabase verification links. Never run arbitrary pasted URLs.
 if(u.protocol!=='https:'||u.origin!==URL||u.pathname!=='/auth/v1/verify'){
  status('Please paste the original Supabase sign-in link from the email, not a page URL or a link you already opened.');return;
 }
 const token_hash=u.searchParams.get('token')||u.searchParams.get('token_hash');
 const type=u.searchParams.get('type');
 if(!token_hash||!['magiclink','email'].includes(type)){
  status('This does not contain a usable email sign-in token. Request a new link and copy it directly from the email.');return;
 }
 $('authUseLink').disabled=true;status('Verifying your email link inside LiminalCreek…');
 try{
  const {error}=await client.auth.verifyOtp({token_hash,type});
  if(error)status('Link could not be verified: '+error.message+'. Request a fresh sign-in email if needed.');
  else {$('authPasteLink').value='';status('Signed in to this app successfully.');}
 }catch(e){status('Sign-in verification failed: '+e.message)}
 finally{$('authUseLink').disabled=false}
});
$('authSignOut').addEventListener('click',async()=>{const {error}=await client.auth.signOut();if(error)status(error.message)});
client.auth.onAuthStateChange((_event,session)=>render(session));
client.auth.getSession().then(({data,error})=>error?status(error.message):render(data.session)).catch(e=>status(e.message));
})();
