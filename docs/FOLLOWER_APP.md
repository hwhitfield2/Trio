# Trio Follower App — Architecture & Protocol

The follower app (`FollowerApp/`, Flutter, iOS + Android) lets a caregiver
perform Trio's remote-controllable therapy actions — bolus, meal, temp
target, override — from their own phone, with the same safety validation the
host applies to any remote command. This document specifies the pairing and
command protocol shared between the host (Swift) and the follower (Dart).

**Keep in sync:**

| Concern | Host (Swift) | Follower (Dart) |
| --- | --- | --- |
| Pairing bundle | `Trio/Sources/Services/RemoteControl/FollowerPairingManager.swift` | `FollowerApp/lib/models/pairing_bundle.dart` |
| Command payload | `Trio/Sources/Models/CommandPayload.swift` | `FollowerApp/lib/models/command.dart` |
| Encryption | `Trio/Sources/Services/RemoteControl/SecureMessenger.swift` | `FollowerApp/lib/services/secure_messenger.dart` |
| Command handling | `Trio/Sources/Services/RemoteControl/TrioRemoteControl.swift` | `FollowerApp/lib/services/command_service.dart` |
| Status snapshot | `Trio/Sources/Services/RemoteControl/FollowerStatusPublisher.swift` | `FollowerApp/lib/models/status_snapshot.dart` |
| Status delivery | `Trio/Sources/Services/RemoteControl/FollowerPushSender.swift` | `FollowerApp/lib/services/push_service.dart` / `status_service.dart` |

## Design goals

1. **Safe pairing with no manual secret handling.** One QR scan transfers
   everything; a mutual six-digit verification code confirms the scan.
2. **Full parity with the host's remote command set.** Followers can do
   everything Trio accepts remotely, subject to the identical safety checks
   (`BolusSafetyValidator`, override name validation, etc.). Actions that
   inherently require physical access (pump/CGM setup, settings) are out of
   scope by design.
3. **Per-device authority.** Every follower has its own secret; each can be
   revoked individually without re-keying the others or the legacy
   LoopFollow-style shared secret.
4. **Replay protection.** A strictly increasing per-follower sequence number
   on top of the existing ±10-minute timestamp window.
5. **The host device is the data source.** Status (glucose, IOB, COB, loop
   state, active targets/overrides) is read from the host's own storage and
   pushed to followers end-to-end encrypted. No Nightscout or any other
   third-party data service is involved.
6. **No new server infrastructure.** Commands ride the existing APNS path;
   status rides push services in the opposite direction (APNS for iOS
   followers, FCM for Android followers). Android followers *send* commands
   to APNS directly (plain HTTPS/2).

## Transport

```
             commands: E2E-encrypted, HTTPS/2 + ES256 JWT
┌──────────────┐ ──────────────────────────▶ ┌───────────┐ ─────▶ ┌──────────┐
│ Follower app │                             │   APNS    │        │ Trio host│
│ (iOS/Android)│ ◀───────────────────────────│ APNS/FCM  │ ◀───── │  device  │
└──────────────┘   status snapshots:         └───────────┘        └──────────┘
                   E2E-encrypted, pushed by the host on every
                   glucose/loop update and on demand
```

Both directions carry only opaque AES-256-GCM blobs; Apple/Google relay
ciphertext. The follower authenticates to APNS with the developer account's
`.p8` key (entered once on the host, delivered during pairing). The host
pushes status to iOS followers over APNS with that same key, and to Android
followers over FCM using an optional Firebase service-account credential.

## Pairing

### Flow

1. Host user enables Remote Control and stores APNS credentials (Team ID,
   Key ID, `.p8` contents) — Settings → Remote Control. Credentials live in
   the keychain.
2. Host user taps **Pair New Follower**, names the device. The host creates a
   `PairedFollower` with a fresh 256-bit random secret and renders the
   pairing bundle as a QR code, plus a six-digit verification code.
3. Follower scans the QR, computes the verification code from the secret, and
   shows it. The user compares codes and confirms on the follower.
4. Follower stores the bundle in the iOS Keychain / Android Keystore.

The QR code is the security boundary: anyone who captures it can act as that
follower until revoked. The host UI warns against screenshots/sharing, and
the code is only rendered on the host's screen during pairing.

