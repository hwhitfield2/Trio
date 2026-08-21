// Trio Web Viewer — crypto tests. Run with:  node --test WebViewer/test
//
// The vectors are shared with the host's Swift tests
// (TrioTests/WebViewerPairingTests.swift, TrioTests/FollowerPairingTests.swift)
// and were generated with an independent implementation, so both sides of the
// wire are pinned to the same bytes.
import assert from 'node:assert/strict';
import { test } from 'node:test';

import '../js/trio-crypto.js';
import '../js/format.js';
import '../js/chart.js';

const { TrioCrypto, TrioFormat, TrioChart } = globalThis;

const SECRET = 'viewer-test-secret';

// base64(nonce 0x01..0x0c || AES-256-GCM(snapshot JSON)) with
// key = SHA-256("viewer-test-secret") — from scripts in the feature branch.
const STATUS_WIRE =
  'AQIDBAUGBwgJCgsMqjHhvPDa/6jA246BvYiTBqEpI9VbzzdI0BQuL1fuUjtCN3FC+bJWf/IBpVlhLcDnYQC/xWHo9fzfb/UoIsvuBkTbkK60N3gmnWJWB8eUVeS49tgl8KH/crORyRXRtN/o70a5wMjB8e4e/sc8Ki9gKeMM+WYlIotpaNh30Q0SzccI0XZV1/ruQ+LR0LekyCL6zpbxqqhTRh1fLA==';

const ALERT_WIRE =
  'AQIDBAUGBwgJCgsMqjHgvPaB56PXsMCdsYXCWbAyJcAaimpJ/V5lbRLuH3R3KHEcurNBOq1e5kl+PI23O1X8nSLh7KyAPbZzfpH8DFatzOPiYT1wgmACH9/xF7mqi6hytPjwIOCw2h/E+JH5lBv91tTTtadet8dycT5pbqtaqG+fhPLsJnYbHjh0JPRtrWt+';

test('decrypts a SecureMessenger status envelope', async () => {
  const snapshot = await TrioCrypto.decryptEnvelope(SECRET, STATUS_WIRE);
  assert.equal(snapshot.type, 'status');
  assert.equal(snapshot.units, 'mg/dL');
  assert.equal(snapshot.timestamp, 1723400000);
  assert.equal(snapshot.iob, 1.25);
  assert.equal(snapshot.cob, 15);
  assert.equal(snapshot.readings.length, 1);
  assert.equal(snapshot.readings[0].sgv, 104);
  assert.equal(snapshot.readings[0].direction, 'Flat');
});

test('decrypts an alert envelope', async () => {
  const alert = await TrioCrypto.decryptEnvelope(SECRET, ALERT_WIRE);
  assert.equal(alert.type, 'alert');
  assert.equal(alert.title, 'Trio · Urgent Low');
  assert.equal(alert.body, 'Glucose 54 mg/dL.');
  // "urgent" is a FollowerAlertSound raw value — what the host actually
  // sends — not the name of the alert rule that chose it.
  assert.equal(alert.sound, 'urgent');
});

test('rejects a tampered envelope and a wrong secret', async () => {
  const tampered = STATUS_WIRE.slice(0, 40) + (STATUS_WIRE[40] === 'A' ? 'B' : 'A') + STATUS_WIRE.slice(41);
  await assert.rejects(() => TrioCrypto.decryptEnvelope(SECRET, tampered));
  await assert.rejects(() => TrioCrypto.decryptEnvelope('some-other-secret', STATUS_WIRE));
});

test('verification code matches the host derivation', async () => {
  assert.equal(await TrioCrypto.verificationCode(SECRET), '905993');
  // Same vectors as TrioTests/FollowerPairingTests.swift.
  assert.equal(await TrioCrypto.verificationCode('test-secret'), '716219');
  assert.equal(
    await TrioCrypto.verificationCode('u8Fyar0N5wCCPzXKvV9V3wJ0lC0T3rH2m8Q1a2b3c4d='),
    '714600'
  );
});

test('registration proof matches the host verification', async () => {
  const proof = await TrioCrypto.registrationProof(
    SECRET,
    '5E0F944E-31C2-4F5E-8E3E-0F1F0A9B6A21',
    'https://fcm.googleapis.com/wp/example-subscription-token',
    'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4',
    'BTBZMqHH6r4Tts7J_aSIgg'
  );
  assert.equal(proof, 'maGS3DD81tN-7Vhv5ln-yydsICDDvOKbpnwR67H7b3M');
});

test('base64url helpers round-trip browser subscription keys', () => {
  const bytes = TrioCrypto.base64urlToBytes('BTBZMqHH6r4Tts7J_aSIgg');
  assert.equal(bytes.length, 16);
  assert.equal(TrioCrypto.bytesToBase64url(bytes), 'BTBZMqHH6r4Tts7J_aSIgg');
});

test('glucose formatting follows the host units', () => {
  assert.equal(TrioFormat.displayGlucose(104, 'mg/dL'), '104');
  assert.equal(TrioFormat.displayGlucose(104, 'mmol/L'), '5.8');
  assert.equal(TrioFormat.arrow('Flat'), '→');
  assert.equal(TrioFormat.arrow('DoubleDown'), '↓↓');
  assert.equal(TrioFormat.arrow('unheard-of'), '');
});

test('reading state uses the host display ranges', () => {
  const ranges = { low: 80, high: 160 };
  assert.equal(TrioChart.stateClass(70, ranges), 'bg-low');
  assert.equal(TrioChart.stateClass(120, ranges), 'bg-in-range');
  assert.equal(TrioChart.stateClass(200, ranges), 'bg-high');
  // No ranges from an older host: fall back to 70/180.
  assert.equal(TrioChart.stateClass(69, null), 'bg-low');
  assert.equal(TrioChart.stateClass(181, null), 'bg-high');
});
