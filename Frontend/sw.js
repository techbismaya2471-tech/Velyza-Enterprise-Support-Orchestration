const CACHE = 'velyza-v3';
const ASSETS = ['/', '/index.html', '/manifest.json'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ASSETS)));
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys =>
    Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
  ));
});

self.addEventListener('fetch', e => {
  // API calls — cache mat karo, hamesha network se lo
  if (e.request.url.includes('/chat') || 
      e.request.url.includes('vercel.app/chat')) {
    e.respondWith(fetch(e.request));
    return; 
  }
  // Static files — cache se lo
  e.respondWith(
    fetch(e.request).catch(() => caches.match(e.request))
  );
});