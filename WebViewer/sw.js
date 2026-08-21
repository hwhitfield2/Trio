// Trio Web Viewer — service worker.
//
// Receives the host's web pushes, decrypts them with the pairing secret from
// IndexedDB, stores the newest snapshot, and tells any open page. When no
// page is visible it maintains one silent, tag-replaced notification showing
// the current glucose — that is both the Chrome-required user-visible outcome
// of a push and a live readout in the notification shade. Alert pushes become
// real notifications.
//
// The app shell is cached so the viewer opens (with its last data) offline.
/* global TrioCrypto, TrioStore */
importScripts('./js/trio-crypto.js', './js/store.js', './js/format.js');

const CACHE_NAME = 'trio-viewer-v1';
const APP_SHELL = [
  './',
  './index.html',
  './style.css',
  './manifest.webmanifest',
  './js/trio-crypto.js',
  './js/store.js',
  './js/format.js',
  './js/chart.js',
  './js/app.js',
  './js/vendor/qrcode.js',
  './js/vendor/jsQR.js',
  './icons/icon.svg',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/apple-touch-icon.png'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_SHELL)).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET' || new URL(request.url).origin !== self.location.origin) return;
  event.respondWith(
    caches.match(request, { ignoreSearch: request.mode === 'navigate' }).then((cached) => {
      const network = fetch(request)
        .then((response) => {
          if (response.ok) {
            const copy = response.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(request, copy));
          }
          return response;
        })
        .catch(() => cached || caches.match('./index.html'));
      return cached || network;
    })
  );
});

async function anyVisibleClient() {
  const clients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
  return clients.some((client) => client.visibilityState === 'visible');
}

async function tellClients(message) {
  const clients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
  for (const client of clients) client.postMessage(message);
}

async function handleStatusPush(pairing, encrypted) {
  const snapshot = await TrioCrypto.decryptEnvelope(pairing.secret, encrypted);
  if (!snapshot || snapshot.type !== 'status') return;

  // Pushes can arrive out of order; never replace a snapshot with an older one.
  const stored = await TrioStore.get('snapshot');
  if (stored && stored.data && stored.data.timestamp >= snapshot.timestamp) return;

  await TrioStore.set('snapshot', { data: snapshot, receivedAt: Date.now() });
  await tellClients({ type: 'snapshot' });

  if (await anyVisibleClient()) return;

  // A background push must always end in a visible notification — that is
  // the userVisibleOnly contract, and Chrome substitutes its own generic
  // notice otherwise. The preference only controls whether glucose values
  // appear in it (a lock-screen privacy choice), never whether it is shown.
  const prefs = (await TrioStore.get('prefs')) || {};
  const showValues = prefs.statusNotifications !== false;

  const units = snapshot.units || 'mg/dL';
  const reading = (snapshot.readings || [])[0];
  const title = showValues && reading
    ? `${TrioFormat.displayGlucose(reading.sgv, units)} ${units} ${TrioFormat.arrow(reading.direction)}`.trim()
    : 'Trio Viewer';
  const parts = [];
  if (showValues) {
    if (typeof snapshot.iob === 'number') parts.push(`IOB ${snapshot.iob.toFixed(2)} U`);
    if (typeof snapshot.cob === 'number') parts.push(`COB ${Math.round(snapshot.cob)} g`);
    if (snapshot.suspended) parts.push('Insulin suspended');
    if (reading) parts.push(`as of ${new Date(reading.date * 1000).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}`);
  } else {
    parts.push('Updated in the background.');
  }

  await self.registration.showNotification(title, {
    body: parts.join(' · '),
    tag: 'trio-status',
    renotify: false,
    silent: true,
    icon: './icons/icon-192.png',
    badge: './icons/icon-192.png',
    data: { kind: 'status' }
  });
}

async function handleAlertPush(pairing, encrypted) {
  const alert = await TrioCrypto.decryptEnvelope(pairing.secret, encrypted);
  if (!alert || alert.type !== 'alert') return;
  // A stale queued alert (the browser was offline) is history, not news.
  if (typeof alert.timestamp === 'number' && Date.now() / 1000 - alert.timestamp > 3600) return;

  const silent = alert.sound === 'silent';
  await self.registration.showNotification(alert.title || 'Trio', {
    body: alert.body || '',
    tag: `trio-alert-${alert.timestamp || Date.now()}`,
    silent,
    vibrate: silent ? undefined : [200, 100, 200, 100, 200],
    icon: './icons/icon-192.png',
    badge: './icons/icon-192.png',
    data: { kind: 'alert' }
  });
}

self.addEventListener('push', (event) => {
  event.waitUntil((async () => {
    let payload;
    try {
      payload = event.data ? event.data.json() : null;
    } catch (error) {
      return;
    }
    if (!payload) return;

    const pairing = await TrioStore.get('pairing');
    if (!pairing || payload.follower_id !== pairing.followerId) return;

    try {
      if (payload.encrypted_status) {
        await handleStatusPush(pairing, payload.encrypted_status);
      } else if (payload.encrypted_alert) {
        await handleAlertPush(pairing, payload.encrypted_alert);
      }
      // Anything else (e.g. encrypted_host_update) is not for viewers.
    } catch (error) {
      // A payload that fails authentication is not ours to show.
    }
  })());
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil((async () => {
    const clients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    if (clients.length > 0) {
      await clients[0].focus();
    } else {
      await self.clients.openWindow('./');
    }
  })());
});

// The push service rotated our subscription. We can resubscribe ourselves,
// but only the host user scanning a fresh registration code can tell the
// host about it — so flag it and make it visible.
self.addEventListener('pushsubscriptionchange', (event) => {
  event.waitUntil((async () => {
    await TrioStore.set('needsReregistration', true);
    await tellClients({ type: 'needsReregistration' });
    await self.registration.showNotification('Trio Viewer needs re-pairing', {
      body: 'The browser renewed its push registration. Open the viewer and scan the new code with Trio.',
      tag: 'trio-reregister',
      icon: './icons/icon-192.png'
    });
  })());
});
