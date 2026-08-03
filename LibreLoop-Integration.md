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

## Scope: Libre 3 / 3+ proven; Lingo experimental

**Proven:** Libre 3 / Libre 3 Plus. These pair and stream via the bundled universal Libre 3
app certificate (`phone_cert_162b.bin` = Juggluco's `LIBRE3_APP_CERTIFICATES_B[1]`).

**Lingo (experimental, unconfirmed):** see the dedicated section below. Rio is
uncharacterized. Until a Lingo pairing is confirmed on hardware, the delayed Apple Health
source (CGM type "FreeStyle Lingo") remains the only working Lingo option, and it is
display-only.

## Lingo — feasibility and the decisive experiment

What the code establishes (verified by reading LibreCRKit, DiaBLE, and Juggluco source):

- **There is no product-type gate.** LibreCRKit parses the product-type byte but never
  branches on it; the NFC activation/switch command carries no product-type field. A patch
  now recognizes the family explicitly (`Libre3ProductType`: Libre 3 = 4, Lingo = 9,
  Instinct = 10) and LibreLoop logs it during pairing, but a Lingo is still driven through
  the **same** universal Libre 3 handshake.
- **The gating identity is the app certificate, not the sensor.** Only two Abbott Libre 3
  app certificates exist publicly (indices 0 and 1); index 1 is the "universal" one that
  pairs live Libre 3 sensors. Neither is Lingo-specific. DiaBLE models Lingo as an empty
  subclass of Libre 3 that reuses this same cert — i.e. it *bets* Lingo trusts it — but
  **no one has published a confirmed Lingo pairing, success or failure.** The certificate
  index is read from the sensor's own patch-info, and Lingo is the same silicon, so the
  universal cert *may* be accepted.

So Lingo is one of two cases, and only a Lingo sensor can tell them apart:

1. **Lingo trusts the universal cert** → it should pair and stream with no further work.
   This code path already attempts it.
2. **Lingo pins its own (Lingo-app) certificate** → the sensor rejects the universal cert.

**The decisive experiment (needs a Lingo sensor + a Mac build):** pair a Lingo through
LibreLoop and read the handshake log (LibreLoop's `llog` file log; the pairing flow logs
every step and prints the sensor's actual response bytes).

Exact log signatures to look for:

1. First confirm recognition — near the top of the attempt:
   `Sensor product: FreeStyle Lingo (raw productType 9).`
   If instead it prints `Unknown Libre 3-family product (N)`, the product-type byte offset
   needs adjusting for Lingo (tell me the raw patch-info); this does **not** affect the
   pairing attempt, which never gates on product type.

2. Then watch the certificate step. The flow sends `LoadCertificate 0x02` → the phone cert →
   `SendCertificateLoadDone 0x03`, then waits for `0x04 CertificateAccepted`:
   - **Case 1 (works):** the log continues past the cert step —
     `got CertificateAccepted response=04…`, then `CertificateReady`, `EphemeralReady`,
     `ChallengeLoadDone`, Phase 6, and glucose readings start. Lingo trusts the universal
     cert; nothing more to do.
   - **Case 2 (Lingo pins its own cert):** the cert step fails, as either
     `got CertificateAccepted response=<non-04 bytes>` followed by a thrown
     `unexpectedCommandResponse(label: "CertificateAccepted", …, actual: <bytes>)`
     (the `actual` bytes are the sensor's rejection/security code — capture them), or a
     timeout waiting for `CertificateAccepted`. Either way the sensor rejected the Libre 3
     app certificate → Lingo needs its own cert material (see below).

A failure *after* `ChallengeLoadDone` (i.e. at Phase 5/Phase 6) is a different signal — it
would mean the cert was accepted but the key derivation diverges — capture that log too, as
it changes what extraction is needed.

**If it's case 2**, enabling Lingo requires extracting the Lingo app's own app certificate
+ matching private/scalar material (the same Frida-against-the-SKB-white-box method used to
obtain the Libre 3 material), then adding that cert + its Phase 5 scalar window as an
alternate in `PhoneCert`/`phase5StaticScalarWindowOverride`. That is a separate
reverse-engineering effort against the Lingo app binary; no public head start exists, and it
is not something that can be produced without the Lingo app + tooling. The code seam for
dropping such material in already exists (the pairing flow takes an injectable
`phoneCert`/scalar).
