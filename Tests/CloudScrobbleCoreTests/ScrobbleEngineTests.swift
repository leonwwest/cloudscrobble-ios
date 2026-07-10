import XCTest
@testable import CloudScrobbleCore

@MainActor
final class ScrobbleEngineTests: XCTestCase {
    func testExcludedTrackDoesNotSendNowPlayingOrScrobble() {
        let engine = ScrobbleEngine()
        let track = makeQueueItem(duration: 180, scrobbleEnabled: false)

        XCTAssertTrue(engine.start(track: track).isEmpty)
        XCTAssertTrue(engine.tick(playbackTime: 90).isEmpty)
        XCTAssertFalse(engine.state.didSendNowPlaying)
        XCTAssertFalse(engine.state.didScrobble)
    }

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

    func testRestoreContinuesListeningProgress() {
        let track = makeQueueItem(duration: 300)
        let engine = ScrobbleEngine()
        _ = engine.start(track: track, startedAt: Date(timeIntervalSince1970: 1_700_000_000))

        var restoredState = engine.state
        restoredState.listenedSeconds = 149

        let restoredEngine = ScrobbleEngine()
        restoredEngine.restore(track: track, state: restoredState, playbackTime: 149, isPaused: false)

        let events = restoredEngine.tick(playbackTime: 151)

        XCTAssertTrue(events.contains(where: {
            if case .sendScrobble(trackURN: _, meta: _, timestamp: let timestamp) = $0 {
                return timestamp == 1_700_000_000
            }
            return false
        }))
    }

    func testFinishScrobblesWhenTrackEndsAfterLastTimerTick() {
        let engine = ScrobbleEngine()
        _ = engine.start(track: makeQueueItem(duration: 300), startedAt: Date(timeIntervalSince1970: 1_700_000_000))

        var events: [ScrobbleEngineEvent] = []
        for t in stride(from: 0.0, through: 149.0, by: 1.0) {
            events.append(contentsOf: engine.tick(playbackTime: t))
        }

        XCTAssertFalse(events.contains(where: {
            if case .sendScrobble = $0 { return true }
            return false
        }))

        let finishEvents = engine.finish(playbackTime: 300)

        XCTAssertTrue(finishEvents.contains(where: {
            if case .sendScrobble(trackURN: _, meta: _, timestamp: let timestamp) = $0 {
                return timestamp == 1_700_000_000
            }
            return false
        }))
    }

    func testFinishDoesNotTreatSeekToEndAsListenedTime() {
        let engine = ScrobbleEngine()
        _ = engine.start(track: makeQueueItem(duration: 300), startedAt: Date(timeIntervalSince1970: 1_700_000_000))

        _ = engine.tick(playbackTime: 1)
        let finishEvents = engine.finish(playbackTime: 300)

        XCTAssertTrue(finishEvents.isEmpty)
    }

    func testMetadataUpdatePreservesProgressAndCanDisableScrobbling() {
        let engine = ScrobbleEngine()
        let original = makeQueueItem(duration: 300)
        _ = engine.start(track: original, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        _ = engine.tick(playbackTime: 0)
        _ = engine.tick(playbackTime: 2)
        let listenedBeforeUpdate = engine.state.listenedSeconds

        let corrected = QueueItem(
            trackURN: original.trackURN,
            title: "Correct Track",
            artistDisplay: "Correct Artist",
            artworkURL: original.artworkURL,
            permalinkURL: original.permalinkURL,
            streamURL: original.streamURL,
            durationSeconds: original.durationSeconds,
            lastFM: LastFMTrackMeta(artist: "Correct Artist", track: "Correct Track")
        )
        let events = engine.updateTrack(corrected)

        XCTAssertEqual(engine.state.listenedSeconds, listenedBeforeUpdate)
        XCTAssertEqual(
            events,
            [.sendNowPlaying(
                trackURN: corrected.trackURN,
                meta: corrected.lastFM,
                duration: corrected.durationSeconds
            )]
        )

        let disabled = QueueItem(
            trackURN: corrected.trackURN,
            title: corrected.title,
            artistDisplay: corrected.artistDisplay,
            artworkURL: corrected.artworkURL,
            permalinkURL: corrected.permalinkURL,
            streamURL: corrected.streamURL,
            durationSeconds: corrected.durationSeconds,
            lastFM: corrected.lastFM,
            scrobbleEnabled: false
        )
        XCTAssertTrue(engine.updateTrack(disabled).isEmpty)
        XCTAssertEqual(engine.state.scrobbleThresholdSeconds, 0)
        XCTAssertTrue(engine.tick(playbackTime: 200).isEmpty)
        XCTAssertFalse(engine.state.didScrobble)
    }

    private func makeQueueItem(duration: Int, scrobbleEnabled: Bool = true) -> QueueItem {
        QueueItem(
            trackURN: "soundcloud:tracks:1",
            title: "Track",
            artistDisplay: "Artist",
            artworkURL: nil,
            permalinkURL: nil,
            streamURL: URL(string: "https://example.com/stream.m3u8")!,
            durationSeconds: duration,
            lastFM: LastFMTrackMeta(artist: "Artist", track: "Track"),
            scrobbleEnabled: scrobbleEnabled
        )
    }
}
