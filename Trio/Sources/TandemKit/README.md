# TandemKit

In-app driver for the **Tandem Mobi** and **Tandem t:slim X2** insulin pumps,
built into the Trio app target (not a separate framework/submodule like
MedtrumKit or DanaKit).

## What this driver can and cannot do

The Tandem BLE protocol — as reverse-engineered by the
[pumpx2](https://github.com/jwoglom/pumpx2) project — exposes a specific,
limited command surface, and it differs between the two models. TandemKit
implements what each pump actually supports:

| Capability | Mobi | t:slim X2 | Notes |
|---|---|---|---|
| Pair + connect | ✅ | ✅ | Mobi: 6-digit JPAKE code. t:slim X2: 16-character code on 7.1–7.6, 6-digit JPAKE on 7.7+ |
| Read status (reservoir, battery, basal, Control-IQ, CGM icon, suspend) | ✅ | ✅ | Polled on Trio's heartbeat |
| Report boluses to Trio's treatment log | ✅ | ✅ | Reconciled from the pump's last-bolus status |
| Remote bolus | ✅ (opt-in) | ✅ (opt-in) | t:slim X2 needs firmware **7.6+** (API ≥ 2.5); user must explicitly enable |
| Remote temp basal | ✅ (opt-in) | ❌ | The temp-rate/suspend/resume commands are **Mobi-only** in the protocol |
| Suspend / resume | ✅ (opt-in) | ❌ | Same |
| Automatic dosing (SMB) | ✅ with basal control on | ⚠️ only in microbolus-basal mode | Requires Trio to be the pump's only automated dosing authority |
| Closed loop | ✅ natively | ⚠️ experimental microbolus-basal only | |

So the two models give Trio genuinely different roles:

- On a **Mobi**, Trio closes the loop the normal way: it sets temp basals on the
  pump and can suspend and resume delivery.
- On a **t:slim X2**, `enactTempBasal`/`suspendDelivery`/`resumeDelivery` return
  a clear "unsupported" error, and the pump is a **monitor, treatment log, and
  (optionally) a manual remote bolus interface** — unless the experimental
  microbolus-basal mode below is enabled.

### Mobi basal control

`TandemNativeBasal.swift` drives the pump's own `SetTempRate` / `StopTempRate` /
`SuspendPumping` / `ResumePumping` commands. Two properties of the protocol
shape the implementation:

- **A temp rate is a percentage of the pump's active basal profile**, not an
  absolute U/hr value, and the percentage is a whole number from 0 to 250. Every
  command therefore reads the pump's current profile rate first (refusing to
  guess from stale status), converts, and records the **achieved** rate — the
  percentage actually applied — for IOB, not the rate oref asked for. Two
  consequences the settings screen surfaces to the user: the pump needs a
  non-zero basal profile, and a high temp is capped at 2.5× the scheduled rate.
- **Durations run from 15 minutes to 72 hours.** Trio's usual 30-minute temp
  fits; a shorter request is raised to the pump's minimum, and a zero-length
  request is treated as "cancel", which is what LoopKit means by it.

The pump's own Control-IQ must be **off**: two systems adjusting basal at once is
unsafe, so each command verifies it against a recent status sync and refuses
otherwise. The whole feature sits behind an explicit opt-in
(`TandemPumpState.remoteBasalEnabled`) with a confirmation dialog.

### Microbolus-basal mode (t:slim X2, experimental)

An opt-in mode (`TandemMicrobolusBasal.swift`) lets Trio close the loop on a
t:slim X2 anyway by delivering **all** basal as a stream of small boluses:

- Each loop cycle, oref's requested basal rate is integrated over the elapsed
  time into an "owed" accumulator; the accrued amount is delivered as one
  microbolus (rounded down to the 0.001 U increment — the milliunit
  resolution of the BLE bolus cargo — and delivered once it reaches the
  firmware's 0.05 U remote-bolus floor, confirmed on hardware running
  7.6.0.1). Sub-minimum rates
  accumulate until they cross the pulse threshold, so even low rates are
  delivered on average.
