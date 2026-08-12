import CryptoSwift
import Foundation
import Security

struct SecureMessenger {
    private let sharedKey: [UInt8]

    init?(sharedSecret: String) {
        guard let secretData = sharedSecret.data(using: .utf8) else {
            return nil
        }
        sharedKey = Array(secretData.sha256())
    }

    /// Encrypts arbitrary JSON data using the same wire format `decrypt`
    /// expects: base64( nonce(12) || ciphertext || GCM tag(16) ). Used for
    /// host → follower status pushes.
    func encrypt(data: Data) throws -> String {
        var nonce = [UInt8](repeating: 0, count: 12)
        let status = SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce)
        guard status == errSecSuccess else {
            throw NSError(
                domain: "SecureMessenger",
                code: 102,
                userInfo: [NSLocalizedDescriptionKey: "Failed to generate a random nonce"]
            )
        }
        let gcm = GCM(iv: nonce, mode: .combined)
        let aes = try AES(key: sharedKey, blockMode: gcm, padding: .noPadding)
        let ciphertextAndTag = try aes.encrypt(Array(data))
        return Data(nonce + ciphertextAndTag).base64EncodedString()
    }

    func decrypt(base64EncodedString: String) throws -> CommandPayload {
        guard let combinedData = Data(base64Encoded: base64EncodedString) else {
            throw NSError(domain: "SecureMessenger", code: 100, userInfo: [NSLocalizedDescriptionKey: "Invalid Base64 string"])
        }

        let nonceSize = 12
        guard combinedData.count > nonceSize else {
            throw NSError(
                domain: "SecureMessenger",
                code: 101,
                userInfo: [NSLocalizedDescriptionKey: "Encrypted data is too short to contain a nonce"]
            )
        }
        let nonce = Array(combinedData.prefix(nonceSize))
        let ciphertextAndTag = Array(combinedData.suffix(from: nonceSize))
        let gcm = GCM(iv: nonce, mode: .combined)
        let aes = try AES(key: sharedKey, blockMode: gcm, padding: .noPadding)
        let decryptedBytes = try aes.decrypt(ciphertextAndTag)
        let decryptedData = Data(decryptedBytes)
        let commandPayload = try JSONDecoder().decode(CommandPayload.self, from: decryptedData)

        return commandPayload
    }
}
