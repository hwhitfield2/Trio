// Trio Web Viewer — tiny IndexedDB key-value store shared by the page and the
// service worker. IndexedDB rather than localStorage because the service
// worker has no localStorage, and both sides need the same pairing record.
//
// Keys in use:
//   pairing   — {followerId, followerName, hostName, secret, units,
//                vapidPublicKey, pairedAt}
//   snapshot  — {data: <decrypted status snapshot>, receivedAt}
//   prefs     — {statusNotifications: bool}
//   needsReregistration — bool; set when the browser's push subscription
//                changed and the host must scan a fresh registration code.
(function (root) {
  'use strict';

  const DB_NAME = 'trio-viewer';
  const STORE = 'kv';

  function open() {
    return new Promise((resolve, reject) => {
      const request = indexedDB.open(DB_NAME, 1);
      request.onupgradeneeded = () => {
        request.result.createObjectStore(STORE);
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
  }

  async function withStore(mode, run) {
    const db = await open();
    try {
      return await new Promise((resolve, reject) => {
        const tx = db.transaction(STORE, mode);
        const result = run(tx.objectStore(STORE));
        tx.oncomplete = () => resolve(result.request ? result.request.result : undefined);
        tx.onerror = () => reject(tx.error);
        tx.onabort = () => reject(tx.error);
      });
    } finally {
      db.close();
    }
  }

  root.TrioStore = {
    get(key) {
      return withStore('readonly', (store) => ({ request: store.get(key) }));
    },
    set(key, value) {
      return withStore('readwrite', (store) => ({ request: store.put(value, key) }));
    },
    remove(key) {
      return withStore('readwrite', (store) => ({ request: store.delete(key) }));
    },
    clearAll() {
      return withStore('readwrite', (store) => ({ request: store.clear() }));
    }
  };
})(typeof self !== 'undefined' ? self : globalThis);
