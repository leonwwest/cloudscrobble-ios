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

    func testPlaylistTracksAreAvailableWithoutDemoAudioStream() async throws {
        let api = MockSoundCloudAPIClient()
        let playlists = try await api.searchPlaylists(query: "Demo", limit: 10, nextHref: nil).collection
        let playlist = try XCTUnwrap(playlists.first)

        let tracksPage = try await api.playlistTracks(urn: playlist.urn, limit: 20, nextHref: nil)
        let firstTrack = try XCTUnwrap(tracksPage.collection.first)
        let streams = try await api.streams(trackURN: firstTrack.urn)

        XCTAssertNil(streams.hlsAac160URL)
        XCTAssertNil(streams.hlsAac96URL)
        XCTAssertNil(streams.hlsMP3128URL)
        XCTAssertNil(streams.httpMP3128URL)
    }

    func testPersonalLibraryCollectionsArePlayable() async throws {
        let api = MockSoundCloudAPIClient()

        let me = try await api.me()
        let feedTracks = try await api.homeFeedTracks(limit: 10, nextHref: nil).collection.compactMap(\.track)
        let feedCollections = try await api.homeFeed(limit: 10, nextHref: nil).collection
        let followingTracks = try await api.myFollowingTracks(limit: 10, nextHref: nil).collection
        let playlists = try await api.myPlaylists(limit: 10, nextHref: nil).collection
        let likedTracks = try await api.myLikedTracks(limit: 10, nextHref: nil).collection
        let likedPlaylists = try await api.myLikedPlaylists(limit: 10, nextHref: nil).collection

        let playlist = try XCTUnwrap(playlists.first)
        let playlistTracks = try await api.playlistTracks(urn: playlist.urn, limit: 20, nextHref: nil).collection
        let firstTrack = try XCTUnwrap(playlistTracks.first)
        let relatedTracks = try await api.relatedTracks(trackURN: firstTrack.urn, limit: 20, nextHref: nil).collection
        let streams = try await api.streams(trackURN: firstTrack.urn)

        XCTAssertEqual(me.username, "CloudScrobble Demo")
        XCTAssertFalse(feedTracks.isEmpty)
        XCTAssertTrue(feedCollections.contains { $0.playlist != nil })
        XCTAssertFalse(followingTracks.isEmpty)
        XCTAssertFalse(playlists.isEmpty)
        XCTAssertFalse(likedTracks.isEmpty)
        XCTAssertFalse(likedPlaylists.isEmpty)
        XCTAssertFalse(relatedTracks.isEmpty)
        XCTAssertEqual(playlist.user.urn, me.urn)
        XCTAssertNil(streams.hlsAac160URL)
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

    func testPlaybackResolverCachesResolvedStreams() async throws {
        let hlsURL = URL(string: "https://api.soundcloud.com/tracks/soundcloud:tracks:1/streams/stream-id/hls")!
        let api = StreamFixtureAPI(
            streams: SCStreams(hlsMP3128URL: hlsURL),
            headers: ["Authorization": "OAuth test-token"]
        )
        let resolver = PlaybackResolver(api: api)

        _ = try await resolver.resolvePlayableStream(for: "soundcloud:tracks:1")
        _ = try await resolver.resolvePlayableStream(for: "soundcloud:tracks:1")

        let count = await api.streamCallCount()
        XCTAssertEqual(count, 1)
    }

    func testPlaybackResolverPrefetchesUpcomingUncachedStreams() async throws {
        let hlsURL = URL(string: "https://api.soundcloud.com/tracks/soundcloud:tracks:1/streams/stream-id/hls")!
        let api = StreamFixtureAPI(
            streams: SCStreams(hlsMP3128URL: hlsURL),
            headers: ["Authorization": "OAuth test-token"]
        )
        let resolver = PlaybackResolver(api: api)

        await resolver.prefetchPlayableStreams(for: [
            "soundcloud:tracks:1",
            "soundcloud:tracks:2",
            "soundcloud:tracks:3",
            "soundcloud:tracks:4",
            "soundcloud:tracks:5"
        ])
        _ = try await resolver.resolvePlayableStream(for: "soundcloud:tracks:1")

        let count = await api.streamCallCount()
        XCTAssertEqual(count, 4)
    }
}

private actor StreamFixtureAPI: SoundCloudAPIClienting {
    let fixtureStreams: SCStreams
    let headers: [String: String]
    private var streamsCallCount = 0

    init(streams: SCStreams, headers: [String: String]) {
        self.fixtureStreams = streams
        self.headers = headers
    }

    func streams(trackURN: String) async throws -> SCStreams {
        streamsCallCount += 1
        return fixtureStreams
    }
    func streamRequestHeaders() async throws -> [String: String] { headers }
    func legacyStreamURL(trackURN: String) async throws -> URL { throw unused() }
    func streamCallCount() -> Int { streamsCallCount }

    func me() async throws -> SCUser { throw unused() }
    func homeFeed(limit: Int, nextHref: URL?) async throws -> SCPage<SCActivity> { throw unused() }
    func homeFeedTracks(limit: Int, nextHref: URL?) async throws -> SCPage<SCActivity> { throw unused() }
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
    func myFollowingTracks(limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack> { throw unused() }
    func playlist(urn: String, showTracks: Bool) async throws -> SCPlaylist { throw unused() }
    func playlistTracks(urn: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack> { throw unused() }
    func track(urn: String) async throws -> SCTrack { throw unused() }
    func relatedTracks(trackURN: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack> { throw unused() }

    private func unused() -> CloudScrobbleError {
        .invalidConfiguration("Unused test fixture endpoint")
    }
}
