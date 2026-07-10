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

    func testVisibleArtistTitleOverridesMismatchedPublisherReleaseTitle() {
        let user = SCUser(urn: "soundcloud:users:1", username: "label", permalink: nil, permalinkURL: nil, avatarURL: nil)
        let track = SCTrack(
            urn: "soundcloud:tracks:1",
            title: "Artist - Actual Song",
            durationMs: 180_000,
            artworkURL: nil,
            permalinkURL: nil,
            user: user,
            publisherMetadata: SCPublisherMetadata(artist: "Artist", releaseTitle: "Wrong EP Title"),
            access: nil
        )

        let mapped = MetadataMapper.mapLastFM(track: track)

        XCTAssertEqual(mapped.artist, "Artist")
        XCTAssertEqual(mapped.track, "Actual Song")
    }

    func testPublisherReleaseTitleWinsWhenVisibleArtistDoesNotMatchPublisherArtist() {
        let user = SCUser(urn: "soundcloud:users:1", username: "label", permalink: nil, permalinkURL: nil, avatarURL: nil)
        let track = SCTrack(
            urn: "soundcloud:tracks:1",
            title: "Repost Channel - Teaser Clip",
            durationMs: 180_000,
            artworkURL: nil,
            permalinkURL: nil,
            user: user,
            publisherMetadata: SCPublisherMetadata(artist: "Actual Artist", releaseTitle: "Actual Song"),
            access: nil
        )

        let mapped = MetadataMapper.mapLastFM(track: track)

        XCTAssertEqual(mapped.artist, "Actual Artist")
        XCTAssertEqual(mapped.track, "Actual Song")
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

    func testTrackIdentityDeduplicatesSameSongAcrossDifferentUploaders() {
        let firstUploader = SCUser(urn: "soundcloud:users:1", username: "repost-channel", permalink: nil, permalinkURL: nil, avatarURL: nil)
        let secondUploader = SCUser(urn: "soundcloud:users:2", username: "another-channel", permalink: nil, permalinkURL: nil, avatarURL: nil)
        let first = SCTrack(
            urn: "soundcloud:tracks:1",
            title: "Uploader title should be ignored",
            durationMs: 180_000,
            artworkURL: nil,
            permalinkURL: URL(string: "https://soundcloud.com/repost/song")!,
            user: firstUploader,
            publisherMetadata: SCPublisherMetadata(artist: "Main Artist", releaseTitle: "Cloud Song"),
            access: nil
        )
        let second = SCTrack(
            urn: "soundcloud:tracks:2",
            title: "Main Artist - Cloud Song [FREE DOWNLOAD]",
            durationMs: 183_000,
            artworkURL: nil,
            permalinkURL: URL(string: "https://soundcloud.com/another/song")!,
            user: secondUploader,
            publisherMetadata: nil,
            access: nil
        )

        let unique = TrackIdentity.uniqueTracks([first, second])

        XCTAssertEqual(unique.map(\.urn), ["soundcloud:tracks:1"])
    }

    func testTrackIdentityDisplayMetadataUsesMainArtistInsteadOfUploader() {
        let user = SCUser(urn: "soundcloud:users:1", username: "third-party-uploader", permalink: nil, permalinkURL: nil, avatarURL: nil)
        let track = SCTrack(
            urn: "soundcloud:tracks:1",
            title: "ignored",
            durationMs: 180_000,
            artworkURL: nil,
            permalinkURL: nil,
            user: user,
            publisherMetadata: SCPublisherMetadata(artist: "Main Artist", releaseTitle: "Cloud Song"),
            access: nil
        )

        let metadata = TrackIdentity.displayMetadata(for: track)

        XCTAssertEqual(metadata.artist, "Main Artist")
        XCTAssertEqual(metadata.track, "Cloud Song")
    }
}
