import Foundation
import Testing

@testable import Trio

@Suite("Follower Pairing Tests") struct FollowerPairingTests {
    @Test("Verification code is deterministic and matches the follower app") func verificationCode() {
        // The follower app (FollowerApp/lib/models/pairing_bundle.dart) derives
        // the same code from the same secret; these vectors pin both sides.
        #expect(PairedFollower.verificationCode(forSecret: "test-secret") == "716219")
        #expect(PairedFollower.verificationCode(forSecret: "u8Fyar0N5wCCPzXKvV9V3wJ0lC0T3rH2m8Q1a2b3c4d=") == "714600")
    }

    @Test("Pairing bundle encodes with the wire field names") func pairingBundleEncoding() throws {
        let bundle = FollowerPairingBundle(
            version: 1,
            type: FollowerPairingBundle.pairingType,
            followerId: "F00",
            followerName: "Mom",
            hostName: "Kid's iPhone",
            secret: "secret",
            apns: FollowerPairingBundle.APNSInfo(
                deviceToken: "token",
                bundleId: "org.example.trio",
                teamId: "TEAM",
                keyId: "KEY",
                apnsKey: "-----BEGIN PRIVATE KEY-----",
                production: true
            ),
            limits: FollowerPairingBundle.Limits(maxBolus: 6.5, maxCarbs: 120, units: "mg/dL"),
            fcmAvailable: true
        )

        let data = try JSONEncoder().encode(bundle)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["v"] as? Int == 1)
        #expect(json["type"] as? String == "trio-follower-pairing")
        #expect(json["follower_id"] as? String == "F00")
        #expect(json["follower_name"] as? String == "Mom")
        #expect(json["host_name"] as? String == "Kid's iPhone")

        let apns = try #require(json["apns"] as? [String: Any])
        #expect(apns["device_token"] as? String == "token")
        #expect(apns["bundle_id"] as? String == "org.example.trio")
        #expect(apns["team_id"] as? String == "TEAM")
        #expect(apns["key_id"] as? String == "KEY")
        #expect(apns["production"] as? Bool == true)

