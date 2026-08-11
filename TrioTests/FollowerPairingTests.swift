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
            nightscout: FollowerPairingBundle.NightscoutInfo(url: "https://ns.example.com", apiSecret: "s"),
            limits: FollowerPairingBundle.Limits(maxBolus: 6.5, maxCarbs: 120, units: "mg/dL")
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
