import CryptoKit
import Foundation

public enum LastFMSignature {
    public static func sign(parameters: [String: String], apiSecret: String) -> String {
        let filtered = parameters
            .filter { $0.key != "format" && $0.key != "callback" && $0.key != "api_sig" }
            .sorted { $0.key < $1.key }

        let payload = filtered.map { "\($0.key)\($0.value)" }.joined() + apiSecret
        let digest = Insecure.MD5.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
