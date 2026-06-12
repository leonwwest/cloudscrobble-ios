import XCTest
@testable import CloudScrobbleCore

final class SoundCloudAuthServiceTests: XCTestCase {
    func testAuthorizationURLUsesPKCEAndStateWithoutPopupDisplay() async throws {
        let service = SoundCloudAuthService(
            config: SoundCloudAuthConfiguration(
                clientID: "client123",
                tokenBrokerBaseURL: URL(string: "http://localhost:8787")!
            ),
            keychain: KeychainStore(service: "CloudScrobbleCoreTests.SoundCloudAuthServiceTests")
        )

        let url = try await service.makeAuthorizationURL(
            codeChallenge: "challenge",
            state: "state123",
            redirectURI: "cloudscrobble://oauth"
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "secure.soundcloud.com")
        XCTAssertEqual(components.path, "/authorize")
        XCTAssertEqual(items["client_id"], "client123")
        XCTAssertEqual(items["redirect_uri"], "cloudscrobble://oauth")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["code_challenge"], "challenge")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "state123")
        XCTAssertFalse(items.keys.contains("display"))
    }

    func testTokenProviderRefreshesExpiredOAuthToken() async throws {
        let service = MockSoundCloudAuthProvider(
            cachedToken: SoundCloudToken(
                accessToken: "expired-oauth",
                refreshToken: "refresh-token",
                tokenType: "Bearer",
                scope: nil,
                expiresAt: Date(timeIntervalSinceNow: -60)
            ),
            refreshedToken: SoundCloudToken(
                accessToken: "fresh-oauth",
                refreshToken: "refresh-token-2",
                tokenType: "Bearer",
                scope: nil,
                expiresAt: Date(timeIntervalSinceNow: 3_600)
            ),
            clientCredentialsToken: nil
        )

        let token = try await SoundCloudTokenProvider(authService: service).validAccessToken()
        let refreshCallCount = await service.refreshCallCount
        let clientCredentialsCallCount = await service.clientCredentialsCallCount

        XCTAssertEqual(token, "fresh-oauth")
        XCTAssertEqual(refreshCallCount, 1)
        XCTAssertEqual(clientCredentialsCallCount, 0)
    }

    func testTokenProviderReissuesExpiredPublicModeToken() async throws {
        let service = MockSoundCloudAuthProvider(
            cachedToken: SoundCloudToken(
                accessToken: "expired-public",
                refreshToken: nil,
                tokenType: "Bearer",
                scope: nil,
                expiresAt: Date(timeIntervalSinceNow: -60)
            ),
            refreshedToken: nil,
            clientCredentialsToken: SoundCloudToken(
                accessToken: "fresh-public",
                refreshToken: nil,
                tokenType: "Bearer",
                scope: nil,
                expiresAt: Date(timeIntervalSinceNow: 3_600)
            )
        )

        let token = try await SoundCloudTokenProvider(authService: service).validAccessToken()
        let refreshCallCount = await service.refreshCallCount
        let clientCredentialsCallCount = await service.clientCredentialsCallCount

        XCTAssertEqual(token, "fresh-public")
        XCTAssertEqual(refreshCallCount, 0)
        XCTAssertEqual(clientCredentialsCallCount, 1)
    }
}

private actor MockSoundCloudAuthProvider: SoundCloudAuthProviding {
    private var token: SoundCloudToken?
    private let refreshedToken: SoundCloudToken?
    private let clientCredentialsToken: SoundCloudToken?

    private(set) var refreshCallCount = 0
    private(set) var clientCredentialsCallCount = 0

    init(
        cachedToken: SoundCloudToken?,
        refreshedToken: SoundCloudToken?,
        clientCredentialsToken: SoundCloudToken?
    ) {
        token = cachedToken
        self.refreshedToken = refreshedToken
        self.clientCredentialsToken = clientCredentialsToken
    }

    func makeAuthorizationURL(codeChallenge: String, state: String, redirectURI: String) async throws -> URL {
        URL(string: "https://secure.soundcloud.com/authorize")!
    }

    func exchangeAuthorizationCode(_ code: String, codeVerifier: String, redirectURI: String) async throws -> SoundCloudToken {
        throw CloudScrobbleError.invalidResponse
    }

    func refreshToken(_ refreshToken: String) async throws -> SoundCloudToken {
        refreshCallCount += 1
        guard let refreshedToken else {
            throw CloudScrobbleError.missingToken
        }
        token = refreshedToken
        return refreshedToken
    }

    func fetchClientCredentialsToken() async throws -> SoundCloudToken {
        clientCredentialsCallCount += 1
        guard let clientCredentialsToken else {
            throw CloudScrobbleError.missingToken
        }
        token = clientCredentialsToken
        return clientCredentialsToken
    }

    func cachedToken() async -> SoundCloudToken? {
        token
    }

    func setCachedToken(_ token: SoundCloudToken) async throws {
        self.token = token
    }

    func clearCachedToken() async throws {
        token = nil
    }
}
