import Foundation
import XCTest
@testable import CloudScrobbleCore

final class LastFMLiveIntegrationTests: XCTestCase {
    func testLiveMobileSessionNowPlayingAndScrobble() async throws {
        let env = ProcessInfo.processInfo.environment

        guard env["LASTFM_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set LASTFM_LIVE_TESTS=1 to run live Last.fm integration test.")
        }

        guard let apiKey = env["LASTFM_API_KEY"], !apiKey.isEmpty,
              let apiSecret = env["LASTFM_API_SECRET"], !apiSecret.isEmpty,
              let username = env["LASTFM_TEST_USERNAME"], !username.isEmpty,
              let password = env["LASTFM_TEST_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("Missing LASTFM_API_KEY / LASTFM_API_SECRET / LASTFM_TEST_USERNAME / LASTFM_TEST_PASSWORD.")
        }

        let keychain = KeychainStore(service: "com.cloudscrobble.tests.lastfm.live.\(UUID().uuidString)")
        let config = LastFMConfiguration(apiKey: apiKey, apiSecret: apiSecret)
        let authService = LastFMAuthService(config: config, keychain: keychain)
        let scrobbleService = LastFMScrobbleService(
            config: config,
            authService: authService,
            queueStore: UserDefaultsScrobbleQueueStore(defaults: .standard, key: "cloudscrobble.tests.lastfm.live.\(UUID().uuidString)")
        )

        let session = try await authService.authenticate(username: username, password: password)
        XCTAssertFalse(session.key.isEmpty)

        try await scrobbleService.updateNowPlaying(
            meta: LastFMTrackMeta(artist: "CloudScrobble Live Test Artist", track: "NowPlaying Validation"),
            durationSeconds: 180
        )

        try await scrobbleService.scrobble(
            meta: LastFMTrackMeta(artist: "CloudScrobble Live Test Artist", track: "Scrobble Validation"),
            timestamp: Int(Date().timeIntervalSince1970) - 120
        )

        let pendingCount = await scrobbleService.pendingScrobbleCount()
        XCTAssertEqual(pendingCount, 0)
    }
}
