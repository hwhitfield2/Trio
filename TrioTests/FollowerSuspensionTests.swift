import Foundation
import Testing

@testable import Trio

@Suite("Follower Suspension Tests") struct FollowerSuspensionTests {
    private func follower(maySuspend: Bool? = nil) -> PairedFollower {
        var follower = PairedFollower(
            id: "F1",
            name: "Mom",
            secret: "secret",
            createdAt: Date(),
            lastSequence: 0,
            lastSeenAt: nil
        )
        follower.maySuspend = maySuspend
        return follower
    }

    @Test("A follower paired before the emergency stop existed may still use it")
    func permissionDefaultsToAllowed() {
        // Absent rather than false: this is a safety feature, and a follower
        // whose pairing predates it should not silently be unable to reach it.
        #expect(follower().maySuspendInsulin)
    }

    @Test("Permission can be withdrawn per follower") func permissionCanBeRevoked() {
        #expect(!follower(maySuspend: false).maySuspendInsulin)
        #expect(follower(maySuspend: true).maySuspendInsulin)
    }

    @Test("A fresh suspension is waiting to be answered") func awaitsAcknowledgement() {
        let suspension = FollowerSuspension(
            followerId: "F1",
            followerName: "Mom",
            requestedAt: Date()
        )
        #expect(suspension.isAwaitingAcknowledgement)
        #expect(suspension.acknowledgedAt == nil)
        #expect(suspension.resumedAt == nil)
    }

    @Test("Answering the alarm and resuming insulin are recorded separately")
    func acknowledgementWithoutResuming() {
        var suspension = FollowerSuspension(
            followerId: "F1",
            followerName: "Mom",
            requestedAt: Date()
        )

        // "I'm alright" without "start my insulin again" is a legitimate
        // answer, and has to remain distinguishable from both the unanswered
        // state and a resumed one.
        suspension.acknowledgedAt = Date()
        #expect(!suspension.isAwaitingAcknowledgement)
        #expect(suspension.resumedAt == nil)

        suspension.resumedAt = Date()
        #expect(suspension.resumedAt != nil)
    }

    @Test("The record survives being written and read back") func codableRoundTrip() throws {
        // It lives in user defaults because the app must know on the next
        // launch that delivery is off and why.
        let original = FollowerSuspension(
            followerId: "F1",
            followerName: "Mom",
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
            acknowledgedAt: Date(timeIntervalSince1970: 1_700_000_600),
            resumedAt: nil
        )

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(FollowerSuspension.self, from: data)

        #expect(restored == original)
        #expect(!restored.isAwaitingAcknowledgement)
    }

    @Test("The alarm repeats often enough to wake someone, and legally")
    func alarmInterval() {
        // iOS rejects a repeating time-interval trigger under 60 seconds, and
        // an alarm nobody hears is the failure this feature exists to avoid.
        #expect(FollowerSuspensionManager.alarmInterval >= 60)
        #expect(FollowerSuspensionManager.alarmInterval <= 5 * 60)
    }

    @Test("Both answers to the alarm are offered on the notification itself")
    func alarmActions() {
        let category = NotificationCategoryFactory.createFollowerSuspensionCategory()
        #expect(category.identifier == NotificationCategoryIdentifier.followerSuspension.rawValue)

        let identifiers = Set(category.actions.map(\.identifier))
        #expect(identifiers == Set(FollowerSuspensionAction.allCases.map(\.rawValue)))
    }
}
