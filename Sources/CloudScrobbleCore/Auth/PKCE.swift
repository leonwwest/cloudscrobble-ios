import CryptoKit
import Foundation
import Security

public struct PKCEPair: Sendable {
    public let codeVerifier: String
    public let codeChallenge: String

    public init(codeVerifier: String, codeChallenge: String) {
        self.codeVerifier = codeVerifier
        self.codeChallenge = codeChallenge
    }
}

public enum PKCE {
    public static func generate() -> PKCEPair {
        let verifier = randomURLSafeString(length: 64)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URLEncode(Data(digest))
        return PKCEPair(codeVerifier: verifier, codeChallenge: challenge)
    }

    public static func randomState(length: Int = 32) -> String {
        randomURLSafeString(length: length)
    }

    private static func randomURLSafeString(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: max(length, 32))
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            fatalError("Unable to generate secure random bytes for PKCE")
        }
        return base64URLEncode(Data(bytes)).prefix(length).description
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
