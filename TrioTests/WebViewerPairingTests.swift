import Foundation
import Testing

@testable import Trio

@Suite("Web Viewer Pairing Tests") struct WebViewerPairingTests {
    @Test("Viewer bundle encodes with the wire field names and withholds APNS credentials") func viewerBundleEncoding() throws {
        let bundle = ViewerPairingBundle(
            version: 1,
            type: ViewerPairingBundle.pairingType,
            followerId: "V01",
            followerName: "Grandma's laptop",
            hostName: "Kid's iPhone",
            secret: "viewer-test-secret",
            units: "mg/dL",
            vapidPublicKey: "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
        )

        let data = try JSONEncoder().encode(bundle)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["v"] as? Int == 1)
        #expect(json["type"] as? String == "trio-viewer-pairing")
        #expect(json["follower_id"] as? String == "V01")
        #expect(json["follower_name"] as? String == "Grandma's laptop")
        #expect(json["host_name"] as? String == "Kid's iPhone")
        #expect(json["secret"] as? String == "viewer-test-secret")
        #expect(json["units"] as? String == "mg/dL")
        #expect(json["vapid_public_key"] as? String != nil)

        // The read-only guarantee: a viewer bundle must never carry the
        // capability to address the host. If either of these ever appears the
        // feature's security model is broken, not just a field renamed.
        #expect(json["apns"] == nil)
        #expect(json["limits"] == nil)
    }

    @Test("Viewer and follower QR types are distinct") func distinctPairingTypes() {
        #expect(ViewerPairingBundle.pairingType != FollowerPairingBundle.pairingType)
    }

    @Test("Viewer verification code matches the web viewer") func viewerVerificationCode() {
        // The web viewer (WebViewer/js/trio-crypto.js) derives the same code
        // from the same secret; this vector pins both sides.
        #expect(PairedFollower.verificationCode(forSecret: "viewer-test-secret") == "905993")
    }

    @Test("Registration parses only viewer push QR codes") func registrationParsing() throws {
        let valid = """
        {"v":1,"type":"trio-viewer-push","follower_id":"F1","endpoint":"https://push.example/e","p256dh":"AA","auth":"BB","proof":"CC"}
        """
        let registration = try #require(WebViewerPushRegistration.parse(valid))
        #expect(registration.followerId == "F1")
        #expect(registration.endpoint == "https://push.example/e")

        #expect(WebViewerPushRegistration.parse("not json") == nil)
        #expect(WebViewerPushRegistration.parse("{\"v\":1,\"type\":\"trio-follower-pairing\"}") == nil)
        #expect(WebViewerPushRegistration.parse(
            "{\"v\":2,\"type\":\"trio-viewer-push\",\"follower_id\":\"F1\",\"endpoint\":\"e\",\"p256dh\":\"a\",\"auth\":\"b\",\"proof\":\"c\"}"
        ) == nil)
    }

    @Test("Registration proof verifies and rejects tampering") func registrationProof() throws {
        // Vector shared with WebViewer/test/crypto.test.mjs: HMAC-SHA-256 over
        // the newline-joined registration with the secret's UTF-8 bytes as key.
        let secret = "viewer-test-secret"
        let followerId = "5E0F944E-31C2-4F5E-8E3E-0F1F0A9B6A21"
        let endpoint = "https://fcm.googleapis.com/wp/example-subscription-token"
        let p256dh = "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
        let auth = "BTBZMqHH6r4Tts7J_aSIgg"

        let proof = WebViewerPushRegistration.proof(
            followerId: followerId,
            endpoint: endpoint,
            p256dh: p256dh,
            auth: auth,
            secret: secret
        )
        #expect(proof == "maGS3DD81tN-7Vhv5ln-yydsICDDvOKbpnwR67H7b3M")

        let registration = WebViewerPushRegistration(
            version: 1,
            type: WebViewerPushRegistration.registrationType,
            followerId: followerId,
            endpoint: endpoint,
            p256dh: p256dh,
            auth: auth,
            proof: proof
        )
        #expect(registration.verifyProof(secret: secret))
        #expect(!registration.verifyProof(secret: "some-other-secret"))

        let tampered = WebViewerPushRegistration(
            version: 1,
            type: WebViewerPushRegistration.registrationType,
            followerId: followerId,
            endpoint: "https://attacker.example/wp/hijack",
            p256dh: p256dh,
            auth: auth,
            proof: proof
        )
        #expect(!tampered.verifyProof(secret: secret))
    }

    @Test("Followers without the flag keep full control; viewers do not") func mayControlDefaults() throws {
        // A record stored before mayControl existed decodes as a controller.
        let legacy = """
        {"id":"F1","name":"Mom","secret":"s","createdAt":700000000,"lastSequence":3}
        """
        let follower = try JSONDecoder().decode(PairedFollower.self, from: Data(legacy.utf8))
        #expect(follower.mayControlRemotely)
        #expect(!follower.isViewerOnly)

        let viewerJSON = """
        {"id":"V1","name":"Laptop","secret":"s","createdAt":700000000,"lastSequence":0,"mayControl":false}
        """
        let viewer = try JSONDecoder().decode(PairedFollower.self, from: Data(viewerJSON.utf8))
        #expect(!viewer.mayControlRemotely)
        #expect(viewer.isViewerOnly)
    }

    @Test("Web push snapshots respect the tighter payload budget") func webPushBudget() throws {
        #expect(FollowerStatusSnapshot.payloadLimit(forTransport: "webpush") == FollowerStatusSnapshot.webPushPayloadLimit)
        #expect(FollowerStatusSnapshot.payloadLimit(forTransport: "apns") == FollowerStatusSnapshot.apnsPayloadLimit)
        #expect(FollowerStatusSnapshot.payloadLimit(forTransport: nil) == FollowerStatusSnapshot.apnsPayloadLimit)
        #expect(FollowerStatusSnapshot.webPushPayloadLimit < FollowerStatusSnapshot.apnsPayloadLimit)

        // Six hours of readings and treatments overflow the budget by far;
        // the encoder must trim until the projected payload fits web push.
        let readings = (0 ..< 72).map {
            FollowerStatusSnapshot.Reading(sgv: 100 + $0 % 40, date: 1_723_400_000 - Double($0) * 300, direction: "Flat")
        }
        let boluses = (0 ..< 24).map {
            FollowerStatusSnapshot.Bolus(a: 0.55, t: 1_723_400_000 - Double($0) * 900, s: $0 % 2 == 0 ? true : nil)
        }
        let snapshot = FollowerStatusSnapshot(
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
            ranges: nil,
            boluses: boluses,
            carbs: [FollowerStatusSnapshot.CarbEntry(g: 30, t: 1_723_399_100)]
        )

        let encoded = try snapshot.encodedWithinPushLimit(
            using: JSONEncoder(),
            payloadLimit: FollowerStatusSnapshot.webPushPayloadLimit
        )
        #expect(
            FollowerStatusSnapshot.projectedPayloadSize(plaintextBytes: encoded.count) <=
                FollowerStatusSnapshot.webPushPayloadLimit
        )
        // What survives must still read as a trend, not a fragment.
        let decoded = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let keptReadings = try #require(decoded["readings"] as? [[String: Any]])
        #expect(keptReadings.count >= FollowerStatusSnapshot.minimumReadings)
    }
}
