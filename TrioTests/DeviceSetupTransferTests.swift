import Foundation
import Testing

@testable import Trio

@Suite("Device Setup Transfer Tests") struct DeviceSetupTransferTests {
    private func makeTransfer() -> DeviceSetupTransfer {
        var backup = TrioSettingsBackup()
        backup.exportDate = Date()
        backup.appVersion = "1.0 (100)"
        backup.insulinConcentrationFactor = 1
        backup.basalProfile = [BasalProfileEntry(start: "00:00", minutes: 0, rate: 0.85)]
        backup.mealPresets = [MealPresetBackup(dish: "Pizza", carbs: 60, fat: 20, protein: 15)]

        let follower = PairedFollower(
            id: "F00",
            name: "Mom",
            secret: "u8Fyar0N5wCCPzXKvV9V3wJ0lC0T3rH2m8Q1a2b3c4d=",
            createdAt: Date(),
            lastSequence: 41,
            lastSeenAt: Date(),
            pushToken: "push-token",
            pushTransport: "apns",
            pushBundleId: "org.example.follower",
            pushEnvironment: "production",
            alerts: nil
        )

        var transfer = DeviceSetupTransfer()
        transfer.createdAt = Date()
        transfer.hostName = "Kid's iPhone"
        transfer.appVersion = "1.0 (100)"
        transfer.backup = backup
        transfer.remoteControl = RemoteControlTransfer(
            enabled: true,
            sharedSecret: "legacy-secret",
            apnsTeamId: "TEAM",
            apnsKeyId: "KEY",
            apnsKey: "-----BEGIN PRIVATE KEY-----",
            fcmServiceAccountJSON: nil,
            followers: [follower]
        )
        return transfer
    }

    @Test("Transfer survives the QR frame round trip, frames scanned out of order") func roundTrip() throws {
        let transfer = makeTransfer()
        // A small chunk size forces several frames even for this compact payload.
        let frames = try DeviceSetupQRCodec.encode(transfer, chunkLength: 120)
        #expect(frames.count > 2)

        let assembler = DeviceSetupScanAssembler()
        for frame in frames.shuffled() {
            try assembler.add(frame)
        }
        #expect(assembler.isComplete)

        let decoded = try assembler.assemble()
        #expect(decoded.hostName == "Kid's iPhone")
        #expect(decoded.backup?.basalProfile?.first?.rate == 0.85)
        #expect(decoded.backup?.mealPresets?.first?.dish == "Pizza")

        let follower = try #require(decoded.remoteControl?.followers?.first)
        #expect(follower.id == "F00")
        #expect(follower.secret == "u8Fyar0N5wCCPzXKvV9V3wJ0lC0T3rH2m8Q1a2b3c4d=")
        // Replay protection carries over: the new host must keep rejecting
        // sequence numbers the old host already consumed.
        #expect(follower.lastSequence == 41)
        #expect(follower.pushToken == "push-token")
        #expect(decoded.remoteControl?.enabled == true)
        #expect(decoded.remoteControl?.sharedSecret == "legacy-secret")
        #expect(decoded.remoteControl?.apnsKey == "-----BEGIN PRIVATE KEY-----")
    }

    @Test("Duplicate frames are ignored, not errors") func duplicateFrames() throws {
        let frames = try DeviceSetupQRCodec.encode(makeTransfer(), chunkLength: 200)
        let assembler = DeviceSetupScanAssembler()
        #expect(try assembler.add(frames[0]) == true)
        #expect(try assembler.add(frames[0]) == false)
        #expect(assembler.receivedCount == 1)
    }

    @Test("Foreign QR codes are rejected as not-a-setup-frame") func foreignCode() {
        let assembler = DeviceSetupScanAssembler()
        #expect(throws: DeviceSetupCodecError.self) {
            try assembler.add("https://example.com")
        }
        #expect(throws: DeviceSetupCodecError.self) {
            // The follower pairing QR is JSON, not a setup frame.
            try assembler.add("{\"type\":\"trio-follower-pairing\"}")
        }
    }

    @Test("Frames of a different transfer session are rejected") func mismatchedSession() throws {
        var other = makeTransfer()
        other.hostName = "Another phone"

        let frames = try DeviceSetupQRCodec.encode(makeTransfer(), chunkLength: 120)
        let otherFrames = try DeviceSetupQRCodec.encode(other, chunkLength: 120)

        let assembler = DeviceSetupScanAssembler()
        try assembler.add(frames[0])
        #expect(throws: DeviceSetupCodecError.self) {
            try assembler.add(otherFrames[1])
        }
    }

    @Test("A tampered chunk fails the integrity check on assembly") func tamperedChunk() throws {
        let frames = try DeviceSetupQRCodec.encode(makeTransfer(), chunkLength: 120)
        // Flip payload characters in one frame while keeping its header intact.
        let parts = frames[1].split(separator: ":", maxSplits: 4).map(String.init)
        let tampered = parts[0 ..< 4].joined(separator: ":") + ":" + String(parts[4].reversed())

        let assembler = DeviceSetupScanAssembler()
        for (index, frame) in frames.enumerated() {
            try assembler.add(index == 1 ? tampered : frame)
        }
        #expect(assembler.isComplete)
        #expect(throws: DeviceSetupCodecError.self) {
            _ = try assembler.assemble()
        }
    }

    @Test("Assembling an incomplete transfer throws") func incompleteAssembly() throws {
        let frames = try DeviceSetupQRCodec.encode(makeTransfer(), chunkLength: 120)
        let assembler = DeviceSetupScanAssembler()
        try assembler.add(frames[0])
        #expect(!assembler.isComplete)
        #expect(throws: DeviceSetupCodecError.self) {
            _ = try assembler.assemble()
        }
    }

    @Test("Frames from a newer format version are refused with a clear error") func newerVersion() {
        let assembler = DeviceSetupScanAssembler()
        #expect(throws: DeviceSetupCodecError.self) {
            try assembler.add("TRIODS999:abcdef01:0:2:AAAA")
        }
    }

    @Test("Host update encodes with the wire field names the follower expects") func hostUpdateEncoding() throws {
        let update = FollowerHostUpdate(
            type: FollowerHostUpdate.updateType,
            timestamp: 1_723_400_000,
            hostName: "New iPhone",
            apns: FollowerHostUpdate.APNSAddress(
                deviceToken: "new-token",
                bundleId: "org.example.trio",
                production: true
            )
        )

        let data = try JSONEncoder().encode(update)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // The follower app (FollowerApp/lib/services/host_migration_service.dart)
        // reads exactly these keys; these expectations pin both sides.
        #expect(json["type"] as? String == "host_migration")
        #expect(json["timestamp"] as? Double == 1_723_400_000)
        #expect(json["host_name"] as? String == "New iPhone")
        let apns = try #require(json["apns"] as? [String: Any])
        #expect(apns["device_token"] as? String == "new-token")
        #expect(apns["bundle_id"] as? String == "org.example.trio")
        #expect(apns["production"] as? Bool == true)
    }

    @Test("Paired followers decode without the migration flag (pre-existing pairings)") func decodeWithoutFlag() throws {
        let legacy = """
        {"id":"F01","name":"Dad","secret":"s","createdAt":700000000,"lastSequence":3}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let follower = try decoder.decode(PairedFollower.self, from: Data(legacy.utf8))
        #expect(follower.needsHostUpdate == nil)
        #expect(follower.lastSequence == 3)
    }
}
