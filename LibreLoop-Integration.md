# FreeStyle Libre 3 / 3+ via LibreLoop — integration notes

Trio can drive a **FreeStyle Libre 3 / Libre 3 Plus** sensor directly over NFC + BLE
using [LibreLoop](https://github.com/LoopKit/LibreLoop), a LoopKit `CGMManager`, plus its
crypto layer [LibreCRKit](https://github.com/airedev326/LibreCRKit). Both are **vendored
directly into this repository** (not submodules) so the full source is visible in one tree
and the project is self-contained.

This still cannot be built or verified in a headless Linux environment — the remaining
verification is an Xcode build on a Mac.

## Layout in this repo (vendored)

- `LibreLoop/` — the LibreLoop CGMManager source + `LibreLoop.xcodeproj` (vendored from
  `LoopKit/LibreLoop` @ `e4a4642`).
- `LibreCRKit/` — the crypto/pairing Swift package (vendored from
  `airedev326/LibreCRKit` @ `abb0f7e`, the revision LibreLoop's project pins).
- `LibreLoop.xcodeproj` references LibreCRKit as a **local Swift package**
  (`XCLocalSwiftPackageReference`, `relativePath = ../LibreCRKit`) instead of the original
  remote URL — so no network package resolution is needed and there is a single copy.

## How it interacts with Trio

- `Trio.xcworkspace` includes `LibreLoop/LibreLoop.xcodeproj`.
- The Trio app target links + embeds `LibreLoop.framework` and `LibreLoopUI.framework`
  (wired in `Trio.xcodeproj`, mirroring the `G7SensorKit` pattern).
- `BasePluginManager.cgms` registers `LibreLoopCGMManager` (identifier
  `"LibreLoopCGMManager"`, display "FreeStyle Libre 3") behind
  `#if canImport(LibreLoop) && canImport(LibreLoopUI)`, and `CGMOptions.swift` adds the
  picker entry. Once the frameworks build, this activates automatically.
- From there, glucose flows through Trio's normal plugin path
  (`PluginSource` → `FetchGlucoseManager` → `GlucoseStorage` → loop) — real-time readings
  that **do** drive closed-loop dosing (unlike the delayed Apple Health "FreeStyle Lingo"
  source, which is display-only).

## Remaining steps (Mac + Xcode)

1. Open `Trio.xcworkspace` in Xcode.
2. Let Swift Package resolution complete. Because LibreCRKit is now a **local** package,
   this should resolve from `./LibreCRKit` with no network fetch.
   - **Fallback if Xcode rejects the hand-edited local reference:** in the LibreLoop
     project, remove the LibreCRKit package reference and re-add it via
     *File ▸ Add Package Dependencies… ▸ Add Local…* pointing at `./LibreCRKit`, then
     re-add the `LibreCRKit` product to the `LibreLoop` framework target.
3. **Resource bundle:** LibreCRKit ships its runtime tables as `LibreCRKit_LibreCRKit.bundle`.
   Confirm it is copied into the built app (pairing/decryption fails without it). If
   embedding `LibreLoop.framework` alone does not carry it, add the bundle to the Trio
   target's *Copy Bundle Resources*.
4. Confirm `LibreLoop` + `LibreLoopUI` build as workspace dependencies of the Trio target.
5. With the frameworks built, "FreeStyle Libre 3" appears in the CGM picker. Pair a Libre 3
   sensor and verify 5-minute readings, historical backfill, and reconnect-after-restart.

## Safety prerequisite (do not skip)

LibreLoop talks directly to the sensor and **bypasses the Abbott app's alarms**. Its
authors explicitly warn against use outside the recommended Loop build until the host app
provides comparable glucose alerting — including **Critical Alerts for urgent-low that
break through Do Not Disturb and silent mode**. Verify Trio's low/urgent-low/high alerting
(and a remote-monitoring path such as Nightscout) before relying on this.

## Legal note

`LibreCRKit` bundles **extracted Abbott artifacts** (white-box AES tables + an Abbott app
certificate under `LibreCRKit/Sources/LibreCRKit/Resources/RuntimeTables/`), not a fully
clean-room reimplementation. Abbott has a history of DMCA enforcement against Libre
interoperability projects. These bytes are now committed directly to this (private)
repository, and a shipped build made from it would contain them. This is an informed,
deliberate choice for a private build — do not publish or redistribute this tree.

## Scope

LibreLoop supports **Libre 3 / Libre 3 Plus only**. It does **not** support the Abbott
**Lingo** or **Rio** sensors — they use different sensor certificates that LibreCRKit does
not carry, so pairing a Lingo/Rio through LibreLoop is expected to fail. For Lingo, the
delayed Apple Health source (CGM type "FreeStyle Lingo") remains the only option, and it is
display-only.
