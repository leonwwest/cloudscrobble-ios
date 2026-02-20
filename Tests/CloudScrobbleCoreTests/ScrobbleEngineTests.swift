import XCTest
@testable import CloudScrobbleCore

final class ScrobbleEngineTests: XCTestCase {
    func testSendsNowPlayingImmediately() {
        let engine = ScrobbleEngine()
        let events = engine.start(track: makeQueueItem(duration: 200))

        guard case .sendNowPlaying = events.first else {
            XCTFail("Expected now playing event")
            return
        }
    }

    func testScrobblesAfterThreshold() {
        let engine = ScrobbleEngine()
        _ = engine.start(track: makeQueueItem(duration: 300), startedAt: Date(timeIntervalSince1970: 1_700_000_000))

        var events: [ScrobbleEngineEvent] = []
        for t in stride(from: 0.0, through: 150.0, by: 1.0) {
            events.append(contentsOf: engine.tick(playbackTime: t))
        }

        XCTAssertTrue(events.contains(where: {
            if case .sendScrobble = $0 { return true }
            return false
        }))
    }

    func testSeekDoesNotInstantlyScrobble() {
        let engine = ScrobbleEngine()
        _ = engine.start(track: makeQueueItem(duration: 300), startedAt: Date(timeIntervalSince1970: 1_700_000_000))

        _ = engine.tick(playbackTime: 1)
        let events = engine.tick(playbackTime: 200)

        XCTAssertTrue(events.isEmpty)
    }

    private func makeQueueItem(duration: Int) -> QueueItem {
        QueueItem(
            trackURN: "soundcloud:tracks:1",
            title: "Track",
            artistDisplay: "Artist",
            artworkURL: nil,
            permalinkURL: nil,
            streamURL: URL(string: "https://example.com/stream.m3u8")!,
            durationSeconds: duration,
            lastFM: LastFMTrackMeta(artist: "Artist", track: "Track")
        )
    }
}
