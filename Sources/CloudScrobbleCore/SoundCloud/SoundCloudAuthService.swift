import Foundation

public struct SoundCloudAuthConfiguration: Sendable {
    public let clientID: String
    public let authorizeURL: URL
    public let tokenBrokerBaseURL: URL
    public let defaultScopes: [String]

    public init(
        clientID: String,
        authorizeURL: URL = URL(string: "https://secure.soundcloud.com/authorize")!,
        tokenBrokerBaseURL: URL,
        defaultScopes: [String] = ["non-expiring"]
    ) {
        self.clientID = clientID
        self.authorizeURL = authorizeURL
        self.tokenBrokerBaseURL = tokenBrokerBaseURL
        self.defaultScopes = defaultScopes
    }
}

public actor SoundCloudAuthService: SoundCloudAuthProviding {
    private enum Storage {
        static let tokenAccount = "soundcloud.token"
    }

    private let config: SoundCloudAuthConfiguration
    private let keychain: KeychainStore
    private let httpClient: HTTPClient

    private var inMemoryToken: SoundCloudToken?

    public init(config: SoundCloudAuthConfiguration, keychain: KeychainStore, httpClient: HTTPClient = HTTPClient()) {
        self.config = config
        self.keychain = keychain
        self.httpClient = httpClient
    }

    public func makeAuthorizationURL(codeChallenge: String, state: String, redirectURI: String) async throws -> URL {
        guard var components = URLComponents(url: config.authorizeURL, resolvingAgainstBaseURL: false) else {
            throw CloudScrobbleError.invalidConfiguration("Invalid authorize URL")
        }

        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: config.defaultScopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "display", value: "popup"),
            URLQueryItem(name: "state", value: state)
        ]

        guard let url = components.url else {
            throw CloudScrobbleError.invalidConfiguration("Could not build authorize URL")
        }

        return url
    }

    public func exchangeAuthorizationCode(_ code: String, codeVerifier: String, redirectURI: String) async throws -> SoundCloudToken {
        let endpoint = config.tokenBrokerBaseURL.appending(path: "oauth/soundcloud/exchange")
        let body: [String: String] = [
            "code": code,
            "codeVerifier": codeVerifier,
            "redirectUri": redirectURI
        ]

        let token: SoundCloudToken = try await postJSON(to: endpoint, body: body)
        try await setCachedToken(token)
        return token
    }

    public func refreshToken(_ refreshToken: String) async throws -> SoundCloudToken {
        let endpoint = config.tokenBrokerBaseURL.appending(path: "oauth/soundcloud/refresh")
        let body = ["refreshToken": refreshToken]

        let token: SoundCloudToken = try await postJSON(to: endpoint, body: body)
        try await setCachedToken(token)
        return token
    }

    public func fetchClientCredentialsToken() async throws -> SoundCloudToken {
        let endpoint = config.tokenBrokerBaseURL.appending(path: "oauth/soundcloud/client-credentials")
        let token: SoundCloudToken = try await postJSON(to: endpoint, body: [String: String]())
        try await setCachedToken(token)
        return token
    }

    public func cachedToken() async -> SoundCloudToken? {
        if let inMemoryToken {
            return inMemoryToken
        }

        guard let data = try? keychain.load(account: Storage.tokenAccount),
              let token = try? JSONDecoder().decode(SoundCloudToken.self, from: data) else {
            return nil
        }

        inMemoryToken = token
        return token
    }

    public func setCachedToken(_ token: SoundCloudToken) async throws {
        inMemoryToken = token
        let data = try JSONEncoder().encode(token)
        try keychain.save(data: data, account: Storage.tokenAccount)
    }

    public func clearCachedToken() async throws {
        inMemoryToken = nil
        keychain.delete(account: Storage.tokenAccount)
    }

    private func postJSON<T: Decodable, Body: Encodable>(to url: URL, body: Body) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let response = try await httpClient.send(request)
        do {
            return try JSONDecoder().decode(T.self, from: response.data)
        } catch {
            throw CloudScrobbleError.invalidResponse
        }
    }
}

public actor SoundCloudTokenProvider: AccessTokenProviding {
    private let authService: SoundCloudAuthProviding

    public init(authService: SoundCloudAuthProviding) {
        self.authService = authService
    }

    public func validAccessToken() async throws -> String {
        guard var token = await authService.cachedToken() else {
            throw CloudScrobbleError.missingToken
        }

        if token.isExpired(), let refreshToken = token.refreshToken {
            token = try await authService.refreshToken(refreshToken)
        }

        return token.accessToken
    }
}
