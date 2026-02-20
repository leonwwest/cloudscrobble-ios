import Foundation

public struct LastFMConfiguration: Sendable {
    public let apiKey: String
    public let apiSecret: String
    public let endpoint: URL

    public init(apiKey: String, apiSecret: String, endpoint: URL = URL(string: "https://ws.audioscrobbler.com/2.0/")!) {
        self.apiKey = apiKey
        self.apiSecret = apiSecret
        self.endpoint = endpoint
    }
}

private struct LastFMSessionResponse: Decodable {
    let session: LastFMSession
}

private struct LastFMErrorResponse: Decodable {
    let error: Int
    let message: String
}

public actor LastFMAuthService: LastFMAuthenticating {
    private enum Storage {
        static let sessionAccount = "lastfm.session"
    }

    private let config: LastFMConfiguration
    private let httpClient: HTTPClient
    private let keychain: KeychainStore
    private var inMemorySession: LastFMSession?

    public init(config: LastFMConfiguration, keychain: KeychainStore, httpClient: HTTPClient = HTTPClient()) {
        self.config = config
        self.keychain = keychain
        self.httpClient = httpClient
    }

    public func authenticate(username: String, password: String) async throws -> LastFMSession {
        var params = [
            "method": "auth.getMobileSession",
            "username": username,
            "password": password,
            "api_key": config.apiKey
        ]
        params["api_sig"] = LastFMSignature.sign(parameters: params, apiSecret: config.apiSecret)

        let responseData = try await performPOST(params: params)

        if let errorPayload = try? JSONDecoder().decode(LastFMErrorResponse.self, from: responseData) {
            throw CloudScrobbleError.lastFMError(code: errorPayload.error, message: errorPayload.message)
        }

        let payload = try JSONDecoder().decode(LastFMSessionResponse.self, from: responseData)
        try await setCachedSession(payload.session)
        return payload.session
    }

    public func cachedSession() async -> LastFMSession? {
        if let inMemorySession {
            return inMemorySession
        }

        guard let data = try? keychain.load(account: Storage.sessionAccount),
              let session = try? JSONDecoder().decode(LastFMSession.self, from: data) else {
            return nil
        }

        inMemorySession = session
        return session
    }

    public func setCachedSession(_ session: LastFMSession) async throws {
        inMemorySession = session
        let data = try JSONEncoder().encode(session)
        try keychain.save(data: data, account: Storage.sessionAccount)
    }

    public func clearSession() async throws {
        inMemorySession = nil
        keychain.delete(account: Storage.sessionAccount)
    }

    private func performPOST(params: [String: String]) async throws -> Data {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyParams = params
        bodyParams["format"] = "json"

        let body = bodyParams
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)"
            }
            .joined(separator: "&")

        request.httpBody = Data(body.utf8)

        let response = try await httpClient.send(request)
        return response.data
    }
}
