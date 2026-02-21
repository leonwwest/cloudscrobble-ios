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
}
