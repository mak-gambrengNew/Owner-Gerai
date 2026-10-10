/* SERVICE WORKER PWA CHECKER — scope: /checker/
 * Isolasi: hanya mengelola cache berawalan "checker-"; tidak menyentuh cache Owner
 * ("pwa-update-*") maupun Gerai ("gerai-spg-*"). Hanya mencegat request GET same-origin
 * di bawah /checker/. API Supabase (cross-origin) tidak pernah dicegat atau disimpan. */
const PREFIX='checker-';
const CACHE='checker-v3-isolated';
const BASE='/checker/';
const SHELL=[BASE,BASE+'index.html',BASE+'checker-manifest.webmanifest',BASE+'checker_logo.png'];
self.addEventListener('install',e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(SHELL)).then(()=>self.skipWaiting())));
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith(PREFIX)&&k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener('fetch',e=>{
  const r=e.request;
  if(r.method!=='GET')return;
  const u=new URL(r.url);
  if(u.origin!==self.location.origin)return;
  if(!u.pathname.startsWith(BASE))return;
  if(u.pathname===BASE+'checker-sw.js')return;
  const isNav=r.mode==='navigate';
  e.respondWith(fetch(r).then(res=>{
    if(res.ok&&(isNav||SHELL.includes(u.pathname))){const c=res.clone();caches.open(CACHE).then(x=>x.put(isNav?BASE+'index.html':r,c)).catch(()=>{});}
    return res;
  }).catch(()=>caches.open(CACHE).then(c=>isNav?c.match(BASE+'index.html'):c.match(r)).then(h=>h||Response.error())));
});
