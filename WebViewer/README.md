# Trio Web Viewer

A read-only browser follower for Trio: glucose, insulin and carb data in any
modern browser, delivered end-to-end encrypted from the Trio phone over Web
Push. It can never send commands — the pairing it receives contains no
control credentials at all (see *Security model* below and
`docs/FOLLOWER_APP.md`, section *Web viewer*).

This directory is a static site with no build step, no dependencies to
install, and no server-side code. The page makes **zero network requests of
its own** after loading: data arrives exclusively as pushes from the host.

## Hosting

Serve the directory as-is from any static host **over HTTPS** (a service
worker and Web Push require a secure origin):

- GitHub Pages: point Pages at this folder (or copy it into a `gh-pages`
  branch).
- Cloudflare Pages / Netlify: drop the folder in, no build command.
- Any web server: `cp -r WebViewer/* /var/www/...`.

Every caregiver can use the same hosted copy — pairings live in each
browser, not on the server. Nothing sensitive is ever sent to the host of
the static files.

## Pairing

1. On the Trio phone: **Settings → Remote Control → Pair Web Viewer**, give
   the viewer a name.
2. In the browser: open the viewer, **Scan Pairing Code** (or paste the
   copied code).
3. Compare the six-digit verification code on both screens, confirm.
4. The browser subscribes for pushes and displays its own QR code; in Trio,
   tap **Scan Browser Code** and point the phone at the browser. Data
   appears moments later.

On iPhone/iPad the page must first be added to the Home Screen
(Share → Add to Home Screen) and opened from there — iOS only allows web
push for installed web apps. Desktop Chrome, Edge, Firefox and Safari work
as normal tabs.

## What the viewer shows

- Current glucose with trend arrow, colored by the host's own display
  ranges (the same color the reading has on the host's screen).
- IOB, COB, eventual BG, time of the last loop.
- A 6-hour chart with boluses (▼, SMBs drawn smaller and unlabeled) and
  carbs (●).
- Active temp target or override, and an insulin-suspension banner.
- A staleness banner when no data has arrived for 15 minutes.
- Optionally, a silent notification with the current reading while the page
  is in the background — plus the glucose alerts configured for this viewer
  on the host (per-follower alert settings apply to viewers too).

## Security model

- **No control capability.** The pairing bundle contains the viewer's data
  secret and the host's VAPID *public* key — no APNS credentials, no host
  push address. There is nothing in this browser that could address the
  host. The host additionally refuses every command from a view-only
  pairing (`TrioRemoteControl`).
- **End-to-end encryption, twice.** Payloads are AES-256-GCM encrypted with
  the per-viewer pairing secret (exactly like app followers), inside Web
  Push's own `aes128gcm` encryption to keys only this browser holds. The
  push service relays ciphertext it cannot read; a captured subscription
  cannot be used to forge data the viewer would accept.
- **Authenticated registration.** The browser's subscription QR carries an
  HMAC over its contents with the pairing secret, so the host only accepts
  a registration from the party that actually scanned the pairing code.
- **Revocation.** Revoke the viewer on the host (swipe → Revoke) at any
  time; pushes stop immediately. "Unpair This Viewer" in the page's
  settings wipes the browser side.
- Treat the pairing code like a password: whoever captures it can *read*
  this Trio's data until the viewer is revoked.

## Tests

```
cd WebViewer
node --test test/crypto.test.mjs test/qr-roundtrip.test.mjs
```

The crypto vectors are shared with the host's Swift tests
(`TrioTests/WebViewerPairingTests.swift`), pinning both sides of the wire to
the same bytes.

## Third-party code

- `js/vendor/qrcode.js` — QR code generator, © Kazuhiko Arase, MIT license
  (header in the file). "QR Code" is a registered trademark of DENSO WAVE.
- `js/vendor/jsQR.js` — QR decoder, © Daniel Cohen, Apache License 2.0
  (`js/vendor/jsQR.LICENSE.txt`).
