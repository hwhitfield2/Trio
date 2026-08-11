# Trio Follower

A companion app for [Trio](https://github.com/nightscout/Trio) that runs on
**iOS and Android** (single Flutter codebase). It pairs with a Trio host phone
by scanning a QR code and can then perform the host's remote-controllable
therapy actions from anywhere:

- **Bolus** (validated against the host's max-bolus and safety rules)
- **Meal** (carbs / fat / protein, optionally with a bolus)
- **Temporary targets** (start and cancel)
- **Overrides** (start and cancel presets defined on the host)

It also shows live glucose, IOB and COB from the host's Nightscout site when
one is configured.

## How it works

```
Follower app ──(AES-256-GCM encrypted command over APNS HTTP/2)──▶ Apple ──▶ Trio host
     │                                                                        │
     └──────────────(read-only status via Nightscout REST)◀───────────────────┘
```

- Commands are **end-to-end encrypted** with a per-follower secret created
  during pairing. Apple only relays an opaque blob.
- The host identifies the sender via `follower_id`, decrypts with that
  follower's key, checks the command timestamp (±10 min) **and** a strictly
  increasing sequence number, so captured pushes can never be replayed.
- Each follower can be individually revoked on the host at any time
  (Settings → Remote Control → swipe a follower → Revoke).
- Commands run through the exact same safety validation as any other remote
  command on the host (max bolus, recent-bolus guards, etc.). The follower
  additionally enforces the host's limits in its UI before sending.

### Pairing

1. On the Trio host: Settings → Remote Control → enable remote control, enter
   the APNS credentials (Team ID, Key ID, `.p8` key of the Apple Developer
   account that built Trio) once, then tap **Pair New Follower** and name the
   device.
2. On the follower: tap **Scan pairing code** and scan the QR code.
3. Both devices display the same six-digit verification code. Confirm on the
   follower only if they match.

The QR code carries the per-follower secret, the host's push address (APNS
device token, bundle ID, environment), the APNS key, optional Nightscout
credentials, and the host's safety limits — one scan, no manual secrets.
Treat it like a password; never screenshot or share it. On the follower it is
stored in the iOS Keychain / Android Keystore.

Sending a command requires an in-app confirmation plus Face ID / Touch ID /
biometric or device credential where available.

## Building

Prerequisites: [Flutter](https://docs.flutter.dev/get-started/install) ≥ 3.22.

The repository intentionally contains only the Dart code and project
metadata; generate the platform shells once after cloning:

```bash
cd FollowerApp
flutter create . --platforms=ios,android --project-name trio_follower --org org.nightscout
flutter pub get
flutter test
```

Then add the required platform permissions:

**iOS — `ios/Runner/Info.plist`:**

```xml
<key>NSCameraUsageDescription</key>
<string>Scan the pairing QR code shown on the Trio host.</string>
<key>NSFaceIDUsageDescription</key>
<string>Confirm remote commands before they are sent.</string>
```

**Android — `android/app/src/main/AndroidManifest.xml`** (mobile_scanner adds
the camera permission automatically; biometric confirmation needs):

```xml
<uses-permission android:name="android.permission.USE_BIOMETRIC" />
```

and `local_auth` requires `MainActivity` to extend `FlutterFragmentActivity`
instead of `FlutterActivity`.

Run on a device:

```bash
flutter run
```

> **Note (Android + APNS):** followers on Android send commands to the iOS
> host through Apple's push API directly — it is a plain HTTPS/2 request, so
> no Google/Firebase services are needed and the app works on any Android
> device with internet access.

## Protocol compatibility

The command wire format is byte-compatible with Trio's
`SecureMessenger`/`CommandPayload` (see `docs/FOLLOWER_APP.md` in the repo
root for the full protocol specification). If you change either side, change
both and bump the pairing-bundle version.

## Limitations

- Command *delivery* is confirmed (APNS accepted the push), but command
  *execution* feedback comes from the host: Trio posts result notifications
  and treatments to Nightscout, which this app surfaces on the status screen.
- Pump management, CGM setup, and settings changes are deliberately not
  remote-controllable — those require physical access to the host device.
- The host must be online (the push wakes Trio in the background). Scheduled
  commands survive short offline windows via APNS storage, subject to the
  host's ±10 minute command freshness window.
