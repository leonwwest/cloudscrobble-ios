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

    func testBatchAppendKeepsOrderAndPublishesCompleteBatch() {
        let controller = PlayerScrobbleController(lastFMScrobbler: nil)
        let first = makeQueueItem(id: "first")
        let second = makeQueueItem(id: "second")
        let appended = [
            makeQueueItem(id: "third"),
            makeQueueItem(id: "fourth"),
            makeQueueItem(id: "fifth")
        ]

        controller.loadQueue([first, second], startAt: 0)
        controller.appendToQueue(appended, showDebug: false)

        XCTAssertEqual(
            controller.queue.map(\.trackURN),
            ([first, second] + appended).map(\.trackURN)
        )
        XCTAssertEqual(controller.currentItem?.trackURN, first.trackURN)
    }

    func testSleepTimerCanBeScheduledAndCancelled() {
        let controller = PlayerScrobbleController(lastFMScrobbler: nil)
        controller.loadQueue([makeQueueItem(id: "sleep")], startAt: 0)

        controller.startSleepTimer(minutes: 15)
        XCTAssertNotNil(controller.sleepTimerEndsAt)

        controller.cancelSleepTimer()
        XCTAssertNil(controller.sleepTimerEndsAt)
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

    func testScrobbleConfigurationUpdatesQueueWithoutRestartingPlayback() {
        let controller = PlayerScrobbleController(lastFMScrobbler: nil)
        let first = makeQueueItem(id: "first")
        let second = makeQueueItem(id: "second")
        let corrected = LastFMTrackMeta(artist: "Correct Artist", track: "Correct Track")

        controller.loadQueue([first, second], startAt: 0)
        controller.updateScrobbleConfiguration(
            trackURN: first.trackURN,
            metadata: corrected,
            isEnabled: false
        )

        XCTAssertEqual(controller.queue.count, 2)
        XCTAssertEqual(controller.currentIndex, 0)
        XCTAssertEqual(controller.currentItem?.lastFM, corrected)
        XCTAssertEqual(controller.currentItem?.title, corrected.track)
        XCTAssertFalse(controller.currentItem?.scrobbleEnabled ?? true)
        XCTAssertEqual(controller.queue[1], second)
    }

    func testScrobbleConfigurationUpdatesEveryDuplicateURN() {
        let controller = PlayerScrobbleController(lastFMScrobbler: nil)
        let repeated = makeQueueItem(id: "repeated")
        let corrected = LastFMTrackMeta(artist: "Correct Artist", track: "Correct Track")

        controller.loadQueue([repeated, repeated], startAt: 1)
        controller.updateScrobbleConfiguration(
            trackURN: repeated.trackURN,
            metadata: corrected,
            isEnabled: false
        )

        XCTAssertEqual(controller.queue.count, 2)
        XCTAssertTrue(controller.queue.allSatisfy { $0.lastFM == corrected })
        XCTAssertTrue(controller.queue.allSatisfy { !$0.scrobbleEnabled })
        XCTAssertEqual(controller.currentIndex, 1)
        XCTAssertEqual(controller.currentItem?.lastFM, corrected)
    }

    func testScrobbleConfigurationUpdatesRecentlyPlayedWithoutQueueMatch() {
        let controller = PlayerScrobbleController(lastFMScrobbler: nil)
        controller.clearRecentlyPlayed()
        let played = makeQueueItem(id: "played")
        let corrected = LastFMTrackMeta(artist: "Correct Artist", track: "Correct Track")

        controller.loadQueue([played], startAt: 0)
        controller.clearQueue()
        controller.updateScrobbleConfiguration(
            trackURN: played.trackURN,
            metadata: corrected,
            isEnabled: true
        )

        XCTAssertTrue(controller.queue.isEmpty)
        XCTAssertEqual(controller.recentlyPlayed.first?.lastFM, corrected)
        XCTAssertEqual(controller.recentlyPlayed.first?.title, corrected.track)
    }

    func testDuplicateURNsSurviveShuffleMoveAndSingleRemoval() {
        let controller = PlayerScrobbleController(lastFMScrobbler: nil)
        let repeated = makeQueueItem(id: "repeated")
        let other = makeQueueItem(id: "other")

        controller.loadQueue([repeated, repeated, other], startAt: 1)
        controller.toggleShuffle()
        XCTAssertEqual(controller.queue.count, 3)
        XCTAssertEqual(controller.queue.filter { $0.trackURN == repeated.trackURN }.count, 2)

        controller.toggleShuffle()
        controller.moveQueueItem(from: 1, to: 2)
        XCTAssertEqual(controller.currentIndex, 0)

        controller.removeQueueItem(at: 2)
        XCTAssertEqual(controller.queue.count, 2)
        XCTAssertEqual(controller.queue.filter { $0.trackURN == repeated.trackURN }.count, 1)
    }

    func testRestoredPrefixPreservesOriginalOrderAndPreviousTrack() {
        let controller = PlayerScrobbleController(lastFMScrobbler: nil)
        let first = makeQueueItem(id: "first")
        let second = makeQueueItem(id: "second")
        let current = makeQueueItem(id: "current")
        let next = makeQueueItem(id: "next")
        let snapshot = SavedPlaybackSnapshot(
            queue: [current, next].map(SavedPlaybackTrack.init(queueItem:)),
            currentIndex: 0,
            elapsedSeconds: 42,
            scrobbleState: ScrobbleState(),
            repeatModeRawValue: PlaybackRepeatMode.off.rawValue,
            isShuffleEnabled: false
        )
        let recoverySnapshot = SavedPlaybackSnapshot(
            queue: [first, second, current, next].map(SavedPlaybackTrack.init(queueItem:)),
            currentIndex: 2,
            elapsedSeconds: 42,
            scrobbleState: ScrobbleState(),
            repeatModeRawValue: PlaybackRepeatMode.off.rawValue,
            isShuffleEnabled: false
        )

        controller.restoreSavedQueue(
            [current, next],
            from: snapshot,
            recoverySnapshot: recoverySnapshot
        )
        XCTAssertEqual(controller.savedPlaybackSnapshot(), recoverySnapshot)

        controller.prependToQueuePreservingCurrent([first, second])
        XCTAssertEqual(controller.savedPlaybackSnapshot(), recoverySnapshot)
        controller.completeProgressiveQueueRestore()

        XCTAssertEqual(controller.queue.map(\.trackURN), [first, second, current, next].map(\.trackURN))
        XCTAssertEqual(controller.currentIndex, 2)
        XCTAssertEqual(controller.currentItem?.trackURN, current.trackURN)
        XCTAssertEqual(controller.savedPlaybackSnapshot()?.queue.map(\.trackURN), recoverySnapshot.queue.map(\.trackURN))

        controller.previous()
        XCTAssertEqual(controller.currentIndex, 1)
        XCTAssertEqual(controller.currentItem?.trackURN, second.trackURN)
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
