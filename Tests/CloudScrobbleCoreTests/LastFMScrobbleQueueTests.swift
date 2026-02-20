import XCTest
@testable import CloudScrobbleCore

final class LastFMScrobbleQueueTests: XCTestCase {
    func testBatchParameterBuilderBuildsIndexedFields() {
        let batch = [
            PendingScrobble(meta: LastFMTrackMeta(artist: "A1", track: "T1"), timestamp: 1_700_000_001),
            PendingScrobble(meta: LastFMTrackMeta(artist: "A2", track: "T2"), timestamp: 1_700_000_002)
        ]

        let params = LastFMScrobbleService.makeBatchScrobbleParameters(
            batch: batch,
            sessionKey: "session",
            apiKey: "api",
            apiSecret: "secret"
        )

        XCTAssertEqual(params["method"], "track.scrobble")
        XCTAssertEqual(params["artist[0]"], "A1")
        XCTAssertEqual(params["track[0]"], "T1")
        XCTAssertEqual(params["timestamp[0]"], "1700000001")
        XCTAssertEqual(params["artist[1]"], "A2")
        XCTAssertEqual(params["track[1]"], "T2")
        XCTAssertEqual(params["timestamp[1]"], "1700000002")
        XCTAssertNotNil(params["api_sig"])
    }

    func testMergedQueueDeduplicatesAndCaps() {
        let base = [
            PendingScrobble(meta: LastFMTrackMeta(artist: "A1", track: "T1"), timestamp: 1),
            PendingScrobble(meta: LastFMTrackMeta(artist: "A2", track: "T2"), timestamp: 2)
        ]

        let deduped = LastFMScrobbleService.mergedPendingQueue(
            existing: base,
            adding: PendingScrobble(meta: LastFMTrackMeta(artist: "A1", track: "T1"), timestamp: 1),
            maxCount: 10
        )
        XCTAssertEqual(deduped.count, 2)

        let capped = LastFMScrobbleService.mergedPendingQueue(
            existing: base,
            adding: PendingScrobble(meta: LastFMTrackMeta(artist: "A3", track: "T3"), timestamp: 3),
            maxCount: 2
        )

        XCTAssertEqual(capped.count, 2)
        XCTAssertEqual(capped.first?.meta.artist, "A2")
        XCTAssertEqual(capped.last?.meta.artist, "A3")
    }
}
