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

        guard let rawSoundCloudClientID = env["SOUNDCLOUD_CLIENT_ID"],
              let rawRedirectURI = env["SOUNDCLOUD_REDIRECT_URI"],
              let rawTokenBroker = env["SOUNDCLOUD_TOKEN_BROKER_BASE_URL"],
              let rawLastFMAPIKey = env["LASTFM_API_KEY"],
              let rawLastFMAPISecret = env["LASTFM_API_SECRET"] else {
            return nil
        }

        let soundCloudClientID = rawSoundCloudClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let redirectURI = rawRedirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenBrokerRaw = rawTokenBroker.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastFMAPIKey = rawLastFMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastFMAPISecret = rawLastFMAPISecret.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !soundCloudClientID.isEmpty,
              !redirectURI.isEmpty,
              !tokenBrokerRaw.isEmpty,
              !lastFMAPIKey.isEmpty,
              !lastFMAPISecret.isEmpty,
              let tokenBrokerBaseURL = URL(string: tokenBrokerRaw) else {
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
