import Foundation
import CloudScrobbleCore

struct AppConfig {
    let soundCloudClientID: String
    let soundCloudRedirectURI: String
    let tokenBrokerBaseURL: URL
    let lastFMAPIKey: String
    let lastFMAPISecret: String

    static let requiredEnvironmentKeys = [
        "SOUNDCLOUD_CLIENT_ID",
        "SOUNDCLOUD_REDIRECT_URI",
        "SOUNDCLOUD_TOKEN_BROKER_BASE_URL",
        "LASTFM_API_KEY",
        "LASTFM_API_SECRET"
    ]

    static func loadFromEnvironment() -> AppConfig? {
        let env = ProcessInfo.processInfo.environment

        guard let soundCloudClientID = env["SOUNDCLOUD_CLIENT_ID"],
              let redirectURI = env["SOUNDCLOUD_REDIRECT_URI"],
              let tokenBrokerRaw = env["SOUNDCLOUD_TOKEN_BROKER_BASE_URL"],
              let tokenBrokerBaseURL = URL(string: tokenBrokerRaw),
              let lastFMAPIKey = env["LASTFM_API_KEY"],
              let lastFMAPISecret = env["LASTFM_API_SECRET"] else {
            return nil
        }

        return AppConfig(
            soundCloudClientID: soundCloudClientID,
            soundCloudRedirectURI: redirectURI,
            tokenBrokerBaseURL: tokenBrokerBaseURL,
            lastFMAPIKey: lastFMAPIKey,
            lastFMAPISecret: lastFMAPISecret
        )
    }

    static func missingEnvironmentKeys() -> [String] {
        let env = ProcessInfo.processInfo.environment
        return requiredEnvironmentKeys.filter { key in
            guard let value = env[key] else { return true }
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
