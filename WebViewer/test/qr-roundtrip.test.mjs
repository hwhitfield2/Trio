// Trio Web Viewer — QR round trip. Run with:  node --test WebViewer/test
//
// The registration QR the page displays (vendored qrcode-generator) must be
// decodable by a scanner; jsQR — a fully independent decoder, and the same
// one the page itself uses for pairing codes — closes the loop offline.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { test } from 'node:test';

const require = createRequire(import.meta.url);
const qrcode = require('../js/vendor/qrcode.js');
const jsQR = require('../js/vendor/jsQR.js');

function rasterize(qr, scale, quiet) {
  const modules = qr.getModuleCount();
  const size = (modules + quiet * 2) * scale;
  const data = new Uint8ClampedArray(size * size * 4).fill(255);
  for (let row = 0; row < modules; row += 1) {
    for (let col = 0; col < modules; col += 1) {
      if (!qr.isDark(row, col)) continue;
      for (let y = 0; y < scale; y += 1) {
        for (let x = 0; x < scale; x += 1) {
          const px = (quiet + col) * scale + x;
          const py = (quiet + row) * scale + y;
          const offset = (py * size + px) * 4;
          data[offset] = 0;
          data[offset + 1] = 0;
          data[offset + 2] = 0;
        }
      }
    }
  }
  return { data, size };
}

test('a realistic registration payload survives encode → decode', () => {
  const payload = JSON.stringify({
    v: 1,
    type: 'trio-viewer-push',
    follower_id: '5E0F944E-31C2-4F5E-8E3E-0F1F0A9B6A21',
    endpoint:
      'https://fcm.googleapis.com/wp/dBx1QeGDT-abcdefghijklmnopqrstuvwxyz0123456789_ABCDEFGHIJKLMNOPQRSTUVWXYZ-0123456789abcdefghijk',
    p256dh:
      'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4',
    auth: 'BTBZMqHH6r4Tts7J_aSIgg',
    proof: 'maGS3DD81tN-7Vhv5ln-yydsICDDvOKbpnwR67H7b3M'
  });

  const qr = qrcode(0, 'L');
  qr.addData(payload, 'Byte');
  qr.make();
  const { data, size } = rasterize(qr, 4, 4);

  const decoded = jsQR(data, size, size);
  assert.ok(decoded, 'jsQR failed to locate the code');
  assert.equal(decoded.data, payload);
});

test('a pairing bundle the host renders also decodes', () => {
  // Shaped like FollowerPairingManager.makeViewerPairingPayload output.
  const payload = JSON.stringify({
    follower_id: '5E0F944E-31C2-4F5E-8E3E-0F1F0A9B6A21',
    follower_name: "Grandma's laptop",
    host_name: "Kid's iPhone",
    secret: 'u8Fyar0N5wCCPzXKvV9V3wJ0lC0T3rH2m8Q1a2b3c4d=',
    type: 'trio-viewer-pairing',
    units: 'mg/dL',
    v: 1,
    vapid_public_key:
      'BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8'
  });

  const qr = qrcode(0, 'L');
  qr.addData(payload, 'Byte');
  qr.make();
  const { data, size } = rasterize(qr, 4, 4);

  const decoded = jsQR(data, size, size);
  assert.ok(decoded, 'jsQR failed to locate the code');
  assert.equal(decoded.data, payload);
});
