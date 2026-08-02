# FreeStyle Libre 3 / 3+ via LibreLoop — integration notes

Trio can drive a **FreeStyle Libre 3 / Libre 3 Plus** sensor directly over NFC + BLE
using [LibreLoop](https://github.com/LoopKit/LibreLoop), a LoopKit `CGMManager` plugin.
This document records what is already wired into this repo and what still has to be
done and verified on a Mac with Xcode (this cannot be built or verified in a headless
Linux CI environment).

## What is already wired in this branch

- **Submodule**: `LibreLoop` (`https://github.com/LoopKit/LibreLoop.git`), pinned to the
  commit recorded in `.gitmodules` / the gitlink.
- **Workspace**: `LibreLoop/LibreLoop.xcodeproj` added to `Trio.xcworkspace`.
- **Project**: `LibreLoop.framework` and `LibreLoopUI.framework` added to the Trio app
  target's *Link Binary With Libraries* and *Embed Frameworks* phases (mirrors how
  `G7SensorKit` is wired).
- **Plugin registration**: `BasePluginManager.cgms` registers `LibreLoopCGMManager`
  (identifier `"LibreLoopCGMManager"`, display name `"FreeStyle Libre 3"`), guarded by
  `#if canImport(LibreLoop) && canImport(LibreLoopUI)` so builds without the framework
  are unaffected.
- **Selection UI**: a `CGMOption(name: "FreeStyle Libre 3", ...)` entry so the manager
  appears in the CGM picker once the framework is present.

Everything above routes Libre 3 glucose through Trio's normal plugin pipeline
(`PluginSource` → `FetchGlucoseManager` → `GlucoseStorage` → loop), the same path used
by Dexcom G7 and LibreTransmitter. Unlike the delayed Apple Health "FreeStyle Lingo"
source, these are real-time readings and **are** used for closed-loop dosing.

## Remaining steps (must be done on a Mac + verified with a build)

1. **Fetch submodules**: `git submodule update --init --recursive LibreLoop`.
2. **Resolve the Swift package**: LibreLoop pulls
   [`LibreCRKit`](https://github.com/airedev326/LibreCRKit) via `XCRemoteSwiftPackageReference`.
   Open `Trio.xcworkspace` in Xcode and let package resolution complete
   (File ▸ Packages ▸ Resolve Package Versions). The workspace resolves package
   references declared by any contained project, so no separate SPM entry in
   `Trio.xcodeproj` should be required — **confirm this actually resolves.**
3. **Resource bundle**: LibreCRKit ships its runtime tables as a resource bundle
   (`LibreCRKit_LibreCRKit.bundle`). Verify this bundle is copied into the built app
   (it must be present at runtime or pairing/decryption fails). If embedding
   `LibreLoop.framework` alone does not carry it, add the bundle to the Trio target's
   *Copy Bundle Resources* (as LibreLoop's own project does).
4. **Build the frameworks**: confirm `LibreLoop` and `LibreLoopUI` build as implicit
   workspace dependencies of the Trio target (add explicit target dependencies if the
   implicit ones are not picked up).
5. **Confirm activation**: with the frameworks present, `#if canImport(LibreLoop)`
   becomes true and "FreeStyle Libre 3" appears in the CGM picker. Pair a Libre 3
   sensor and confirm 5-minute readings, historical backfill, and reconnect-after-restart.

## Safety prerequisite (do not skip)

LibreLoop talks directly to the sensor and **bypasses the Abbott app's alarms**. Its
authors explicitly warn against use in Trio until Trio provides comparable glucose
alerting — including **Critical Alerts for urgent-low that break through Do Not Disturb
and silent mode**. Verify Trio's low/urgent-low/high alerting (and a remote-monitoring
path such as Nightscout) before relying on this in production.

## Legal note

LibreLoop's crypto dependency, `LibreCRKit`, bundles **extracted Abbott artifacts**
(white-box AES tables and an Abbott app certificate) rather than a fully clean-room
reimplementation. This repo commits only a submodule *pointer* to LibreLoop (and
LibreCRKit is fetched by SPM at build time), so no Abbott-derived bytes live in the
Trio repository — but a shipped build made with it would contain them. Abbott has a
history of DMCA enforcement against Libre interoperability projects. Bundling and
distributing this is an informed decision for whoever builds and ships Trio.

## Scope

LibreLoop supports **Libre 3 / Libre 3 Plus only**. It does **not** support the Abbott
**Lingo** or **Rio** sensors — those use different sensor certificates that LibreCRKit
does not carry, so pairing a Lingo/Rio through LibreLoop is expected to fail. For Lingo,
the delayed Apple Health source (CGM type "FreeStyle Lingo") remains the only option,
and it is display-only.
