import XCTest
@testable import CloudScrobbleCore

@MainActor
final class PlayerScrobbleControllerTests: XCTestCase {
    func testQueueEditingAndRecentlyPlayedState() {
        let controller = PlayerScrobbleController(lastFMScrobbler: nil)
        controller.clearRecentlyPlayed()

        let first = makeQueueItem(id: "first")
        let second = makeQueueItem(id: "second")
        let third = makeQueueItem(id: "third")
        let fourth = makeQueueItem(id: "fourth")

        controller.loadQueue([first, second], startAt: 0)

        XCTAssertEqual(controller.currentItem?.trackURN, first.trackURN)
        XCTAssertEqual(controller.recentlyPlayed.first?.trackURN, first.trackURN)

        controller.playNext(third)
        XCTAssertEqual(controller.queue.map(\.trackURN), [
            first.trackURN,
            third.trackURN,
            second.trackURN
        ])

        controller.appendToQueue(fourth)
        XCTAssertEqual(controller.queue.last?.trackURN, fourth.trackURN)

        controller.moveQueueItem(from: 3, to: 1)
        XCTAssertEqual(controller.queue.map(\.trackURN), [
            first.trackURN,
            fourth.trackURN,
            third.trackURN,
            second.trackURN
        ])

        controller.removeQueueItem(at: 2)
        XCTAssertEqual(controller.queue.map(\.trackURN), [
            first.trackURN,
            fourth.trackURN,
            second.trackURN
        ])

        controller.clearQueue()
        XCTAssertTrue(controller.queue.isEmpty)
        XCTAssertNil(controller.currentItem)
    }

    func testLastFMDiagnosticsFlushPendingScrobbles() async {
        let scrobbler = DiagnosticScrobbler(pendingCount: 2)
        let controller = PlayerScrobbleController(lastFMScrobbler: scrobbler)

        await controller.refreshLastFMDiagnostics()
        XCTAssertEqual(controller.pendingScrobbleCount, 2)

        await controller.flushPendingLastFMScrobbles()

        XCTAssertEqual(controller.pendingScrobbleCount, 0)
        XCTAssertNotNil(controller.lastScrobbleSucceededAt)
        XCTAssertNil(controller.lastScrobbleError)
    }

    func testTrackSwitchCancelsStaleNowPlayingUpdate() async {
        let scrobbler = DelayedNowPlayingScrobbler(delayNanoseconds: 150_000_000)
        let controller = PlayerScrobbleController(lastFMScrobbler: scrobbler)

        let first = makeQueueItem(id: "first")
        let second = makeQueueItem(id: "second")

        controller.loadQueue([first], startAt: 0)
        await Task.yield()
        controller.loadQueue([second], startAt: 0)

        try? await Task.sleep(nanoseconds: 400_000_000)

        let nowPlaying = await scrobbler.nowPlayingTracks()
        XCTAssertEqual(nowPlaying, [second.lastFM])
    }

    private func makeQueueItem(id: String) -> QueueItem {
        QueueItem(
            trackURN: "soundcloud:tracks:test:\(id)",
            title: id.capitalized,
            artistDisplay: "Test Artist",
            artworkURL: nil,
            permalinkURL: URL(string: "https://soundcloud.com/test/\(id)")!,
            streamURL: URL(string: "https://example.com/\(id).m3u8")!,
            durationSeconds: 180,
            lastFM: LastFMTrackMeta(artist: "Test Artist", track: id.capitalized)
        )
    }
}

private actor DiagnosticScrobbler: LastFMScrobbleSending {
    private var pendingCountValue: Int

    init(pendingCount: Int) {
        self.pendingCountValue = pendingCount
    }

    func updateNowPlaying(meta: LastFMTrackMeta, durationSeconds: Int?) async throws {}

    func scrobble(meta: LastFMTrackMeta, timestamp: Int) async throws {
        pendingCountValue += 1
    }

    func flushPendingScrobbles() async throws {
        pendingCountValue = 0
    }

    func pendingScrobbleCount() async -> Int {
        pendingCountValue
    }
}

private actor DelayedNowPlayingScrobbler: LastFMScrobbleSending {
    private let delayNanoseconds: UInt64
    private var nowPlayingValues: [LastFMTrackMeta] = []

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func updateNowPlaying(meta: LastFMTrackMeta, durationSeconds: Int?) async throws {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        nowPlayingValues.append(meta)
    }

    func scrobble(meta: LastFMTrackMeta, timestamp: Int) async throws {}

    func flushPendingScrobbles() async throws {}

    func pendingScrobbleCount() async -> Int {
        0
    }

    func nowPlayingTracks() -> [LastFMTrackMeta] {
        nowPlayingValues
    }
}
