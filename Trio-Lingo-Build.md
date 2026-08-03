# Building "Trio Lingo" via GitHub Actions

This branch is configured to build as a **separate, side-by-side app** so it installs next to
a normal Trio and cannot touch it:

- `APP_DISPLAY_NAME = Trio Lingo`, `APP_URL_SCHEME = TrioLingo`
- `BUNDLE_IDENTIFIER = org.nightscout.$(DEVELOPMENT_TEAM).triolingo` (distinct id ⇒ separate
  app + separate sandbox)
- App group is left unchanged. That is safe: Trio's settings, dosing state, and the Core Data
  glucose history live in the app's **own sandbox**, not the app group, so the real Trio's data
  is isolated. Only widget / Live Activity / Apple Watch / xDrip-bridge data uses the shared
  app group — if both apps' widgets/complications are active they can cross-talk (cosmetic).
  Avoid adding the Trio Lingo widget/complication if you want to keep that clean.

The `4. Build Trio` action's upstream-sync step is disabled on this branch, so it builds this
code as-is instead of trying to sync from a (nonexistent) upstream branch of the same name.

## Prerequisites

The normal Trio "browser build" secrets must already be set on this repo (same ones a regular
Trio build uses): `GH_PAT`, `TEAMID`, `FASTLANE_ISSUER_ID`, `FASTLANE_KEY_ID`, `FASTLANE_KEY`,
`MATCH_PASSWORD`. If your regular Trio builds work, these are set.

## Dispatch order (all on branch `claude/freestyle-lingo-cgm-qk8cvy`)

Because the bundle id is new, its identifiers and signing must be provisioned once before the
first build. In the GitHub **Actions** tab, run each workflow with this branch selected:

1. **2. Add Identifiers** — registers the new `…triolingo` bundle ids (app, watch app, watch
   complication, LiveActivity) and their capabilities (App Groups, HealthKit, NFC, Push) in
   App Store Connect.
2. **3. Create Certificates** — `match` generates App Store provisioning profiles for the new
   ids.
3. **Create the App Store Connect app record** (one-time, likely manual): in App Store Connect
   ▸ Apps ▸ +, create an app with bundle id `org.nightscout.<TEAMID>.triolingo`, name
   "Trio Lingo", pick any SKU. This is needed because step 4 looks up the latest TestFlight
   build number for that app; a brand-new bundle id has no app record until you make one.
   (Some fastlane versions auto-create it — if step 4 fails at `latest_testflight_build_number`
   with "app not found", do this and re-run.)
4. **4. Build Trio** — builds the IPA and uploads it to TestFlight under the "Trio Lingo" app.

## This build doubles as the integration verification

The macOS runner does a full Xcode build of the workspace, so it also compiles the vendored
LibreLoop framework + the local LibreCRKit package + my Trio wiring. If the build fails at
package resolution or framework embedding, that's the integration needing a fix — grab the
build log artifact (uploaded even on failure) and the Fastlane/xcodebuild error, and it can be
corrected. A green build means the whole Libre 3 / Lingo stack compiles and is on TestFlight.

## Reminders

- The IPA (containing LibreCRKit's extracted Abbott artifacts) is uploaded to Apple/TestFlight
  — a bit more exposure than the private repo; that's your call.
- Don't rely on this for real dosing until Trio's urgent-low / Critical Alerts are verified —
  LibreLoop bypasses Abbott's alarms. This build is for the Lingo pairing test.
- After install, run the Lingo pairing test per `LibreLoop-Integration.md` ("Lingo") and send
  the handshake log.
