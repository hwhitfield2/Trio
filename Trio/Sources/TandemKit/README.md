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
| Closed loop | ✅ native temp rates **or** microbolus-basal | ⚠️ experimental microbolus-basal only | Mode is a single explicit choice; the two never run together |
| Cartridge change + fill tubing | ⚠️ opt-in, untested | ⚠️ opt-in, field-tested | Sequence verified on a Mobi; the tubing fill runs from the pump's own button |
| Prime cannula | ⚠️ opt-in, untested | ❌ | `FillCannula` is Mobi-only; prime on the pump itself on a t:slim X2 |

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

### Microbolus-basal mode (either model, experimental)

`TandemMicrobolusBasal.swift` delivers **all** basal as a stream of small
boluses. On a **t:slim X2** it is the only way to close the loop at all. On a
**Mobi** it is an alternative to native temp rates, and buys finer control: a
Tandem temp rate is a whole percentage of the pump's profile, capped at 250%
with a 15-minute minimum, whereas microboluses follow oref's requested rate at
milliunit resolution with no ceiling beyond Trio's own limits. The trade is that
it replaces the pump's delivery engine with Trio's, and needs the pump's own
basal zeroed.

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

### Choosing between them

`TandemBasalControlMode` makes the choice explicit — `none`, `nativeTempRate`
(Mobi only) or `microbolus` (either model) — rather than leaving two independent
opt-in flags to be read separately. The two working modes **must never both be
live**: a pump-side temp rate delivering underneath a microbolus stream is a
straightforward double dose. So the mode is derived, microbolus wins if both
flags are somehow set (it is the mode that delivers on its own initiative), the
settings screen offers one picker rather than two toggles, and switching to
microbolus stops any temp rate still running on the pump instead of merely
clearing the flag.

## Cartridge changes

`TandemCartridgeChange.swift` walks through loading a new cartridge, filling the
tubing and (on a Mobi) priming the cannula, using the pump's own
`EnterChangeCartridgeMode` / `EnterFillTubingMode` / `FillCannula` commands, with
live progress from the control-stream characteristic.

**This is the least proven part of the driver, and deliberately the most
gated.** Two things make it different from everything else here:

- **There is no reference implementation.** pumpx2 defines these message
  encodings and unit-tests them, but nothing in its Android library or sample
  app ever sends them, and its progress-state enums have a single known value
  each (`READY_TO_CHANGE(2)`, `CANNULA_FILLED(2)`). The encodings are
  transcribed with the same confidence as the rest of the driver; the
  **sequence** is reconstructed from how the pump's own procedure works.
- **It moves insulin outside any dosing calculation.** Filling tubing pushes
  insulin through the line; priming pushes it into the infusion site. Neither is
  IOB — the pump does not count them either, so they are recorded as `prime`
  events with no dose. Counting them would make Trio under-deliver for hours
  after every set change.

### The pump's own load state machine

`LoadStatusRequest` (opcode 20, unsigned, current-status) reports
`isLoadingActive`, a `LoadState` — change cartridge, load cartridge, prime
tubing, prime cannula, prime nudge — and a prime-detail byte. It costs nothing
and is ungated, so the driver reads it before a cartridge command and again
after a refusal.

One reading needs care: `isLoadingActive == false` means *no load is running*,
and `LoadState` is then whatever the machine last held. A Mobi at rest reports
`INVALID` there — that is its resting value, not a fault — so the driver
describes an inactive pump as "not loading a cartridge" and quotes the state
only while a load is actually under way.

pumpx2 documents the precondition for `EnterChangeCartridgeMode` outright:
**insulin must be suspended**. `beginCartridgeChange` therefore establishes that
state and then *verifies it against the pump* rather than trusting its own
record or the suspend command's status byte:

1. refuse if a bolus is requesting or delivering (`CurrentBolusStatus`) — the
   pump does one insulin operation at a time, and in microbolus-basal mode Trio
   boluses every few minutes;
2. read `HomeScreenMirror`; if the basal icon is not `SUSPEND`/`HYPO_SUSPEND`,
   send `SuspendPumping` (Mobi only — the t:slim X2 has no remote suspend, so
   the user is asked to stop insulin on the pump);
3. re-read `HomeScreenMirror`. A suspend the pump *accepted but did not act on*
   is a different problem from one it refused, and gets its own message instead
   of resurfacing as an unexplained refusal one command later.

**On hardware, `EnterChangeCartridgeMode` was still refused with status 1 on a
Mobi after the suspend** — with the pump verified suspended (`basalIcon=4`) and
idle. The field logs held the answer: the reservoir reading went 180 U → 0 U in
the same minute the refusals started, which is a cartridge alarm — Empty
Cartridge or Cartridge Removed (`AlarmStatusResponse` bits 8/25). **An alarming
Tandem pump refuses to start new operations until the alarm is acknowledged**,
and Trio never read the alarm bitmask, so the refusal looked inexplicable.

The driver now reads `AlarmStatus` (opcode 70) and `AlertStatus` (68) — both
unsigned current-status queries — wherever it summarises pump state, so a
refusal reports "the pump is alarming: Empty Cartridge" ahead of the delivery
and load state. On a Mobi the phone app is the only place an alarm *can* be
acknowledged (there is no pump screen), and pumpx2 carries the message for it
from the decompiled Mobi app: `DismissNotificationRequest` (0xB8, signed,
control). The cartridge screen offers it under deliberate constraints:

- only on an explicit button press, with the alarm named on the button;
- only for alarms whose documented remedy is this flow — the cartridge-fault
  family, Empty Cartridge, Cartridge Removed, Occlusion, Resume Pump. A
  temperature, battery or hardware alarm is shown but never cleared by Trio;
