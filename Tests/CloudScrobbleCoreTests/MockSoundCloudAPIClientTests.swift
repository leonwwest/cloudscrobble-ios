import XCTest
@testable import CloudScrobbleCore

final class MockSoundCloudAPIClientTests: XCTestCase {
    func testSearchTracksReturnsDemoResults() async throws {
        let api = MockSoundCloudAPIClient()
        let page = try await api.searchTracks(query: "Aurora", limit: 10, nextHref: nil)

        XCTAssertFalse(page.collection.isEmpty)
        XCTAssertTrue(page.collection.contains { $0.title.contains("Aurora") })
        XCTAssertNil(page.nextHref)
    }

    func testPlaylistTracksAndStreamsAreAvailable() async throws {
        let api = MockSoundCloudAPIClient()
        let playlists = try await api.searchPlaylists(query: "Demo", limit: 10, nextHref: nil).collection
        let playlist = try XCTUnwrap(playlists.first)

        let tracksPage = try await api.playlistTracks(urn: playlist.urn, limit: 20, nextHref: nil)
        let firstTrack = try XCTUnwrap(tracksPage.collection.first)
        let streams = try await api.streams(trackURN: firstTrack.urn)

        XCTAssertEqual(streams.hlsAac160URL, MockSoundCloudAPIClient.demoStreamURL)
        XCTAssertNil(streams.hlsAac96URL)
    }

    func testPersonalLibraryCollectionsArePlayable() async throws {
        let api = MockSoundCloudAPIClient()

        let me = try await api.me()
        let playlists = try await api.myPlaylists(limit: 10, nextHref: nil).collection
        let likedTracks = try await api.myLikedTracks(limit: 10, nextHref: nil).collection
        let likedPlaylists = try await api.myLikedPlaylists(limit: 10, nextHref: nil).collection

        let playlist = try XCTUnwrap(playlists.first)
        let playlistTracks = try await api.playlistTracks(urn: playlist.urn, limit: 20, nextHref: nil).collection
        let firstTrack = try XCTUnwrap(playlistTracks.first)
        let stream = try await api.streams(trackURN: firstTrack.urn)

        XCTAssertEqual(me.username, "CloudScrobble Demo")
        XCTAssertFalse(playlists.isEmpty)
        XCTAssertFalse(likedTracks.isEmpty)
        XCTAssertFalse(likedPlaylists.isEmpty)
        XCTAssertEqual(playlist.user.urn, me.urn)
        XCTAssertNotNil(stream.hlsAac160URL)
    }

    func testPlaybackResolverUsesCurrentSoundCloudMP3HLSStreamFields() async throws {
        let hlsURL = URL(string: "https://api.soundcloud.com/tracks/soundcloud:tracks:1/streams/stream-id/hls")!
        let api = StreamFixtureAPI(
            streams: SCStreams(hlsMP3128URL: hlsURL),
            headers: ["Authorization": "OAuth test-token"]
        )
        let resolver = PlaybackResolver(api: api)

        let stream = try await resolver.resolvePlayableStream(for: "soundcloud:tracks:1")

        XCTAssertEqual(stream.url, hlsURL)
        XCTAssertEqual(stream.headers["Authorization"], "OAuth test-token")
    }
}

private actor StreamFixtureAPI: SoundCloudAPIClienting {
    let fixtureStreams: SCStreams
    let headers: [String: String]

    init(streams: SCStreams, headers: [String: String]) {
        self.fixtureStreams = streams
        self.headers = headers
    }

    func streams(trackURN: String) async throws -> SCStreams { fixtureStreams }
    func streamRequestHeaders() async throws -> [String: String] { headers }
    func legacyStreamURL(trackURN: String) async throws -> URL { throw unused() }

    func me() async throws -> SCUser { throw unused() }
    func searchTracks(query: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack> { throw unused() }
    func searchPlaylists(query: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCPlaylist> { throw unused() }
    func searchUsers(query: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCUser> { throw unused() }
    func user(urn: String) async throws -> SCUser { throw unused() }
    func userTracks(urn: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack> { throw unused() }
    func userPlaylists(urn: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCPlaylist> { throw unused() }
    func userLikesTracks(urn: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack> { throw unused() }
    func userLikesPlaylists(urn: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCPlaylist> { throw unused() }
    func myPlaylists(limit: Int, nextHref: URL?) async throws -> SCPage<SCPlaylist> { throw unused() }
    func myLikedTracks(limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack> { throw unused() }
    func myLikedPlaylists(limit: Int, nextHref: URL?) async throws -> SCPage<SCPlaylist> { throw unused() }
    func playlist(urn: String, showTracks: Bool) async throws -> SCPlaylist { throw unused() }
    func playlistTracks(urn: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack> { throw unused() }
    func track(urn: String) async throws -> SCTrack { throw unused() }

    private func unused() -> CloudScrobbleError {
        .invalidConfiguration("Unused test fixture endpoint")
    }
}
