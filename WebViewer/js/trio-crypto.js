// Trio Web Viewer — crypto helpers shared by the page and the service worker.
//
// Everything here mirrors the host's Swift implementation byte for byte:
//   - SecureMessenger.swift: AES-256-GCM, key = SHA-256(UTF-8 secret string),
//     wire = base64(nonce[12] || ciphertext || tag[16]).
//   - PairedFollower.verificationCode: first 4 bytes of SHA-256(secret) as a
//     big-endian uint32, mod 10^6, zero-padded to six digits.
//   - WebViewerPushRegistration.proof: HMAC-SHA-256 over the newline-joined
//     registration fields, keyed by the UTF-8 secret, unpadded base64url.
//
// Loaded as a classic script (<script> / importScripts) and by the Node test
// suite; it defines a single TrioCrypto global and touches nothing else.
(function (root) {
  'use strict';

  const subtle = (root.crypto || globalThis.crypto).subtle;
  const encoder = new TextEncoder();

  function bytesToBase64(bytes) {
    let binary = '';
    for (let i = 0; i < bytes.length; i += 1) binary += String.fromCharCode(bytes[i]);
    return btoa(binary);
  }

  function base64ToBytes(base64) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }

  function base64urlToBytes(base64url) {
    let base64 = base64url.replace(/-/g, '+').replace(/_/g, '/');
    while (base64.length % 4 !== 0) base64 += '=';
    return base64ToBytes(base64);
  }

  function bytesToBase64url(bytes) {
    return bytesToBase64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }

  async function aesKey(secret) {
    const digest = await subtle.digest('SHA-256', encoder.encode(secret));
    return subtle.importKey('raw', digest, { name: 'AES-GCM' }, false, ['decrypt']);
  }

  // Decrypts one SecureMessenger envelope and parses the JSON inside.
  // Throws on a bad key, tampered data, or malformed JSON.
  async function decryptEnvelope(secret, base64) {
    const combined = base64ToBytes(base64);
    if (combined.length <= 12 + 16) throw new Error('Encrypted payload too short');
    const iv = combined.slice(0, 12);
    const ciphertextAndTag = combined.slice(12);
    const key = await aesKey(secret);
    const plaintext = await subtle.decrypt({ name: 'AES-GCM', iv, tagLength: 128 }, key, ciphertextAndTag);
    return JSON.parse(new TextDecoder().decode(plaintext));
  }

  async function verificationCode(secret) {
    const digest = new Uint8Array(await subtle.digest('SHA-256', encoder.encode(secret)));
    // Big-endian uint32 of the first 4 bytes; >>> 0 keeps it unsigned.
    const value = ((digest[0] << 24) | (digest[1] << 16) | (digest[2] << 8) | digest[3]) >>> 0;
    return String(value % 1000000).padStart(6, '0');
  }

  async function registrationProof(secret, followerId, endpoint, p256dh, auth) {
    const key = await subtle.importKey(
      'raw',
      encoder.encode(secret),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign']
    );
    const message = ['trio-viewer-push', followerId, endpoint, p256dh, auth].join('\n');
    const mac = await subtle.sign('HMAC', key, encoder.encode(message));
    return bytesToBase64url(new Uint8Array(mac));
  }

  root.TrioCrypto = {
    bytesToBase64,
    base64ToBytes,
    base64urlToBytes,
    bytesToBase64url,
    decryptEnvelope,
    verificationCode,
    registrationProof
  };
})(typeof self !== 'undefined' ? self : globalThis);
