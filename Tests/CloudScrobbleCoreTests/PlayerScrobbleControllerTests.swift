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