- `executeExtraAction` is always false (acknowledge only — the per-alarm
  follow-up action in the decompiled app is unreviewed);
- pumpx2 never sends this message, so the `notificationId = alarm bit index`
  encoding is a reconstruction: the driver re-reads `AlarmStatus` afterwards
  and reports an alarm that did not clear instead of trusting the status byte.

The reconstruction is now **field-confirmed**: on a live Mobi, dismissing
alarm bit 23 (Resume Pump) by its bit index cleared it — the alarm bitmask
went `0x800008` → `0x8` on re-read. The same log exposed a sign-conversion
slip: the pump answers a dismissal with opcode 0xB9 (-71), not 0xB7, so the
first build reported failure for a dismissal that had in fact worked.

That live pump also demonstrated a Pump Reset alarm (bit 3) blocking the
change, which is why pump reset is in the acknowledgeable family: a reset
Tandem requires acknowledgment and a fresh cartridge load before it delivers
again — precisely this flow. Its warning that pump-side IOB was zeroed does
not change Trio, which keeps its own insulin records.

A refusal that still happens with no alarm active reports the raw
`loadActive`/`loadState`/`prime` ids for the next round of diagnosis.

### The sequence, as the pump actually runs it

The first complete field run corrected the driver's model of the order.
pumpx2's javadoc says it plainly — `ExitChangeCartridgeModeRequest` is
"called after EnterChangeCartridgeModeRequest **once the new cartridge has
been inserted**" — and the pump demonstrated it: the exit immediately
produced the detecting-cartridge stream (20%…100%). Exit-change-mode is the
mid-flow "check the new cartridge" step, not the finish. The corrected flow:

1. Acknowledge any blocking alarm; suspend; `EnterChangeCartridgeMode`
   (stream: "ready to change").
2. User physically swaps the cartridge.
3. **"The new cartridge is installed"** → `ExitChangeCartridgeMode` → the
   pump detects the cartridge (streamed 0–100%).
4. `EnterFillTubingMode` opens the fill — and that is all it does. **On a
   Mobi the fill itself runs only while the pump's own physical button is
   held**; the control stream reports the button state, and the pump refuses
   `ExitFillTubingMode` until some insulin has moved (prime status "entered,
   cannot exit" — surfaced as "waiting for its button to be held"). Trio has
   no command that pushes this insulin, which is the pump requiring a hand
   on the hardware for the one step that sprays insulin.
5. `ExitFillTubingMode` once insulin reaches the tip.
6. Optional cannula prime (`FillCannula`, set inserted and confirmed).
7. Finish = `ResumePumping` — the pump left change mode back at step 3, so
   finishing means restarting insulin, and says so on the button.

Cancelling is stage-aware for the same reason: only a pump still in change
mode has a mode to exit; sending the exit later would not cancel anything,
it would ask the pump to detect whatever cartridge is present.

An interrupted load leaves **started-but-unfinished alerts** behind
(Incomplete Cartridge Change / Fill Tubing / Fill Cannula, bits 13/14/15/49),
and the pump refuses to resume delivery over them. Finishing the change
clears exactly those before sending the resume, and the acknowledge button
covers them alongside the cartridge alarms — because the user completing
the change *is* the completion of those operations. Low Insulin and every
other alert is a real warning, not a leftover, and is never dismissed.

Reading the state first also means a load the user started on the pump, or an
earlier attempt whose reply was lost, is **adopted** rather than restarted.

The safety model follows from the second point. Trio cannot see the infusion
set, so it asks, and the two fill steps need **opposite** answers:

| Step | Required confirmation |
|---|---|
| Fill tubing | the set is **off the body** — insulin sprays from the end of the line |
| Prime cannula | the set is **inserted and connected** — the prime fills its dead space |

A confirmation is good for ten minutes, is cleared whenever the stage advances,
and is never persisted: after an app restart the user answers again rather than
inheriting an answer Trio cannot vouch for. Nothing runs automatically — each
step is a separate button — and while a change is open Trio refuses every
dosing command and reports delivery as suspended, so the loop cannot fight the
change. A session older than two hours stops being trusted, because by then the
pump's real state is anyone's guess.

Removing the pump, or turning the opt-in off, clears the session; cancelling
attempts to leave fill-tubing mode and change mode in turn, and tells the user
to check the pump if either failed.

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
  TandemCartridgeChange.swift      Cartridge change / fill tubing / prime cannula
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
    TandemCartridgeMessages.swift  Cartridge control + control-stream progress
    TandemJpakeAuthenticator.swift JPAKE handshake driver + key derivation
    TandemPumpSession.swift        Request/response orchestration + authentication
  UI/
    TandemUICoordinator.swift      Setup/settings navigation controller
    TandemPairingView.swift        Scan + pairing-code entry
    TandemSettingsView.swift       Status, opt-in toggles, minimum-dose test, delete
    TandemCartridgeChangeView.swift Step-by-step cartridge change
```

## Threading

Control-stream progress is the one inbound path with no request behind it: the
pump pushes it during a cartridge change. Those frames are reassembled in their
own accumulator, signature-checked like any control response — forged progress
could otherwise convince Trio a prime finished when it had not — and handed to
the delegate outside the session lock.

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
hardware (firmware 7.6.0.1).

The **Mobi paths — JPAKE pairing, temp rate, suspend and resume — are unverified
on hardware.** They are transcribed from the protocol and covered by unit tests,
but must be tested against a real pump before being relied on.

The **cartridge-change flow is unverified on hardware and, unlike everything
else here, has no reference implementation behind its sequencing** (see above).
Treat it as the least trustworthy surface in the driver: the encodings are
tested, the ordering is a reconstruction. Changing the cartridge on the pump
itself remains the safer option.
