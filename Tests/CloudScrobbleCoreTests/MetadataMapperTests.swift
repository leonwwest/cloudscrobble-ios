import XCTest
@testable import CloudScrobbleCore

final class MetadataMapperTests: XCTestCase {
    func testUsesPublisherMetadataWhenAvailable() {
        let user = SCUser(urn: "soundcloud:users:1", username: "uploader", permalink: nil, permalinkURL: nil, avatarURL: nil)
        let track = SCTrack(
            urn: "soundcloud:tracks:1",
            title: "ignored title",
            durationMs: 180_000,
            artworkURL: nil,
            permalinkURL: nil,
            user: user,
            publisherMetadata: SCPublisherMetadata(artist: "Artist", releaseTitle: "Song"),
            access: nil
        )

        let mapped = MetadataMapper.mapLastFM(track: track)
        XCTAssertEqual(mapped.artist, "Artist")
        XCTAssertEqual(mapped.track, "Song")
    }

    func testFallsBackToArtistDashTitlePattern() {
        let user = SCUser(urn: "soundcloud:users:1", username: "uploader", permalink: nil, permalinkURL: nil, avatarURL: nil)
        let track = SCTrack(
            urn: "soundcloud:tracks:1",
            title: "Daft Punk - One More Time",
            durationMs: 180_000,
            artworkURL: nil,
            permalinkURL: nil,
            user: user,
            publisherMetadata: nil,
            access: nil
        )

        let mapped = MetadataMapper.mapLastFM(track: track)
        XCTAssertEqual(mapped.artist, "Daft Punk")
        XCTAssertEqual(mapped.track, "One More Time")
    }

    func testDashTitleOverridesThirdPartyUploader() {
        let user = SCUser(urn: "soundcloud:users:1", username: "third-party-repost", permalink: nil, permalinkURL: nil, avatarURL: nil)
        let track = SCTrack(
            urn: "soundcloud:tracks:1",
            title: "Pintsored - Pine Squad",
            durationMs: 180_000,
            artworkURL: nil,
            permalinkURL: nil,
            user: user,
            publisherMetadata: nil,
            access: nil
        )

        let mapped = MetadataMapper.mapLastFM(track: track)
        XCTAssertEqual(mapped.artist, "Pintsored")
        XCTAssertEqual(mapped.track, "Pine Squad")
    }

    func testUsesPublisherArtistWhenReleaseTitleIsMissing() {
        let user = SCUser(urn: "soundcloud:users:1", username: "uploader", permalink: nil, permalinkURL: nil, avatarURL: nil)
        let track = SCTrack(
            urn: "soundcloud:tracks:1",
            title: "Loose Track Title",
            durationMs: 180_000,
            artworkURL: nil,
            permalinkURL: nil,
            user: user,
            publisherMetadata: SCPublisherMetadata(artist: "Known Artist", releaseTitle: nil),
            access: nil
        )

        let mapped = MetadataMapper.mapLastFM(track: track)
        XCTAssertEqual(mapped.artist, "Known Artist")
        XCTAssertEqual(mapped.track, "Loose Track Title")
    }

    func testSplitsOnlyOnFirstDashSeparator() {
        let user = SCUser(urn: "soundcloud:users:1", username: "uploader", permalink: nil, permalinkURL: nil, avatarURL: nil)
        let track = SCTrack(
            urn: "soundcloud:tracks:1",
            title: "Artist - Track - Remix",
            durationMs: 180_000,
            artworkURL: nil,
            permalinkURL: nil,
            user: user,
            publisherMetadata: nil,
            access: nil
        )

        let mapped = MetadataMapper.mapLastFM(track: track)
        XCTAssertEqual(mapped.artist, "Artist")
        XCTAssertEqual(mapped.track, "Track - Remix")
    }
}
