// Service Worker: macht die Seiten installierbar und lädt sie offline aus dem Cache.
// Daten von Supabase werden nie zwischengespeichert.
const CACHE = 'messdiener-v8';
const SHELL = ['./', 'index.html', 'mini.html', 'theme.js', 'theme.css', 'qrcode.js', 'icons/favicon-32.png', 'icons/apple-touch-icon.png', 'icons/icon-192.png', 'icons/icon-512.png', 'icons/icon-maskable-512.png', 'icons/church-logo.png', 'icons/logo-192.png'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.hostname.endsWith('supabase.co')) return; // Daten immer live
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return;
  // Netzwerk zuerst, damit Updates sofort ankommen; ohne Netz greift der Cache
  e.respondWith(
    fetch(req).then((res) => {
      if (res && (res.ok || res.type === 'opaque')) {
        const copy = res.clone();
        caches.open(CACHE).then((c) => c.put(req, copy));
      }
      return res;
    }).catch(() => caches.match(req).then((hit) => hit || (req.mode === 'navigate' ? caches.match('index.html') : Response.error())))
  );
});

// ---------- Web Push (Vertretungsanfragen) ----------
self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data.json(); } catch (_) { d = { title: 'Messdienst', body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Messdienst', {
    body: d.body || '',
    icon: 'icons/icon-192.png',
    badge: 'icons/favicon-32.png',
    tag: d.tag,
    data: { url: d.url || 'mini.html' },
  }));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const target = new URL((e.notification.data && e.notification.data.url) || 'mini.html', self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
    for (const c of list) {
      if (c.url.indexOf(self.registration.scope + 'mini.html') === 0 && 'focus' in c) {
        c.postMessage({ type: 'vertretung' });
        return c.focus();
      }
    }
    return self.clients.openWindow(target);
  }));
});
