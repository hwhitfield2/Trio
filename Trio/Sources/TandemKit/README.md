# TandemKit

In-app driver for the **Tandem t:slim X2** insulin pump, built into the Trio
app target (not a separate framework/submodule like MedtrumKit or DanaKit).

## What this driver can and cannot do

The t:slim X2 BLE protocol — as reverse-engineered by the
[pumpx2](https://github.com/jwoglom/pumpx2) project — exposes a specific,
limited command surface. TandemKit implements what the pump actually
supports:

| Capability | Supported | Notes |
|---|---|---|
| Pair + connect | ✅ | Firmware 7.1–7.6, 16-character pairing code |
| Read status (reservoir, battery, basal, Control-IQ, CGM icon, suspend) | ✅ | Polled on Trio's heartbeat |
| Report boluses to Trio's treatment log | ✅ | Reconciled from the pump's last-bolus status |
| Remote bolus | ✅ (opt-in) | Firmware **7.6+** (API ≥ 2.5) only; user must explicitly enable |
| Native remote temp basal (protocol command) | ❌ | **Not possible.** The temp-basal/suspend/resume commands are Tandem **Mobi**-only in the protocol. |
| Closed loop via microbolus-basal | ⚠️ experimental opt-in | Emulates basal with a stream of automatic microboluses; requires the pump basal zeroed + Control-IQ off. |

The t:slim X2 has no remote temp-basal command, so by default this pump is a
**monitor, treatment log, and (optionally) a manual remote bolus interface**,
and `enactTempBasal`/`suspendDelivery`/`resumeDelivery` return a clear
"unsupported" error unless microbolus-basal mode (below) is enabled.

### Microbolus-basal mode (experimental)

An opt-in mode (`TandemMicrobolusBasal.swift`) lets Trio close the loop anyway
by delivering **all** basal as a stream of small automatic boluses:

- Each loop cycle, oref's requested basal rate is integrated over the elapsed
  time into an "owed" accumulator; the accrued amount is delivered as one
  microbolus (rounded down to the 0.001 U increment — the milliunit
  resolution of the BLE bolus cargo). Sub-minimum rates
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

The newer 6-digit **JPAKE** pairing flow (firmware 7.7+ and Tandem Mobi) is
**not implemented**; those pumps are rejected during pairing with an
explanatory message. The message structs for the Mobi-only basal-control
commands are present but never sent by the t:slim X2 path — they are kept so
a future Mobi driver can reuse the transport.

## Safety model

Remote bolus is guarded by two independent gates:

1. **User opt-in.** `TandemPumpState.remoteBolusEnabled` is off by default and
   is only set from the settings screen behind a confirmation dialog. It drives
   `TandemPumpSession.insulinDeliveryActionsEnabled`, which refuses to send any
   `modifiesInsulinDelivery` message when false — mirroring pumpx2's
   `actionsAffectingInsulinDeliveryEnabled` gate.
2. **Manual confirmation only.** `enactBolus` rejects `.automatic` activation
   types. Trio never delivers an autonomous/algorithmic bolus on this pump;
   only manually confirmed boluses go through. (A second autonomous dosing
   authority alongside on-pump Control-IQ would be unsafe.)

Every insulin-affecting command is **signed** (HMAC-SHA1 over the message with
a fresh `pumpTimeSinceReset`, keyed by the pairing code). The session refreshes
the time reference before each control command and refuses to sign with a stale
value, matching the pump's anti-replay expectation.

The bolus flow follows the pump's required ordering:
`BolusPermissionRequest` → (granted, with a `bolusId`) → `InitiateBolusRequest`
→ (accepted) → poll `LastBolusStatus` → `BolusPermissionRelease`.

## Layout

```
TandemKit/
  TandemPumpManager.swift          LoopKit PumpManager: status polling, bolus, event reconciliation
  TandemPumpManager+UI.swift       (UI/) PumpManagerUI conformance
  TandemPumpState.swift            Persisted state (RawRepresentable round-trip)
  TandemDoseProgressReporter.swift Bolus progress estimate
  TandemLogger.swift               Logging shim over Trio's logger
  Bluetooth/
    TandemBLEConstants.swift       Service + characteristic UUIDs
    TandemBluetoothManager.swift   CoreBluetooth transport (scan/connect/notify/write)
  Protocol/
    TandemCRC.swift                CRC-16/CCITT-FALSE
    TandemPacketize.swift          Framing, chunking, signing, reassembly
    TandemMessages.swift           Status (read-only) request/response messages
    TandemControlMessages.swift    Signed control messages
    TandemPumpSession.swift        Request/response orchestration + authentication
  UI/
    TandemUICoordinator.swift      Setup/settings navigation controller
    TandemPairingView.swift        Scan + pairing-code entry
    TandemSettingsView.swift       Status, remote-bolus toggle, 0.001 U test dose, delete
```

## Threading

`TandemPumpSession.send()` writes a request and **blocks** on a semaphore until
the response is reassembled. It runs on `TandemPumpManager.commandQueue`;
BLE delegate callbacks (which signal the semaphore) run on the separate
`TandemBluetoothManager.managerQueue`. The two queues are distinct, so blocking
sends never deadlock. Never call `send()` from the BLE manager queue.

## Protocol source of truth

All wire constants (UUIDs, opcodes, byte offsets, CRC, signing) are transcribed
from the pumpx2 Java library. The extraction notes used while writing this
driver live outside the repo; the authoritative reference is pumpx2 itself.
This is clean-room-style reuse of a documented, community-maintained protocol —
no Tandem firmware or proprietary code is included.
