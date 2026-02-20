import CryptoKit
import Foundation

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
        let bytes = (0..<length).map { _ in UInt8.random(in: 0...255) }
        return base64URLEncode(Data(bytes)).prefix(length).description
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
