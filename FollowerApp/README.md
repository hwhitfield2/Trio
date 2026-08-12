# Trio Follower

A companion app for [Trio](https://github.com/nightscout/Trio) that runs on
**iOS and Android** (single Flutter codebase). It pairs with a Trio host phone
by scanning a QR code and can then perform the host's remote-controllable
therapy actions from anywhere:

- **Bolus** (validated against the host's max-bolus and safety rules)
- **Meal** (carbs / fat / protein, optionally with a bolus)
- **Temporary targets** (start and cancel)
- **Overrides** (start and cancel presets defined on the host)

It also shows live glucose, IOB, COB, loop state and active targets/overrides
— **pushed end-to-end encrypted straight from the host device**. There is no
Nightscout and no other third-party data service anywhere in the loop.

The same data is available on the **home screen**, on both platforms: an iOS
widget (small, medium, and the three lock screen sizes) and an Android app
widget. Both are redrawn whenever a status push arrives, including while the
app is in the background — see [Home screen widgets](#home-screen-widgets).

## How it works

```
Follower app ──(AES-256-GCM encrypted command over APNS HTTP/2)──▶ Apple ──▶ Trio host
     ▲                                                                        │
     └──(AES-256-GCM encrypted status pushed via APNS (iOS) / FCM (Android))──┘
```

- Commands are **end-to-end encrypted** with a per-follower secret created
  during pairing. Apple only relays an opaque blob.
- The host pushes an encrypted **status snapshot** to every paired follower
  on each glucose/loop update, right after every command (so you see the
  effect immediately), and on demand via pull-to-refresh. Data exists only on
  the host and paired followers — the push services carry ciphertext.
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
device token, bundle ID, environment), the APNS key, and the host's safety
limits — one scan, no manual secrets.
Treat it like a password; never screenshot or share it. On the follower it is
stored in the iOS Keychain / Android Keystore.

Sending a command requires an in-app confirmation plus Face ID / Touch ID /
biometric or device credential where available.

## Building

### CI/CD (recommended)

The repository's GitHub Actions build the follower for you:

- **"5. Build Trio Follower"** (`build_follower.yml`) — run it from the
  Actions tab (or push to `main` touching `FollowerApp/`). It ships the iOS
  app to **TestFlight** using the same fastlane/match secrets as "4. Build
  Trio", and attaches an installable **Android APK** as a workflow artifact.
  One-time prerequisites:
  1. Run **"2. Add Identifiers"** once — it also creates the follower bundle id
     (`org.nightscout.<TEAMID>.triofollower`) with push notifications, creates
     the widget bundle id (`…triofollower.widget`), and reports whether the App
     Store Connect app record below exists.
  1b. Add the **Trio App Group** to both follower identifiers by hand, at
     [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list):
     open `org.nightscout.<TEAMID>.triofollower` and
     `org.nightscout.<TEAMID>.triofollower.widget`, and under **App Groups**
     click Configure and select **Trio App Group**
     (`group.org.nightscout.<TEAMID>.trio.trio-app-group`). The follower shares
     Trio's group instead of registering one of its own; it is how the app hands
     glucose to its widget. Apple's API cannot assign app groups, so this is
     manual. Skip it and the build fails to sign the widget.
  2. Create the follower's **App Store Connect app record** by hand, once, at
     [App Store Connect](https://appstoreconnect.apple.com) → Apps → **+**:
     platform **iOS**, bundle id `org.nightscout.<TEAMID>.triofollower`, the
     same string as the SKU, and any app name still available in the App Store.
     This one step cannot be automated — Apple's App Store Connect API does not
     allow creating apps (`The resource 'apps' does not allow 'CREATE'`), and
     fastlane's `produce`, which can, only supports Apple ID authentication.
     Without the record the build succeeds but the TestFlight upload fails.
  3. Run **"3. Create Certificates"** — it provisions the follower's signing
     profile. The follower build runs fastlane match in read-only mode and
     cannot create the profile itself, so it has to exist beforehand. Run this
     even if you already created certificates before the follower existed.
  4. Optional, Android live status: add a repository secret
     `FOLLOWER_GOOGLE_SERVICES_JSON` containing your Firebase project's
     `google-services.json` contents.
- **"Follower CI"** (`follower_ci.yml`) — runs automatically on changes to
  `FollowerApp/`: analyzer, protocol/crypto tests, an Android APK build, and
  an unsigned iOS compile check.

## Home screen widgets

Both platforms show the host's latest status on the home screen. Add them the
usual way: long-press the home screen → **Widgets** → **Trio Follower** on iOS,
or **Widgets** → **Trio Follower** on Android.

- **iOS** — small and medium home screen sizes plus the circular, rectangular
  and inline lock screen sizes. The medium size includes six hours of readings.
- **Android** — one resizable widget with six hours of readings, drawn to fit
  whatever size you give it.

Both show glucose and trend, the delta, IOB, COB and the time of the reading,
coloured with the same 70/180 mg/dL thresholds as the in-app chart, and strike
the value through once the reading is more than six minutes old.

How it works: `lib/services/widget_bridge.dart` formats every displayed value
and writes one JSON payload to shared storage whenever a status push arrives —
including background pushes, so the widgets stay current without opening the
app. The native side only lays out the strings it is given, which is what keeps
iOS, Android and the in-app screen from disagreeing.

The widgets show `--` and "Open Trio Follower" until the first status arrives,
and are cleared when you unpair, so they can never keep displaying glucose from
a host this device is no longer paired with.

**iOS specifics.** The widget is a separate process, so it reads the payload
from the app group it shares with the app — Trio's own
`group.org.nightscout.<TEAMID>.trio.trio-app-group`, reused so builders do not
have to register a second group. The group id carries the Apple team id, so
`tool/prepare_platforms.sh` needs `TEAMID` to build the widget:

```bash
TEAMID=<your team id> ./tool/prepare_platforms.sh
```

Without it the script skips the iOS widget (with a warning) and everything else
still builds. It also needs fastlane's `xcodeproj` gem, since it adds the widget
extension target to the generated `ios/Runner.xcodeproj`; run `bundle install`
at the repository root first, then run the script under `bundle exec`. For a
local `flutter run`/`flutter build ios`, pass the group to the Dart side too:

```bash
flutter build ios --dart-define=APP_GROUP_ID=group.org.nightscout.<TEAMID>.trio.trio-app-group
```

CI does both automatically. Android needs none of this — its widget reads the
app's own storage.

### Local builds

Prerequisites: [Flutter](https://docs.flutter.dev/get-started/install) ≥ 3.29.

The repository intentionally contains only the Dart code and project
metadata. One script generates the platform shells **and applies every
required platform patch** (permissions, background modes, entitlements,
FlutterFragmentActivity, optional Firebase config):

```bash
cd FollowerApp
./tool/prepare_platforms.sh
flutter pub get
flutter test
```

The details it takes care of (for reference, or if you prefer manual setup):

**iOS — `ios/Runner/Info.plist`:**

```xml
<key>NSCameraUsageDescription</key>
<string>Scan the pairing QR code shown on the Trio host.</string>
<key>NSFaceIDUsageDescription</key>
<string>Confirm remote commands before they are sent.</string>
```

Also enable, in Xcode → Runner target → Signing & Capabilities:

- **Push Notifications**
- **Background Modes → Remote notifications** (delivers the host's status
  pushes while the app is in the background)

**Android — `android/app/src/main/AndroidManifest.xml`** (mobile_scanner adds
the camera permission automatically; biometric confirmation needs):

```xml
<uses-permission android:name="android.permission.USE_BIOMETRIC" />
```

`local_auth` requires `MainActivity` to extend `FlutterFragmentActivity`
instead of `FlutterActivity`. For live status on Android, add your Firebase
project's `google-services.json` to `android/app/` (see "Status pushes"
below).

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

## Status pushes

After pairing, the app automatically registers its push address with the host
(`register_follower` command). From then on the host pushes encrypted status:

- **iOS followers** receive background APNS pushes — no Firebase, no extra
  setup. The host uses the same `.p8` key it already has for commands.
- **Android followers** receive FCM data messages. This requires a one-time
  setup: create a (free) Firebase project, add its `google-services.json` to
  `android/app/` before building, and paste the project's *service-account
  JSON* into the Trio host under Settings → Remote Control → Android
  Followers. Without it, commands still work but no live status arrives.

The home screen shows how fresh the host data is; pull to refresh sends a
`status_request` and waits for the answering push.

## Limitations

- Command *delivery* is confirmed (APNS accepted the push); command
  *execution* feedback arrives moments later in the status snapshot the host
  pushes after handling every command.
- Pump management, CGM setup, and settings changes are deliberately not
  remote-controllable — those require physical access to the host device.
- The host must be online (the push wakes Trio in the background). Scheduled
  commands survive short offline windows via APNS storage, subject to the
  host's ±10 minute command freshness window.
- iOS may throttle background status pushes when the follower app hasn't been
  opened for a long time; opening the app and pulling to refresh always
  fetches the current state.