- **Hard precondition:** the pump's own basal profile must be **0 U/hr** and
  **Control-IQ off**, verified against the last status sync. Otherwise Trio
  would stack microboluses on top of the pump's own delivery, so the engine
  refuses to dose and surfaces an error.
- With the pump basal zeroed, `suspendDelivery` becomes a real suspend
  (withholding microboluses = zero delivery), so Trio regains the ability to
  stop insulin.
- Deliveries are recorded as **automatic bolus** pump events (not temp basal):
  bolus and temp basal contribute identically to IOB, and recording as bolus
  avoids Trio's `maxBasal` temp-basal filter that would otherwise drop a
  high-reconstructed-rate pulse and undercount IOB.
- Automatic (SMB) boluses are only accepted while this mode is on. An ambiguous
  initiate is recorded as delivered (safe direction, never re-delivered).
  Backstops cap the single pulse (2 U) and total owed (5 U).

This deliberately disables the pump's built-in Control-IQ/Basal-IQ safety
automation and substitutes Trio's. It is a significant, genuinely risky,
off-label configuration gated behind an explicit confirmation, is **unverified
on hardware**, and must not be relied on without real-pump testing.

The mode is offered only on the t:slim X2. On a Mobi there is no reason to
emulate basal with boluses when the pump accepts real temp rates.

## Pairing

Two handshakes, chosen by the shape of the code the pump displays:

**Legacy, 16 characters (t:slim X2 software 7.1–7.6).** A
`CentralChallenge`/`PumpChallenge` exchange; the pairing code itself becomes the
HMAC key for signed messages.

**JPAKE, 6 digits (Tandem Mobi, and t:slim X2 software 7.7+).** An EC-JPAKE
password-authenticated key exchange over NIST P-256, ported from pumpx2's
`io.particle.crypto.EcJpake` (itself derived from mbed TLS) into
`Crypto/TandemEcJpake.swift`. Unlike the legacy flow it never puts a value
derived from the code on the wire, so an eavesdropper cannot recover the code.

The flow is five message pairs on the authorization characteristic:

```
Jpake1a / Jpake1b   round 1 (330 bytes, split in half because a message
                    cargo caps at 165 bytes of payload)
Jpake2              round 2 (we send 165 bytes; the pump replies with 168 —
                    it prefixes a named-curve id)
Jpake3SessionKey    the pump issues an 8-byte nonce
Jpake4KeyConfirm    both sides prove they derived the same key
```

Rounds 1 and 2 produce the long-lived **derived secret**, which is persisted.
Rounds 3 and 4 run again on **every connection**: the message-signing key is
`HKDF-SHA256(salt: the pump's fresh nonce, ikm: derived secret)`, so it is
different each time. Reconnecting to a paired pump therefore does no
elliptic-curve work at all — only the nonce exchange — which matters because the
full handshake costs roughly a dozen P-256 scalar multiplications and takes a
couple of seconds on-device.

If key confirmation fails against a stored secret (the pump was re-paired, or an
earlier pairing was cut short), the driver discards the secret and retries the
full handshake once from the saved code, rather than making the user delete and
re-add the pump.

Apple's platform crypto exposes no raw big-integer or elliptic-curve point
arithmetic, so `Crypto/TandemBigUInt.swift` and `Crypto/TandemP256.swift`
provide the minimum needed. They are **not constant-time**, and are used only
for this handshake — never for long-lived key material. Peer points are
validated against the curve equation on decode, which is what blocks an
invalid-curve attack.

## Safety model

Insulin-affecting commands are guarded by two independent gates:

1. **User opt-in.** `remoteBolusEnabled` and `remoteBasalEnabled` are both off by
   default and are only set from the settings screen behind a confirmation
   dialog. Together they drive `TandemPumpSession.insulinDeliveryActionsEnabled`,
   which refuses to send any `modifiesInsulinDelivery` message when false —
   mirroring pumpx2's `actionsAffectingInsulinDeliveryEnabled` gate.
2. **A single dosing authority.** Automatic (oref SMB) boluses are refused
   unless Trio is verifiably the only automated dosing system: on a Mobi that
   means remote basal control is on, the status sync is fresh, Control-IQ is
   off, and delivery is not suspended; on a t:slim X2 it means microbolus-basal
   mode with its own preconditions met. Manual, user-confirmed boluses are
   exempt.

