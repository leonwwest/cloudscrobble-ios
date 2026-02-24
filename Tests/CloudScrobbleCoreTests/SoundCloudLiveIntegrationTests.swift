import Foundation
import XCTest
@testable import CloudScrobbleCore

final class SoundCloudLiveIntegrationTests: XCTestCase {
    func testLiveClientCredentialsAndPublicSearch() async throws {
        let env = ProcessInfo.processInfo.environment

        guard env["SOUNDCLOUD_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set SOUNDCLOUD_LIVE_TESTS=1 to run live SoundCloud integration test.")
        }

        guard let clientID = env["SOUNDCLOUD_CLIENT_ID"], !clientID.isEmpty,
              let brokerURLRaw = env["SOUNDCLOUD_TOKEN_BROKER_BASE_URL"], !brokerURLRaw.isEmpty,
              let brokerURL = URL(string: brokerURLRaw) else {
            throw XCTSkip("Missing SOUNDCLOUD_CLIENT_ID / SOUNDCLOUD_TOKEN_BROKER_BASE_URL.")
        }

        let keychain = KeychainStore(service: "com.cloudscrobble.tests.soundcloud.live.\(UUID().uuidString)")
        let authService = SoundCloudAuthService(
            config: SoundCloudAuthConfiguration(
                clientID: clientID,
                tokenBrokerBaseURL: brokerURL
            ),
            keychain: keychain
        )

        let token = try await authService.fetchClientCredentialsToken()
        XCTAssertFalse(token.accessToken.isEmpty)

        let apiClient = SoundCloudAPIClient(tokenProvider: SoundCloudTokenProvider(authService: authService))
        let query = env["SOUNDCLOUD_LIVE_QUERY"] ?? "lofi"
        let results = try await apiClient.searchTracks(query: query, limit: 5)

        if results.collection.isEmpty {
            throw XCTSkip("SoundCloud returned no public tracks for query '\(query)'.")
        }

        XCTAssertTrue(results.collection[0].urn.hasPrefix("soundcloud:tracks:"))
    }
}
