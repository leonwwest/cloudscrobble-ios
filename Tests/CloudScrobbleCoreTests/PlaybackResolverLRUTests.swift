import XCTest
@testable import CloudScrobbleCore

final class PlaybackResolverLRUTests: XCTestCase {
    /// Minimal `SoundCloudAPIClienting` stub: only the three stream methods are
    /// meaningful; the rest throw. Counts `streams(trackURN:)` calls so the
    /// test can distinguish cache hits from misses.
    private final class StubPlaybackAPI: SoundCloudAPIClienting, @unchecked Sendable {
        var streamsCallCount = 0

        func streams(trackURN: String) async throws -> SCStreams {
            streamsCallCount += 1
            return SCStreams(hlsAac160URL: URL(string: "https://stream.example/\(trackURN).m3u8"))
        }

        func streamRequestHeaders() async throws -> [String: String] { [:] }

        func legacyStreamURL(trackURN: String) async throws -> URL {
            URL(string: "https://stream.example/legacy/\(trackURN).m3u8")!
        }

        // MARK: - Unused members (required for protocol conformance)
        func me() async throws -> SCUser { throw CloudScrobbleError.invalidConfiguration("unused") }
        func homeFeed(limit: Int, nextHref: URL?) async throws -> SCPage<SCActivity> { throw CloudScrobbleError.invalidConfiguration("unused") }
        func homeFeedTracks(limit: Int, nextHref: URL?) async throws -> SCPage<SCActivity> { throw CloudScrobbleError.invalidConfiguration("unused") }
        func searchTracks(query: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack> { throw CloudScrobbleError.invalidConfiguration("unused") }
        func searchPlaylists(query: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCPlaylist> { throw CloudScrobbleError.invalidConfiguration("unused") }
        func searchUsers(query: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCUser> { throw CloudScrobbleError.invalidConfiguration("unused") }
        func user(urn: String) async throws -> SCUser { throw CloudScrobbleError.invalidConfiguration("unused") }
        func userTracks(urn: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack> { throw CloudScrobbleError.invalidConfiguration("unused") }
        func userPlaylists(urn: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCPlaylist> { throw CloudScrobbleError.invalidConfiguration("unused") }
        func userLikesTracks(urn: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack> { throw CloudScrobbleError.invalidConfiguration("unused") }
        func userLikesPlaylists(urn: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCPlaylist> { throw CloudScrobbleError.invalidConfiguration("unused") }
        func myPlaylists(limit: Int, nextHref: URL?) async throws -> SCPage<SCPlaylist> { throw CloudScrobbleError.invalidConfiguration("unused") }
        func myLikedTracks(limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack> { throw CloudScrobbleError.invalidConfiguration("unused") }
        func myLikedPlaylists(limit: Int, nextHref: URL?) async throws -> SCPage<SCPlaylist> { throw CloudScrobbleError.invalidConfiguration("unused") }
        func myFollowingTracks(limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack> { throw CloudScrobbleError.invalidConfiguration("unused") }
        func playlist(urn: String, showTracks: Bool) async throws -> SCPlaylist { throw CloudScrobbleError.invalidConfiguration("unused") }
        func playlistTracks(urn: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack> { throw CloudScrobbleError.invalidConfiguration("unused") }
        func track(urn: String) async throws -> SCTrack { throw CloudScrobbleError.invalidConfiguration("unused") }
        func relatedTracks(trackURN: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack> { throw CloudScrobbleError.invalidConfiguration("unused") }
    }

    func testCacheHitAvoidsAPICall() async throws {
        let api = StubPlaybackAPI()
        let resolver = PlaybackResolver(api: api, maxCacheSize: 10)

        _ = try await resolver.resolvePlayableStream(for: "urn:1")
        XCTAssertEqual(api.streamsCallCount, 1)

        _ = try await resolver.resolvePlayableStream(for: "urn:1")
        XCTAssertEqual(api.streamsCallCount, 1, "Cache hit must not call the API")
    }

    func testLRUEvictsLeastRecentlyUsed() async throws {
        let api = StubPlaybackAPI()
        let resolver = PlaybackResolver(api: api, maxCacheSize: 3)

        _ = try await resolver.resolvePlayableStream(for: "urn:A")  // cache: [A]
        _ = try await resolver.resolvePlayableStream(for: "urn:B")  // cache: [A, B]
        _ = try await resolver.resolvePlayableStream(for: "urn:C")  // cache: [A, B, C]

        // Re-access A so B becomes the least-recently-used.
        _ = try await resolver.resolvePlayableStream(for: "urn:A")  // order: [B, C, A]
        XCTAssertEqual(api.streamsCallCount, 3)

        // Inserting D evicts B (LRU), not A or C.
        _ = try await resolver.resolvePlayableStream(for: "urn:D")  // cache: [C, A, D]
        XCTAssertEqual(api.streamsCallCount, 4)

        // A is still cached (no API call); B was evicted (API call).
        _ = try await resolver.resolvePlayableStream(for: "urn:A")
        XCTAssertEqual(api.streamsCallCount, 4, "A must survive because it was recently used")

        _ = try await resolver.resolvePlayableStream(for: "urn:B")
        XCTAssertEqual(api.streamsCallCount, 5, "B must have been evicted as the least-recently-used entry")
    }
}