Every insulin-affecting command is **signed** (HMAC-SHA1 over the message with
a fresh `pumpTimeSinceReset`, keyed by the pairing code on legacy pumps or by
the derived session key on JPAKE pumps). The session refreshes the time
reference before each control command and refuses to sign with a stale value,
matching the pump's anti-replay expectation.

The bolus flow follows the pump's required ordering:
`BolusPermissionRequest` → (granted, with a `bolusId`) → `InitiateBolusRequest`
→ (accepted) → poll `LastBolusStatus` → `BolusPermissionRelease`.

Removing the pump stops any Trio-commanded temp rate first, so a Mobi is never
left running a rate with nothing able to cancel it.

## Layout

```
TandemKit/
  TandemPumpManager.swift          LoopKit PumpManager: status polling, bolus, event reconciliation
  TandemPumpModel.swift            Model (Mobi / t:slim X2), capabilities, pairing-code kinds
  TandemPumpManager+UI.swift       (UI/) PumpManagerUI conformance
  TandemPumpState.swift            Persisted state (RawRepresentable round-trip)
  TandemNativeBasal.swift          Mobi temp rate / suspend / resume
  TandemMicrobolusBasal.swift      t:slim X2 experimental basal-via-bolus engine
  TandemDoseProgressReporter.swift Bolus progress estimate
  TandemLogger.swift               Logging shim over Trio's logger
  Bluetooth/
    TandemBLEConstants.swift       Service + characteristic UUIDs
    TandemBluetoothManager.swift   CoreBluetooth transport (scan/connect/notify/write)
  Crypto/
    TandemBigUInt.swift            Minimal arbitrary-precision unsigned integer
    TandemP256.swift               NIST P-256 point arithmetic
    TandemEcJpake.swift            EC-JPAKE protocol
  Protocol/
    TandemCRC.swift                CRC-16/CCITT-FALSE
    TandemPacketize.swift          Framing, chunking, signing, reassembly
    TandemMessages.swift           Status (read-only) request/response messages
    TandemControlMessages.swift    Signed control messages
    TandemJpakeMessages.swift      JPAKE pairing messages
    TandemJpakeAuthenticator.swift JPAKE handshake driver + key derivation
    TandemPumpSession.swift        Request/response orchestration + authentication
  UI/
    TandemUICoordinator.swift      Setup/settings navigation controller
    TandemPairingView.swift        Scan + pairing-code entry
    TandemSettingsView.swift       Status, opt-in toggles, minimum-dose test, delete
```

## Threading

`TandemPumpSession.send()` writes a request and **blocks** on a semaphore until
the response is reassembled. It runs on `TandemPumpManager.commandQueue`;
BLE delegate callbacks (which signal the semaphore) run on the separate
`TandemBluetoothManager.managerQueue`. The two queues are distinct, so blocking
sends never deadlock. Never call `send()` from the BLE manager queue.

The JPAKE handshake is CPU-heavy and likewise must not run on the main thread;
the pairing view drives it from its own work queue, and reconnections run it on
`commandQueue`.

## Protocol source of truth

All wire constants (UUIDs, opcodes, byte offsets, CRC, signing, JPAKE message
layouts) are transcribed from the pumpx2 Java library. The EC-JPAKE port is
checked against reference vectors generated by running pumpx2's own
implementation with a deterministic random source; `TrioTests/TandemCryptoTests.swift`
replays the exact scalars it consumed and asserts byte-identical output, so a
passing test means this driver produces the same bytes as the implementation
known to work against real pumps.

This is clean-room-style reuse of a documented, community-maintained protocol —
no Tandem firmware or proprietary code is included.

## Hardware verification status

The t:slim X2 status, pairing and remote-bolus paths have been exercised on real
hardware (firmware 7.6.0.1). The **Mobi paths — JPAKE pairing, temp rate,
suspend and resume — are unverified on hardware.** They are transcribed from the
protocol and covered by unit tests, but must be tested against a real pump
before being relied on.
