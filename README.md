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

**Touch and hold the glucose chart** — or drag sideways across it — to read a
single reading's value and time; the readings are five minutes apart and the
chart is small, so there is otherwise no way to tell what any given dot was.
Releasing puts the chart back. The same readout is published as the chart's
accessibility value, since painted text is invisible to a screen reader.

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
  the host and paired followers — the push services carry ciphertext. The one
  exception is opt-in and off by default: [Live Activity updates pushed by the
  host](#live-activity-updates-pushed-by-the-host-ios-opt-in) cannot be
  encrypted, because ActivityKit has to read them to draw the Lock Screen.
- The host identifies the sender via `follower_id`, decrypts with that
  follower's key, checks the command timestamp (±10 min) **and** a strictly
  increasing sequence number, so captured pushes can never be replayed.
- Each follower can be individually revoked on the host at any time
  (Settings → Remote Control → swipe a follower → Revoke).
- Commands run through the exact same safety validation as any other remote
  command on the host (max bolus, recent-bolus guards, etc.). The follower
  additionally enforces the host's limits in its UI before sending.
- **Only commands that change something make a sound on the host.** A command
  that alters therapy — bolus, meal, temp target, override, emergency stop —
  is sent as an alert push whose banner names the follower and what it asked
  for ("Remote command from Mom · Bolus 2.50 U"). Status refreshes and push /
  Live Activity registrations run on a schedule and change nothing, so they go
  out as silent background pushes: the host still wakes, decrypts and answers
  them, without putting anything on anyone's screen. A command type this build
  does not recognize counts as changing something, so it is announced rather
  than arriving unnoticed.

### Emergency stop

The follower's home screen carries a **Suspend all insulin** button. It asks
the host to stop delivery — basal and automated dosing alike — and the host
then alarms until someone holding it answers.

What happens, in order:

1. The follower confirms twice: an explicit dialog naming the consequences,
   then the same biometric gate every other command uses.
2. The host suspends the pump, records which follower asked and when, and
   starts a **repeating time-sensitive alarm** on its own screen.
3. The alarm offers two answers, on the notification itself: *I'm OK — resume
   insulin* and *I'm OK — stay suspended*. The same two sit on a banner across
   the top of the host's Home screen for as long as the suspension goes
   unanswered — a notification can be swiped away and is then gone, and the
   answers must not go with it. (The banner deliberately does not dim the
   screen behind it: deciding whether to restart insulin means looking at the
   glucose the banner would otherwise cover.) Both also remain in Settings →
   Remote Control.
4. The follower watches the state: **requested**, **suspended · not
   acknowledged** with a running clock, or **acknowledged**.

The rules this holds to are deliberate:

- **Nothing resumes insulin on its own.** Not the host's loop, which already
  refuses to enact against a suspended pump, and not a timer. Insulin
  restarting unattended, into someone who may be in the state that prompted
  the suspension, is the worse failure of the two.
- **The follower never claims insulin stopped until the pump says so.** An
  accepted push means Apple took the message. "Suspended" on the follower's
  screen comes only from the host's status snapshot reporting the pump's own
  state; until then it says *waiting — assume insulin is still running*.
- **Answering the alarm and resuming delivery are separate choices.** Someone
  woken by it should not have to agree to restart insulin in order to say they
  are alright.

The cost of never auto-resuming is real: a suspension nobody answers stays in
force, and hours without insulin carry their own danger. That is why the
follower shows how long it has gone unacknowledged — so a caregiver escalates
by calling or going there, rather than trusting this to sort itself out.

Each follower can be allowed or refused this individually, on the host, under
Settings → Remote Control → tap a follower → **Allow Suspending Insulin**.
Followers paired before this existed are allowed by default.

### Versions and update notices

Every registration reports this build's version to the host, and a registration
is re-sent when the app updates — not only when the push token changes, which
an app update usually does not.

The host shows, under Settings → Remote Control:

- the **latest follower release**, read from `FollowerApp/pubspec.yaml` on
  `main` in the Trio repository (the same way Trio checks its own version
  against `Config.xcconfig`), and
- **each follower's version**, marked when it is behind.

From there the host can send an outdated follower — or all of them — a
notification saying a newer version exists. That nudge is a plain notification,
not a command: it carries a version number for the app to show and nothing it
acts on. Updating is still done by whoever holds the follower phone, through
TestFlight or a new APK. A follower that has never reported a version is never
called out of date; the host cannot know, so it does not guess.

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
coloured with the same thresholds as the in-app chart — the ones the host
alerts on, or 70/180 mg/dL until it reports them — and strike the value
through once the reading is more than six minutes old.

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

### Keeping in sync without pulling to refresh

Status pushes are silent background pushes, which iOS and Android are free to
delay, coalesce or drop — so the app does not rely on them alone. While it is
on screen, and every time it comes back to the foreground, it checks the age
of the newest snapshot and sends a `status_request` itself once nothing has
arrived for longer than a CGM cycle (6 minutes). Pulling to refresh does the
same thing on demand.

The check is deliberately quiet, because every request costs the host a push:
nothing is sent while snapshots keep arriving, requests are never sent more
than once every 5 minutes, and the gap doubles up to 30 minutes while the host
stays silent, resetting as soon as it answers. The policy lives in
`lib/services/sync_scheduler.dart` and is covered by
`test/sync_scheduler_test.dart`.

None of this helps while the app is closed — a suspended app cannot poll. For
the Lock Screen there is a way around that; see below.

### Live Activity updates pushed by the host (iOS, opt-in)

The Live Activity can be updated by the host **directly**, without the app
being woken at all:

1. When the activity starts, the app asks ActivityKit for a push token
   (`pushType: .token`).
2. With **Settings → Let the host update it directly** switched on, the app
   sends that token to the host (`register_live_activity`).
3. The host then pushes an `apns-push-type: liveactivity` update to it on
   every reading, at `apns-priority: 10`. Priority 5 is the one that stays out
   of the system's ActivityKit budget, but it is also explicitly deliverable
   whenever the device finds it power-efficient — which for a five-minute
   cadence leaves the Lock Screen minutes behind the app. The app declares
   `NSSupportsLiveActivitiesFrequentUpdates`, which is the allowance a CGM
   cadence asks for, and leaves the user a switch in iOS Settings if they
   would rather have the battery.

The system draws these itself, so the Lock Screen and Dynamic Island stay
current while the app is suspended or has been swiped away — the cases where
silent status pushes are dropped entirely.

**The trade-off, and why it is off by default:** ActivityKit decodes the
payload to draw it, so a remote Live Activity update *cannot* be end-to-end
encrypted. It is the only message in this system that isn't: Apple's push
service carries the displayed glucose, trend, IOB and COB as plain text.
Everything else — commands, status snapshots — stays ciphertext whether this
is on or off. Leaving it off costs nothing but Lock Screen freshness: the app
still updates the activity whenever it runs.

### Layout: Lock Screen, Watch, CarPlay and the widgets

The Live Activity carries the same choices Trio's does, under **Settings →
Live Activity & widgets**:

- **Lock Screen style** — simple (glucose, trend, delta, time) or detailed
  (a chart with the values below it, and override / temp target badges over it).
- **Watch & CarPlay style** — the same choice, made separately, for the Apple
  Watch Smart Stack and the CarPlay dashboard. The activity reaches them at all
  because it declares `supplementalActivityFamilies([.small])`, which needs
  iOS 18.
- **Glucose colour** — coloured by range, or a single colour.
- **Detailed layout** — the four values under the chart, in order: glucose
  (two sizes), IOB, COB, eventual glucose, last updated, or blank. The medium
  home screen widget follows the same list.

Trio keeps these inside the Live Activity's content state, because there the
device that renders is the device that configures. The follower cannot: an
update may be *pushed by the host*, which knows nothing about how this
follower likes to see things. So they live in the shared app group instead
(`lib/models/display_preferences.dart` writes,
`platform/ios/TrioFollowerWidget/FollowerDisplayPreferences.swift` reads), and
the widget extension applies them to whatever content state it is handed —
local or pushed, identically. Changing one republishes the activity, since a
layout is only applied when a content state is rendered.

Trio's **Total Daily Dose** item has no counterpart here: the host's status
snapshot carries no TDD, so there would be nothing to put in the slot.

Two more things worth knowing:

- The displayed values are formatted twice, once in Dart
  (`lib/services/live_activity_bridge.dart`) for local updates and once in
  Swift (`Trio/Sources/Services/RemoteControl/FollowerLiveActivityState.swift`)
  for pushed ones. They must agree digit for digit, down to how halves round;
  the same test vectors are pinned on both sides.
- iOS ends any Live Activity after 8 hours. The app starts a new one the next
  time it runs. Reviving it remotely would need a push-to-start token
  (iOS 17.2+), which is not implemented — and Apple requires start pushes to
  carry a user-visible alert.

### Staleness, and getting the activity back

Two different failures look the same from the Lock Screen — the activity is
showing an old number, or it is not there at all — and they need different
answers.

**Showing an old number.** A Live Activity is only re-rendered when new
content arrives, so a view that worked out staleness from the current time
would draw the last reading as current forever once updates stopped. Every
content state therefore carries a **stale date** six minutes past its reading,
which is what makes the system re-render at that moment and set
`context.isStale`; the views read that flag, and strike the glucose through
when it is set. Alongside it, every layout shows the reading's age as a
relative date, which SwiftUI keeps counting up on its own without any update
at all — so on iOS 16, where `isStale` does not exist, the Lock Screen still
cannot look fresher than its data.

**Not there at all.** An activity ends when the user swipes it away or when
the system retires it, usually while the app is not running to hear about it.
So:

- The app asks ActivityKit whether one is running rather than remembering,
  every time it comes to the front, and starts a fresh one if not.
- **Settings → Start a new Live Activity**, and a card on the home screen when
  one is missing, do the same on demand.
- Restarting means *ending and requesting*, never updating: the system issues
  a push token when an activity is requested, so an activity that is merely
  updated can never gain one — the host would go on pushing at a dead address.
  The new token is registered with the host as part of the restart.
- A dismissal the app *witnesses* is taken as a decision and left alone until
  the user asks for the activity back (or the app is next launched). One it
  finds after the fact is not: that is the system's doing, and comes back by
  itself.

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
  opened for a long time, and delivers none at all to an app that was swiped
  away, so the home screen widgets can lag behind. Opening the app fetches the
  current state: it asks the host directly whenever the data it has is older
  than a CGM cycle. The Lock Screen has a way around this that the widgets do
  not — see [Live Activity updates pushed by the
  host](#live-activity-updates-pushed-by-the-host-ios-opt-in).
