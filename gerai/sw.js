const CACHE='gerai-spg-prod-v5';
const BASE='/gerai/';
const SHELL=[BASE+'index.html',BASE+'manifest.webmanifest',BASE+'icon-192.png',BASE+'icon-512.png'];
self.addEventListener('install',event=>event.waitUntil(caches.open(CACHE).then(c=>c.addAll(SHELL)).then(()=>self.skipWaiting())));
// Hanya hapus cache milik PWA Gerai; cache PWA Owner tidak disentuh.
self.addEventListener('activate',event=>event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith('gerai-spg-')&&k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener('push',event=>{let d={};try{d=event.data?.json()||{}}catch(_){d={body:event.data?.text()||''}};event.waitUntil(self.registration.showNotification(d.title||'PWA Gerai',{body:d.body||'Ada pemberitahuan baru.',icon:BASE+'icon-192.png',badge:BASE+'icon-192.png',tag:d.notification_id||`gerai-${Date.now()}`,renotify:true,data:{url:d.url||BASE}}))});
self.addEventListener('notificationclick',event=>{event.notification.close();const target=event.notification.data?.url||BASE;event.waitUntil(clients.matchAll({type:'window',includeUncontrolled:true}).then(list=>{const u=new URL(target,self.location.origin);const hit=list.find(c=>c.url.includes(u.pathname));return hit?hit.focus():clients.openWindow(u.href)}))});
self.addEventListener('fetch',event=>{if(event.request.method!=='GET')return;const u=new URL(event.request.url);if(u.origin!==self.location.origin)return;if(!u.pathname.startsWith(BASE))return;
 if(event.request.mode==='navigate'){event.respondWith(fetch(event.request,{cache:'no-store'}).then(r=>{if(r.ok){const cp=r.clone();caches.open(CACHE).then(c=>c.put(BASE+'index.html',cp)).catch(()=>{});}return r}).catch(()=>caches.match(BASE+'index.html')));return}
 event.respondWith(fetch(event.request,{cache:'no-store'}).then(r=>{if(r.ok){const cp=r.clone();caches.open(CACHE).then(c=>c.put(event.request,cp)).catch(()=>{});}return r}).catch(()=>caches.match(event.request).then(h=>h||caches.match(BASE+'index.html'))))});