### Pairing bundle (QR payload, JSON, version 1)

```json
{
  "v": 1,
  "type": "trio-follower-pairing",
  "follower_id": "<UUID>",
  "follower_name": "<name given on the host>",
  "host_name": "<host device name>",
  "secret": "<base64, 32 random bytes>",
  "apns": {
    "device_token": "<host APNS device token>",
    "bundle_id": "<host app bundle id>",
    "team_id": "<Apple Developer team id>",
    "key_id": "<APNS auth key id>",
    "apns_key": "<contents of the .p8 file>",
    "production": true
  },
  "limits": { "max_bolus": 6.5, "max_carbs": 120, "units": "mg/dL" },
  "fcm_available": false
}
```

`limits` mirrors the host's settings at pairing time and is enforced in the
follower UI as a first gate — the host remains the authority and re-validates
every command; every status snapshot carries the live limits, which take
precedence on the follower. `fcm_available` tells Android followers whether
the host can push status to them (see Status channel below).

### Verification code

`code = (first 4 bytes of SHA-256(UTF-8(secret)) as big-endian uint32) mod 10^6`,
zero-padded to six digits. Both sides display it; the user confirms equality.

## Command protocol

### Envelope (APNS payload)

```json
{
  "aps": { "alert": {"title": "Trio", "body": "Remote command received"},
           "content-available": 1, "interruption-level": "time-sensitive" },
  "encrypted_data": "<base64( nonce[12] || ciphertext || tag[16] )>",
  "follower_id": "<UUID from pairing>"
}
```

- `follower_id` present → host decrypts with that follower's secret and
  requires a valid `sequence`. Unknown/revoked IDs are rejected.
- `follower_id` absent → legacy shared-secret path (LoopFollow et al.),
  unchanged.

### Encryption

AES-256-GCM. Key = `SHA-256(UTF-8 bytes of the secret string)`. Wire format:
12-byte nonce, ciphertext, 16-byte tag, concatenated and base64-encoded —
identical to the existing `SecureMessenger`.

### Command payload (encrypted plaintext)

Trio's existing `CommandPayload` JSON with one addition:

| Field | Type | Notes |
| --- | --- | --- |
| `user` | string | Follower's name; appears in host logs/notifications |
| `timestamp` | number | Unix seconds; host accepts ±600 s |
| `command_type` | string | `bolus`, `meal`, `temp_target`, `cancel_temp_target`, `start_override`, `cancel_override`, `status_request`, `register_follower` |
| `sequence` | int | **New.** Required on the follower path; strictly increasing per follower |
| `bolus_amount`, `carbs`, `fat`, `protein`, `target`, `duration`, `overrideName`, `scheduled_time` | | As before (`target` in mg/dL, `duration` minutes) |
| `push_token`, `push_transport`, `push_bundle_id`, `push_environment` | string | `register_follower` only: where the host should deliver status pushes (`push_transport`: `apns` or `fcm`) |

`status_request` and `register_follower` are follower-path only (they require
a `follower_id` envelope) and are rejected on the legacy shared-secret path.

### Replay protection

The host stores `lastSequence` per follower and accepts a command only when
`sequence > lastSequence` (then persists the new value). The follower
reserves the next number *before* sending, so an ambiguous send failure can
never lead to reuse. Gaps are fine. A follower that loses its counter (app
reinstall) must re-pair — which is the desired behavior, since its secret
store was destroyed.

### Execution feedback

APNS acceptance only proves hand-off to Apple. After every follower command
the host pushes a fresh status snapshot to that follower, so the effect
(updated IOB/COB, active target/override) is visible within seconds.

## Status channel (host → follower)

The follower's only data source is the host device itself.

1. After pairing (and whenever the OS rotates its push token), the follower
   sends `register_follower` with its push address. The host stores it on the
   `PairedFollower` record.
