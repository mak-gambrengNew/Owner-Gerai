/*
 * UNIVERSAL PWA SERVICE WORKER
 * Update-first, aman untuk repo dengan struktur file berbeda.
 *
 * Prinsip:
 * 1. HTML selalu mencoba server terlebih dahulu.
 * 2. JS/CSS/gambar/font/manifest juga mencoba server terlebih dahulu.
 * 3. Cache hanya dipakai sebagai fallback saat jaringan gagal.
 * 4. Tidak ada cache.addAll() sehingga satu file yang hilang tidak
 *    menggagalkan instalasi service worker.
 * 5. Service worker baru langsung mengambil alih halaman yang tersedia.
 */

const SW_VERSION = 'pwa-update-2026-10-09-checker-isolation';
const CACHE_NAME = `${SW_VERSION}-cache`;

self.addEventListener('install', event => {
  // Tidak melakukan precache file tertentu.
  // Ini membuat SW aman dipakai di repo dengan struktur berbeda.
  event.waitUntil(self.skipWaiting());
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys
          .filter(key => key.startsWith('pwa-update-') && key !== CACHE_NAME)
          .map(key => caches.delete(key))
      ))
      .then(() => self.clients.claim())
  );
});

function shouldHandle(request, url) {
  if (request.method !== 'GET') return false;
  if (url.origin !== self.location.origin) return false;

  // Area /gerai/ adalah PWA terpisah dengan service worker sendiri.
  if (url.pathname === '/gerai' || url.pathname.startsWith('/gerai/')) return false;

  // Area /checker/ adalah PWA terpisah dengan service worker sendiri.
  if (url.pathname === '/checker' || url.pathname.startsWith('/checker/')) return false;

  // Jangan pernah mencegat service worker itu sendiri.
  if (url.pathname.endsWith('/sw.js')) return false;

  return true;
}

function isDocument(request, url) {
  return request.mode === 'navigate' ||
    request.destination === 'document' ||
    url.pathname.endsWith('/') ||
    url.pathname.endsWith('/index.html');
}

function isStaticAsset(request) {
  return [
    'script',
    'style',
    'image',
    'font',
    'manifest',
    'worker'
  ].includes(request.destination);
}

async function networkFirst(request) {
  const cache = await caches.open(CACHE_NAME);

  try {
    const response = await fetch(request, {
      cache: 'no-store'
    });

    if (response && response.ok) {
      await cache.put(request, response.clone());
    }

    return response;
  } catch (error) {
    const cached = await cache.match(request);
    if (cached) return cached;
    throw error;
  }
}

self.addEventListener('fetch', event => {
  const request = event.request;
  const url = new URL(request.url);

  if (!shouldHandle(request, url)) return;

  // HTML: selalu server-first.
  if (isDocument(request, url)) {
    event.respondWith(networkFirst(request));
    return;
  }

  // Asset aplikasi: server-first, cache hanya sebagai fallback.
  if (isStaticAsset(request)) {
    event.respondWith(networkFirst(request));
    return;
  }

  // Request lain tidak dicegat. Ini penting agar API/data dinamis
  // tidak tersimpan di cache service worker.
});

self.addEventListener('message', event => {
  const data = event.data;
  if (!data) return;

  if (data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }

  if (data.type === 'GET_VERSION' && event.source) {
    event.source.postMessage({
      type: 'SW_VERSION',
      version: SW_VERSION
    });
  }
});
