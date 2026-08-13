import Foundation
import Testing

@testable import Trio

@Suite("Follower Version Checker Tests") struct FollowerVersionCheckerTests {
    @Test("Reads the app version out of the follower's pubspec") func parsePubspec() {
        let pubspec = """
        name: trio_follower
        description: >-
          Follower app for Trio.
        publish_to: "none"
        version: 0.4.2+17

        environment:
          sdk: ">=3.7.0 <4.0.0"
        """

        // The build number after the + is dropped: rebuilding the same version
        // must not make every follower look out of date.
        #expect(FollowerVersionChecker.parseVersion(fromPubspec: pubspec) == "0.4.2")
    }

    @Test("Ignores the version of a dependency") func ignoresNestedVersions() {
        // A dependency's pinned version is indented; the app's own is not.
        let pubspec = """
        name: trio_follower
        dependencies:
          some_package:
            version: 9.9.9
        version: 1.0.0+3
        """

        #expect(FollowerVersionChecker.parseVersion(fromPubspec: pubspec) == "1.0.0")
    }

    @Test("A pubspec with no version yields nothing to compare against") func missingVersion() {
        #expect(FollowerVersionChecker.parseVersion(fromPubspec: "name: trio_follower\n") == nil)
    }

    @Test("Versions compare by number, not by text") func versionOrdering() {
        // The case a string comparison gets backwards.
        #expect(FollowerVersionChecker.isVersion("0.10.0", newerThan: "0.9.0"))
        #expect(!FollowerVersionChecker.isVersion("0.9.0", newerThan: "0.10.0"))

        #expect(FollowerVersionChecker.isVersion("1.0.0", newerThan: "0.9.9"))
        #expect(FollowerVersionChecker.isVersion("0.1.1", newerThan: "0.1.0"))
        #expect(!FollowerVersionChecker.isVersion("0.1.0", newerThan: "0.1.0"))
        // Missing components count as zero, so 1.2 and 1.2.0 are the same release.
        #expect(!FollowerVersionChecker.isVersion("1.2", newerThan: "1.2.0"))
        #expect(FollowerVersionChecker.isVersion("1.2.1", newerThan: "1.2"))
    }

    @Test("An unknown version on either side is never called out of date") func unknownVersions() {
        #expect(!FollowerVersionChecker.isVersion("", newerThan: "1.0.0"))
        #expect(!FollowerVersionChecker.isVersion("1.0.0", newerThan: ""))
    }

    @Test("A follower is only outdated when both versions are known") func outdatedFollower() {
        var follower = PairedFollower(
            id: "F1",
            name: "Mom",
            secret: "secret",
            createdAt: Date(),
            lastSequence: 0,
            lastSeenAt: nil
        )

        // Never reported one: the host cannot know, so it must not claim to.
        #expect(!follower.isOutdated(comparedTo: "1.0.0"))

        follower.appVersion = "0.9.0"
        #expect(follower.isOutdated(comparedTo: "1.0.0"))
        #expect(!follower.isOutdated(comparedTo: "0.9.0"))
        // The host has not managed to look up a release yet.
        #expect(!follower.isOutdated(comparedTo: nil))
    }
}