2. The host observes its own glucose and loop-determination updates
   (`GlucoseObserver` / `DeterminationObserver`) and pushes an encrypted
   status snapshot to every registered follower, throttled to at most one per
   minute. It also pushes immediately after handling a follower command and
   in answer to `status_request` (the follower's pull-to-refresh).
3. Delivery: iOS followers receive a background APNS push sent with the same
   `.p8` key used for commands (with an automatic one-shot sandbox/production
   retry, since debug follower builds register sandbox tokens); Android
   followers receive an FCM data message, authenticated with a Firebase
   service-account JSON the host user can paste in Settings → Remote Control.
   Without that credential Android followers still send commands but get no
   status pushes (`fcm_available: false` in the pairing bundle warns them).

### Status envelope

APNS: `{"aps": {"content-available": 1}, "encrypted_status": "...", "follower_id": "..."}`
(background push, priority 5). FCM: a data-only message with the same
`encrypted_status` / `follower_id` keys.

### Status snapshot (encrypted plaintext)

Encrypted exactly like commands, with the same per-follower key:

```json
{
  "type": "status",
  "timestamp": 1723400000,
  "units": "mg/dL",
  "readings": [ {"sgv": 104, "date": 1723399700, "direction": "Flat"}, ... ],
  "iob": 1.25,
  "cob": 15,
  "last_loop": 1723399900,
  "eventual_bg": 120,
  "temp_target": { "target": 140, "name": "Exercise", "started_at": 1723398000, "duration": 120 },
  "override": { "name": "Sports", "started_at": 1723398000, "duration": 60 },
  "max_bolus": 6.5,
  "max_carbs": 120,
  "low": 70,
  "high": 180,
  "ranges": { "low": 70, "high": 180, "target": 100, "scheme": "staticColor" },
  "boluses": [ {"a": 1.25, "t": 1723399600, "s": true}, ... ],
  "carbs": [ {"g": 30, "t": 1723399100}, ... ]
}
```

`readings` is newest-first, up to 6 hours, always mg/dL. The follower ignores
snapshots older than the one it already has (out-of-order pushes) and marks
data stale in the UI when the newest snapshot is older than 15 minutes.

`boluses` and `carbs` cover the same window as `readings`, newest first, and
are drawn on the follower's chart against the reading each happened nearest.
Keys are short because they compete with glucose for the same 4 KB: `a` is
units, `g` is grams, `t` is Unix seconds, and `s` marks a bolus the loop gave
itself (absent for one a person asked for). When a snapshot will not fit, what
gives way is, in order: treatments outside the readings' window, then the
oldest readings down to two hours, then the oldest treatments, then the rest of
the readings.

The same two arrays travel on to the follower's widgets (times in milliseconds,
matching that payload's chart points) and to its Live Activity (times in
seconds, trimmed to the two hours the Lock Screen chart covers and to eight of
each). A host pushing a Live Activity update directly builds them the same way,
so a pushed Lock Screen and a locally built one draw the same markers.

`low`/`high` are the glucose thresholds *this* follower is alerted on, and are
substituted per follower. `ranges` is a different thing: how the host itself
displays glucose — its own display low and high, the glucose target in force
when the snapshot was built, and its colour scheme (`staticColor` or
`dynamicColor`) — which is what the follower colours each point of its chart
by, so a reading is the same colour on both screens. A host that predates
either sends neither, and the follower falls back to its own defaults.

## Revocation

- Host: Settings → Remote Control → swipe follower → **Revoke**. Deletes the
  secret; subsequent commands from that follower fail decryption lookup and
  are logged.
- Follower: Settings → **Unpair** wipes the bundle from the secure store. The
  UI reminds the user to also revoke on the host.

## Threat model notes

- **Compromised QR during pairing** grants that follower's authority until
  revoked — the QR is displayed only on the host screen and never persisted;
  treat it accordingly.
- **Stolen follower phone**: commands require biometric/passcode confirmation
  in the follower app; the host user can revoke at any time; all commands are
  bounded by host-side safety limits.
- **Push capture/replay**: defeated by AES-GCM (confidentiality/integrity)
  plus sequence numbers (replay). Status snapshots are read-only; the
  follower still rejects stale and out-of-order snapshots by timestamp.
- **Apple/Google/network**: see only ciphertext, sender metadata, and the
  target push token. There is no third-party data store — status exists only
  on the host, in transit as ciphertext, and on the paired follower.
- **Push-registration hijack** would require a valid follower secret and a
  fresh sequence number (registration is an authenticated command); revoking
  the follower kills both commands and status pushes at once.
