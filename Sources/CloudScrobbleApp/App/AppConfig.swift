import Foundation
import CloudScrobbleCore

struct AppConfig {
    let soundCloudClientID: String
    let soundCloudRedirectURI: String
    let tokenBrokerBaseURL: URL

    static let requiredConfigurationKeys = [
        "SOUNDCLOUD_CLIENT_ID",
        "SOUNDCLOUD_REDIRECT_URI",
        "SOUNDCLOUD_TOKEN_BROKER_BASE_URL"
    ]

    static func load() -> AppConfig? {
        loadFromEnvironment() ?? loadFromBundleInfo()
    }

    static func loadFromEnvironment() -> AppConfig? {
        makeConfig(from: ProcessInfo.processInfo.environment)
    }

    static func loadFromBundleInfo() -> AppConfig? {
        makeConfig(from: Bundle.main.infoDictionary ?? [:])
    }

    private static func makeConfig(from values: [String: Any]) -> AppConfig? {
        guard let rawSoundCloudClientID = stringValue(for: "SOUNDCLOUD_CLIENT_ID", in: values),
              let rawRedirectURI = stringValue(for: "SOUNDCLOUD_REDIRECT_URI", in: values),
              let rawTokenBroker = stringValue(for: "SOUNDCLOUD_TOKEN_BROKER_BASE_URL", in: values) else {
            return nil
        }

        guard let redirectURI = URLComponents(string: rawRedirectURI),
              let redirectScheme = redirectURI.scheme,
              !redirectScheme.isEmpty,
              redirectURI.host != nil || !redirectURI.path.isEmpty else {
            return nil
        }

        guard let tokenBrokerBaseURL = URL(string: rawTokenBroker),
              let tokenBrokerScheme = tokenBrokerBaseURL.scheme?.lowercased(),
              ["http", "https"].contains(tokenBrokerScheme),
              tokenBrokerBaseURL.host != nil else {
            return nil
        }

        return AppConfig(
            soundCloudClientID: rawSoundCloudClientID,
            soundCloudRedirectURI: rawRedirectURI,
            tokenBrokerBaseURL: tokenBrokerBaseURL
        )
    }

    private static func stringValue(for key: String, in values: [String: Any]) -> String? {
        guard let rawValue = values[key] as? String else {
            return nil
        }

        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("$(") else {
            return nil
        }
        return value
    }

    static func missingConfigurationKeys() -> [String] {
        let env = ProcessInfo.processInfo.environment
        let info = Bundle.main.infoDictionary ?? [:]
        return requiredConfigurationKeys.filter { key in
            stringValue(for: key, in: env) == nil && stringValue(for: key, in: info) == nil
        }
    }
}