        let limits = try #require(json["limits"] as? [String: Any])
        #expect(limits["max_bolus"] != nil)
        #expect(limits["max_carbs"] != nil)
        #expect(limits["units"] as? String == "mg/dL")
        #expect(json["fcm_available"] as? Bool == true)
        #expect(json["nightscout"] == nil)
    }

    @Test("Status snapshot encodes with the wire field names") func statusSnapshotEncoding() throws {
        let snapshot = FollowerStatusSnapshot(
            type: "status",
            timestamp: 1_723_400_000,
            units: "mg/dL",
            readings: [FollowerStatusSnapshot.Reading(sgv: 104, date: 1_723_399_700, direction: "Flat")],
            iob: 1.25,
            cob: 15,
            lastLoop: 1_723_399_900,
            eventualBG: 120,
            tempTarget: FollowerStatusSnapshot.ActiveTempTarget(
                target: 140,
                name: "Exercise",
                startedAt: 1_723_398_000,
                duration: 120
            ),
            override: nil,
            maxBolus: 6.5,
            maxCarbs: 120,
            low: 70,
            high: 180
        )

        let data = try JSONEncoder().encode(snapshot)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["type"] as? String == "status")
        #expect(json["units"] as? String == "mg/dL")
        #expect(json["last_loop"] as? Double == 1_723_399_900)
        #expect(json["eventual_bg"] as? Double == 120)
        #expect(json["max_bolus"] as? Double == 6.5)

        let readings = try #require(json["readings"] as? [[String: Any]])
        #expect(readings.first?["sgv"] as? Int == 104)
        #expect(readings.first?["direction"] as? String == "Flat")

        let tempTarget = try #require(json["temp_target"] as? [String: Any])
        #expect(tempTarget["target"] as? Double == 140)
        #expect(tempTarget["started_at"] as? Double == 1_723_398_000)

        // The follower colours its chart and widgets with these rather than
        // assuming 70/180.
        #expect(json["low"] as? Double == 70)
        #expect(json["high"] as? Double == 180)
    }

    @Test("Per-follower thresholds replace the defaults in the snapshot") func snapshotThresholds() {
        let snapshot = FollowerStatusSnapshot(
            type: "status",
            timestamp: 1_723_400_000,
            units: "mg/dL",
            readings: [],
            iob: nil,
            cob: nil,
            lastLoop: nil,
            eventualBG: nil,
            tempTarget: nil,
            override: nil,
            maxBolus: 6.5,
            maxCarbs: 120,
            low: 70,
            high: 180
        )

        var settings = FollowerAlertSettings.default
        settings.low.threshold = 80
        settings.high.threshold = 200

        let personalised = snapshot.withThresholds(from: settings)
        #expect(personalised.low == 80)
        #expect(personalised.high == 200)
    }

    @Test("Alert thresholds stay ordered however they are edited") func thresholdClamping() {
        var settings = FollowerAlertSettings.default
        // Drag the low above the high; the store must not be left watching for a
        // low that can never fire below a high that always does.
        settings.low.threshold = 300
        settings.clampThresholds()

        #expect(settings.urgentLow.threshold < settings.low.threshold)
        #expect(settings.low.threshold < settings.high.threshold)
        #expect(settings.high.threshold < settings.urgentHigh.threshold)
        #expect(settings.urgentHigh.threshold <= 400)
    }

    @Test("A condition holds until glucose clears it by the hysteresis margin") func alertHysteresis() {
        let settings = FollowerAlertSettings.default

        // Falling through 70 raises a low.
        #expect(settings.kind(forGlucose: 69, previous: nil) == .low)
        // Ticking back to 71 does not clear it, so it cannot re-fire at 69.
        #expect(settings.kind(forGlucose: 71, previous: .low) == .low)
        // Clear of the margin, it does.
        #expect(settings.kind(forGlucose: 74, previous: .low) == nil)
        // In range with nothing active stays quiet.
        #expect(settings.kind(forGlucose: 120, previous: nil) == nil)
        // The more severe condition wins.
        #expect(settings.kind(forGlucose: 50, previous: .low) == .urgentLow)
    }

    @Test("Followers paired before alert settings existed still decode") func legacyFollowerDecoding() throws {
        // Exactly what the keychain holds for a follower paired before this
        // feature: no `alerts` key at all.
        let json = Data(
            #"{"id":"abc","name":"Mom","secret":"s","createdAt":760000000,"lastSequence":3}"#.utf8
        )
        let follower = try JSONDecoder().decode(PairedFollower.self, from: json)

        #expect(follower.name == "Mom")
        #expect(follower.alerts == nil)
        // And it falls back to the defaults rather than alerting on nothing.
        #expect(follower.alertSettings == FollowerAlertSettings.default)
    }

    @Test("Register-follower payload decodes push registration fields") func registerFollowerDecoding() throws {
        let json = """
        {
            "user": "Mom",
            "command_type": "register_follower",
            "timestamp": 1723400000.0,
            "sequence": 3,
            "push_token": "abc123",
            "push_transport": "apns",
            "push_bundle_id": "org.nightscout.triofollower",
            "push_environment": "production"
        }
        """
        let payload = try JSONDecoder().decode(CommandPayload.self, from: Data(json.utf8))
        #expect(payload.commandType == .registerFollower)
        #expect(payload.pushToken == "abc123")
        #expect(payload.pushTransport == "apns")
        #expect(payload.pushBundleId == "org.nightscout.triofollower")
        #expect(payload.pushEnvironment == "production")
    }

    @Test("PKCS#8 wrapper is unwrapped to PKCS#1") func pkcs8Unwrap() throws {
        // Minimal synthetic PKCS#8 structure wrapping a 4-byte "key".
        let innerKey: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let algorithm: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        var body: [UInt8] = [0x02, 0x01, 0x00] // INTEGER 0
        body += algorithm
        body += [0x04, UInt8(innerKey.count)] + innerKey // OCTET STRING
        let der = Data([0x30, UInt8(body.count)] + body)

        let unwrapped = try #require(FollowerPushSender.pkcs1Data(fromPKCS8: der))
        #expect(Array(unwrapped) == innerKey)

        // PKCS#1 data (no algorithm sequence) is left alone.
        let pkcs1 = Data([0x30, 0x06, 0x02, 0x01, 0x00, 0x02, 0x01, 0x11])
        #expect(FollowerPushSender.pkcs1Data(fromPKCS8: pkcs1) == nil)
    }

    @Test("Encrypted push message decodes follower envelope") func envelopeDecoding() throws {
        let withFollower = """
        {"encrypted_data": "abc", "follower_id": "F00", "aps": {"content-available": 1}}
        """
        let message = try JSONDecoder().decode(EncryptedPushMessage.self, from: Data(withFollower.utf8))
        #expect(message.encryptedData == "abc")
        #expect(message.followerId == "F00")

        // Legacy senders (no follower_id) must keep decoding.
        let legacy = """
        {"encrypted_data": "abc"}
        """
        let legacyMessage = try JSONDecoder().decode(EncryptedPushMessage.self, from: Data(legacy.utf8))
        #expect(legacyMessage.followerId == nil)
    }

    @Test("Command payload decodes the follower sequence number") func sequenceDecoding() throws {
        let json = """
        {
            "user": "Mom",
            "command_type": "bolus",
            "timestamp": 1723400000.0,
            "bolus_amount": 1.5,
            "sequence": 42
        }
        """
        let payload = try JSONDecoder().decode(CommandPayload.self, from: Data(json.utf8))
        #expect(payload.sequence == 42)
        #expect(payload.commandType == .bolus)

        let withoutSequence = """
        {"user": "Mom", "command_type": "cancel_override", "timestamp": 1723400000.0}
        """
        let legacyPayload = try JSONDecoder().decode(CommandPayload.self, from: Data(withoutSequence.utf8))
        #expect(legacyPayload.sequence == nil)
    }
}
