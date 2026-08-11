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
5. **No new server infrastructure.** Commands ride the existing APNS path;
   status display uses the existing Nightscout site. Android followers talk
   to APNS directly (plain HTTPS/2) — no Firebase needed.

## Transport

```
┌──────────────┐  E2E-encrypted command    ┌───────┐  background push   ┌──────────┐
│ Follower app │ ─────────────────────────▶│ APNS  │ ──────────────────▶│ Trio host│
│ (iOS/Android)│      (HTTPS/2, ES256 JWT) └───────┘  (encrypted blob)  │          │
└──────┬───────┘                                                        └────┬─────┘
       │                     glucose / IOB / COB / treatments                │
       └────────────────────────◀── Nightscout ──◀───────────────────────────┘
```

The follower authenticates to APNS with the developer account's `.p8` key
(entered once on the host, delivered during pairing). Apple never sees
plaintext commands — the payload is an opaque AES-GCM blob.

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
  "nightscout": { "url": "https://...", "api_secret": "<optional>" },
  "limits": { "max_bolus": 6.5, "max_carbs": 120, "units": "mg/dL" }
}
```

`nightscout` is omitted when the host has no Nightscout configured; the
follower then works command-only. `limits` mirrors the host's settings at
pairing time and is enforced in the follower UI as a first gate — the host
remains the authority and re-validates every command.

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
| `command_type` | string | `bolus`, `meal`, `temp_target`, `cancel_temp_target`, `start_override`, `cancel_override` |
| `sequence` | int | **New.** Required on the follower path; strictly increasing per follower |
| `bolus_amount`, `carbs`, `fat`, `protein`, `target`, `duration`, `overrideName`, `scheduled_time` | | As before (`target` in mg/dL, `duration` minutes) |

### Replay protection

The host stores `lastSequence` per follower and accepts a command only when
`sequence > lastSequence` (then persists the new value). The follower
reserves the next number *before* sending, so an ambiguous send failure can
never lead to reuse. Gaps are fine. A follower that loses its counter (app
reinstall) must re-pair — which is the desired behavior, since its secret
store was destroyed.

### Execution feedback

APNS acceptance only proves hand-off to Apple. Actual results surface as
Trio's existing return notifications and as Nightscout treatments, which the
follower shows on its status screen.

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
  plus sequence numbers (replay).
- **Apple/network**: sees only ciphertext, sender metadata, and the target
  device token.
- **Nightscout credentials** in the bundle grant the same read/write access
  the host already delegates to any follow setup; omit Nightscout on the host
  if that is not acceptable.
