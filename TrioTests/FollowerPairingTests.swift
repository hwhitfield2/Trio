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
            high: 180,
            ranges: FollowerStatusSnapshot.GlucoseRanges(
                low: 80,
                high: 160,
                target: 110,
                scheme: "dynamicColor"
            ),
            boluses: [
                FollowerStatusSnapshot.Bolus(a: 1.25, t: 1_723_399_600, s: true),
                FollowerStatusSnapshot.Bolus(a: 3, t: 1_723_399_000, s: nil)
            ],
            carbs: [FollowerStatusSnapshot.CarbEntry(g: 30, t: 1_723_399_100)]
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

        // The follower alerts on these rather than assuming 70/180.
        #expect(json["low"] as? Double == 70)
        #expect(json["high"] as? Double == 180)

        // And colours its chart by these, which are the host's own display
        // settings and nothing to do with what this follower is alerted on.
        let ranges = try #require(json["ranges"] as? [String: Any])
        #expect(ranges["low"] as? Double == 80)
        #expect(ranges["high"] as? Double == 160)
        #expect(ranges["target"] as? Double == 110)
        #expect(ranges["scheme"] as? String == "dynamicColor")

        // Short keys, because every treatment in a snapshot costs a glucose
        // reading out of the same push budget.
        let boluses = try #require(json["boluses"] as? [[String: Any]])
        #expect(boluses.first?["a"] as? Double == 1.25)
        #expect(boluses.first?["t"] as? Double == 1_723_399_600)
        #expect(boluses.first?["s"] as? Bool == true)
        // A bolus somebody asked for says nothing rather than saying false.
        #expect(boluses[1]["s"] == nil)

        let carbs = try #require(json["carbs"] as? [[String: Any]])
        #expect(carbs.first?["g"] as? Double == 30)
        #expect(carbs.first?["t"] as? Double == 1_723_399_100)
    }

    // MARK: - Push budget

    /// Newest first, five minutes apart, like the host sends them.
    private func readings(_ count: Int, from now: TimeInterval) -> [FollowerStatusSnapshot.Reading] {
        (0 ..< count).map {
            FollowerStatusSnapshot.Reading(sgv: 120, date: now - Double($0) * 300, direction: "Flat")
        }
    }

    private func budgetSnapshot(
        readings: [FollowerStatusSnapshot.Reading],
        boluses: [FollowerStatusSnapshot.Bolus] = [],
        carbs: [FollowerStatusSnapshot.CarbEntry] = []
    ) -> FollowerStatusSnapshot {
        FollowerStatusSnapshot(
            type: "status",
            timestamp: 1_723_400_000,
            units: "mg/dL",
            readings: readings,
            iob: 1.25,
            cob: 15,
            lastLoop: 1_723_399_900,
            eventualBG: 120,
            tempTarget: nil,
            override: nil,
            maxBolus: 6.5,
            maxCarbs: 120,
            low: 70,
            high: 180,
            boluses: boluses,
            carbs: carbs
        )
    }

    private func decoded(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("A snapshot is trimmed until the push it becomes fits APNS")
    func payloadFitsThePushLimit() throws {
        let now: TimeInterval = 1_723_400_000
        let snapshot = budgetSnapshot(
            readings: readings(48, from: now),
            boluses: (0 ..< 12).map {
                FollowerStatusSnapshot.Bolus(a: 1.25, t: now - Double($0) * 900, s: nil)
            },
            carbs: (0 ..< 8).map {
                FollowerStatusSnapshot.CarbEntry(g: 30, t: now - Double($0) * 1200)
            }
        )

        let data = try snapshot.encodedWithinPushLimit(using: JSONEncoder())
        #expect(
            FollowerStatusSnapshot.projectedPayloadSize(plaintextBytes: data.count)
                <= FollowerStatusSnapshot.apnsPayloadLimit
        )
    }

    @Test("Treatments the chart could not draw are the first thing dropped")
    func treatmentsOffTheChartAreDropped() throws {
        let now: TimeInterval = 1_723_400_000
        // One bolus an hour before the oldest of two readings: nothing on the
        // follower's chart for it to sit against.
        let snapshot = budgetSnapshot(
            readings: readings(2, from: now),
            boluses: [FollowerStatusSnapshot.Bolus(a: 1, t: now - 3600, s: nil)],
            carbs: [FollowerStatusSnapshot.CarbEntry(g: 30, t: now - 60)]
        )

        let json = try decoded(snapshot.encodedWithinPushLimit(using: JSONEncoder()))
        #expect((json["boluses"] as? [[String: Any]])?.isEmpty == true)
        #expect((json["carbs"] as? [[String: Any]])?.count == 1)
        // ...and this one fits without giving up either reading.
        #expect((json["readings"] as? [[String: Any]])?.count == 2)
    }

    @Test("Glucose gives way before treatments do, until two hours are left")
    func readingsGiveWayFirst() throws {
        let now: TimeInterval = 1_723_400_000
        // Every treatment sits inside the readings' window, so nothing is
        // dropped for being off the chart; the payload has to be cut instead.
        let snapshot = budgetSnapshot(
            readings: readings(48, from: now),
            boluses: (0 ..< 20).map {
                FollowerStatusSnapshot.Bolus(a: 1.25, t: now - Double($0) * 60, s: true)
            },
            carbs: (0 ..< 16).map {
                FollowerStatusSnapshot.CarbEntry(g: 30, t: now - Double($0) * 60)
            }
        )

        let json = try decoded(snapshot.encodedWithinPushLimit(using: JSONEncoder()))
        let keptReadings = (json["readings"] as? [[String: Any]])?.count ?? 0
        let keptBoluses = (json["boluses"] as? [[String: Any]])?.count ?? 0

        // Readings were trimmed, but not past the floor, and the treatments
        // near the newest readings survived: a follower has to be able to see
        // that the climb was already answered.
        #expect(keptReadings < 48)
        #expect(keptReadings >= FollowerStatusSnapshot.minimumReadings)
        #expect(keptBoluses > 0)
    }

    @Test("Per-follower thresholds leave the host's display ranges alone")
    func rangesSurvivePersonalisation() {
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
            high: 180,
            ranges: FollowerStatusSnapshot.GlucoseRanges(
                low: 70,
                high: 180,
                target: 100,
                scheme: "staticColor"
            )
        )

        var settings = FollowerAlertSettings.default
        settings.low.threshold = 80
        settings.high.threshold = 200

        // A follower that wants to be woken at 80 has not asked for its chart
        // to be redrawn; the host still displays what the host displays.
        let personalised = snapshot.withThresholds(from: settings)
        #expect(personalised.low == 80)
        #expect(personalised.ranges?.low == 70)
        #expect(personalised.ranges?.high == 180)
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
