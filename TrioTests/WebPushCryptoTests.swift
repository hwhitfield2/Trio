import CryptoKit
import Foundation
import Testing

@testable import Trio

@Suite("Web Push Crypto Tests") struct WebPushCryptoTests {
    private func data(base64url: String) -> Data {
        WebPushMessenger.base64URLDecode(base64url)!
    }

    @Test("RFC 8291 Appendix A vector encrypts byte-for-byte") func rfc8291Vector() throws {
        // Every input and the expected output are printed in RFC 8291
        // Appendix A; getting this bit-exact means interoperating with every
        // browser's push implementation.
        let uaPublic = data(
            base64url: "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
        )
        let authSecret = data(base64url: "BTBZMqHH6r4Tts7J_aSIgg")
        let salt = data(base64url: "DGv6ra1nlYgDCS1FRnbzlw")
        let asPrivate = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: data(base64url: "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")
        )
        #expect(
            WebPushVAPID.base64URL(asPrivate.publicKey.x963Representation) ==
                "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
        )

        let body = try WebPushEncryptor.encrypt(
            plaintext: Data("When I grow up, I want to be a watermelon".utf8),
            receiverPublicKey: uaPublic,
            authSecret: authSecret,
            ephemeralKey: asPrivate,
            salt: salt
        )

        #expect(
            WebPushVAPID.base64URL(body) ==
                "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml" +
                "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT" +
                "pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
        )
    }

    @Test("Encryptor refuses payloads beyond one push message") func payloadTooLarge() throws {
        let key = P256.KeyAgreement.PrivateKey()
        let oversize = Data(repeating: 0x41, count: WebPushEncryptor.maximumPlaintextBytes + 1)
        #expect(throws: WebPushError.self) {
            _ = try WebPushEncryptor.encrypt(
                plaintext: oversize,
                receiverPublicKey: key.publicKey.x963Representation,
                authSecret: Data(repeating: 0, count: 16)
            )
        }
    }

    @Test("Encryptor refuses malformed subscriptions") func malformedSubscription() throws {
        #expect(throws: WebPushError.self) {
            _ = try WebPushEncryptor.encrypt(
                plaintext: Data("x".utf8),
                receiverPublicKey: Data(repeating: 1, count: 64), // not 65 bytes
                authSecret: Data(repeating: 0, count: 16)
            )
        }
        #expect(throws: WebPushError.self) {
            _ = try WebPushEncryptor.encrypt(
                plaintext: Data("x".utf8),
                receiverPublicKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation,
                authSecret: Data(repeating: 0, count: 15) // not 16 bytes
            )
        }
    }

    @Test("VAPID audience is the push service origin") func vapidAudience() throws {
        #expect(try WebPushVAPID.audience(forEndpoint: URL(string: "https://fcm.googleapis.com/wp/abc")!) ==
            "https://fcm.googleapis.com")
        #expect(try WebPushVAPID.audience(forEndpoint: URL(string: "https://updates.push.services.mozilla.com/wpush/v2/x")!) ==
            "https://updates.push.services.mozilla.com")
        #expect(try WebPushVAPID.audience(forEndpoint: URL(string: "https://example.com:8443/push")!) ==
            "https://example.com:8443")
    }

    @Test("VAPID authorization header carries a verifiable ES256 JWT") func vapidHeader() throws {
        let key = P256.Signing.PrivateKey()
        let now = Date(timeIntervalSince1970: 1_723_400_000)
        let header = try WebPushVAPID.authorizationHeader(
            endpoint: URL(string: "https://fcm.googleapis.com/wp/some-token")!,
            privateKeyRaw: key.rawRepresentation,
            now: now
        )

        #expect(header.hasPrefix("vapid t="))
        let parts = header.dropFirst("vapid t=".count).components(separatedBy: ", k=")
        let jwt = try #require(parts.first)
        let publicKey = try #require(parts.last)
        #expect(publicKey == WebPushVAPID.base64URL(key.publicKey.x963Representation))

        let segments = jwt.components(separatedBy: ".")
        #expect(segments.count == 3)

        let headerJSON = try #require(WebPushMessenger.base64URLDecode(segments[0]))
        let headerObject = try #require(JSONSerialization.jsonObject(with: headerJSON) as? [String: Any])
        #expect(headerObject["alg"] as? String == "ES256")
        #expect(headerObject["typ"] as? String == "JWT")

        let claimsJSON = try #require(WebPushMessenger.base64URLDecode(segments[1]))
        let claims = try #require(JSONSerialization.jsonObject(with: claimsJSON) as? [String: Any])
        #expect(claims["aud"] as? String == "https://fcm.googleapis.com")
        #expect(claims["sub"] as? String == WebPushVAPID.subject)
        #expect(claims["exp"] as? Int == Int(now.timeIntervalSince1970 + WebPushVAPID.tokenLifetime))

        let signatureData = try #require(WebPushMessenger.base64URLDecode(segments[2]))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        let signingInput = Data("\(segments[0]).\(segments[1])".utf8)
        #expect(key.publicKey.isValidSignature(signature, for: signingInput))
    }

    @Test("base64url decoding accepts browser-style unpadded keys") func base64URLDecoding() {
        #expect(WebPushMessenger.base64URLDecode("BTBZMqHH6r4Tts7J_aSIgg")?.count == 16)
        #expect(WebPushMessenger.base64URLDecode("") == nil)
        // '-' and '_' are the url-safe alphabet; '+' and '/' are not used.
        #expect(WebPushMessenger.base64URLDecode("a-b_") != nil)
    }
}
