const CACHE='gerai-spg-prod-v13';
const BASE='/gerai/';
const CDN='https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.57.0/dist/umd/supabase.min.js';
const SHELL=[BASE+'index.html',BASE+'manifest.webmanifest',BASE+'icon-192.png',BASE+'icon-512.png'];
self.addEventListener('install',event=>event.waitUntil(caches.open(CACHE).then(c=>Promise.all([c.addAll(SHELL),fetch(CDN,{mode:'no-cors'}).then(r=>c.put(CDN,r)).catch(()=>{})])).then(()=>self.skipWaiting())));
// Hanya hapus cache milik PWA Gerai; cache PWA Owner tidak disentuh.
self.addEventListener('activate',event=>event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith('gerai-spg-')&&k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener('push',event=>{let d={};try{d=event.data?.json()||{}}catch(_){d={body:event.data?.text()||''}};event.waitUntil(self.registration.showNotification(d.title||'PWA Gerai',{body:d.body||'Ada pemberitahuan baru.',icon:BASE+'icon-192.png',badge:BASE+'icon-192.png',tag:d.notification_id||`gerai-${Date.now()}`,renotify:true,data:{url:d.url||BASE}}))});
self.addEventListener('notificationclick',event=>{event.notification.close();const target=event.notification.data?.url||BASE;event.waitUntil(clients.matchAll({type:'window',includeUncontrolled:true}).then(list=>{const u=new URL(target,self.location.origin);const hit=list.find(c=>c.url.includes(u.pathname));return hit?hit.focus():clients.openWindow(u.href)}))});
function netFirst(req,ms){return new Promise((res,rej)=>{const t=setTimeout(()=>rej(new Error('timeout')),ms);fetch(req,{cache:'no-store'}).then(r=>{clearTimeout(t);res(r)},e=>{clearTimeout(t);rej(e)})})}
self.addEventListener('fetch',event=>{
 if(event.request.method!=='GET')return;
 // Library Supabase: cache-first agar aplikasi cepat terbuka dan tetap jalan offline.
 if(event.request.url===CDN){event.respondWith(caches.match(CDN).then(h=>h||fetch(CDN,{mode:'no-cors'}).then(r=>{const cp=r.clone();caches.open(CACHE).then(c=>c.put(CDN,cp)).catch(()=>{});return r})));return}
 const u=new URL(event.request.url);if(u.origin!==self.location.origin)return;if(!u.pathname.startsWith(BASE))return;if(/\/qr-drop\/?$/.test(u.pathname)||u.pathname.startsWith(BASE+'qr-drop/'))return;
 // Halaman: ambil versi terbaru, tetapi jika jaringan lambat (>3 dtk) langsung pakai salinan tersimpan.
 if(event.request.mode==='navigate'){event.respondWith(netFirst(event.request,3000).then(r=>{if(r.ok){const cp=r.clone();caches.open(CACHE).then(c=>c.put(BASE+'index.html',cp)).catch(()=>{});}return r}).catch(()=>caches.match(BASE+'index.html').then(h=>h||fetch(event.request))));return}
 // Ikon & manifest: cache-first, diperbarui di latar belakang.
 event.respondWith(caches.match(event.request).then(h=>{const net=fetch(event.request).then(r=>{if(r.ok){const cp=r.clone();caches.open(CACHE).then(c=>c.put(event.request,cp)).catch(()=>{});}return r}).catch(()=>h||caches.match(BASE+'index.html'));return h||net}))});
