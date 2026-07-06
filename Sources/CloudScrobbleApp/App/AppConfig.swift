import Foundation
import CloudScrobbleCore

struct AppConfig {
    let soundCloudClientID: String
    let soundCloudRedirectURI: String
    let tokenBrokerBaseURL: URL
    let appAPIKey: String?

    private static let deployedTokenBrokerBaseURL = URL(string: "https://broker.example")!

    static let requiredConfigurationKeys = [
        "SOUNDCLOUD_CLIENT_ID",
        "SOUNDCLOUD_REDIRECT_URI"
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
              let rawRedirectURI = stringValue(for: "SOUNDCLOUD_REDIRECT_URI", in: values) else {
            return nil
        }

        guard let redirectURI = URLComponents(string: rawRedirectURI),
              let redirectScheme = redirectURI.scheme,
              !redirectScheme.isEmpty,
              redirectURI.host != nil || !redirectURI.path.isEmpty else {
            return nil
        }

        let tokenBrokerBaseURL = validatedTokenBrokerURL(from: values)
        let appAPIKey = stringValue(for: "CS_APP_API_KEY", in: values)

        return AppConfig(
            soundCloudClientID: rawSoundCloudClientID,
            soundCloudRedirectURI: rawRedirectURI,
            tokenBrokerBaseURL: tokenBrokerBaseURL,
            appAPIKey: appAPIKey
        )
    }

    private static func validatedTokenBrokerURL(from values: [String: Any]) -> URL {
        guard let rawTokenBroker = stringValue(for: "SOUNDCLOUD_TOKEN_BROKER_BASE_URL", in: values),
              let tokenBrokerBaseURL = URL(string: rawTokenBroker),
              let tokenBrokerScheme = tokenBrokerBaseURL.scheme?.lowercased(),
              ["http", "https"].contains(tokenBrokerScheme),
              tokenBrokerBaseURL.host != nil else {
            return deployedTokenBrokerBaseURL
        }

        return publicTokenBrokerURL(for: tokenBrokerBaseURL)
    }

    private static func publicTokenBrokerURL(for configuredURL: URL) -> URL {
        NetworkURLPolicy.isLocalNetworkURL(configuredURL) ? deployedTokenBrokerBaseURL : configuredURL
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
