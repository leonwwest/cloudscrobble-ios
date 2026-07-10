import Foundation
import XCTest
@testable import CloudScrobbleCore

final class FeedPersonalizationTests: XCTestCase {
    private struct Item: Equatable {
        let id: String
        let artist: String
    }

    func testLessDownranksArtistWithoutRemovingTracks() {
        var feedback = FeedPersonalization()
        feedback.showLess(fromArtistKey: "Artist A")

        let ranked = feedback.ranked(
            [
                Item(id: "a-1", artist: "Artist A"),
                Item(id: "b-1", artist: "Artist B"),
                Item(id: "a-2", artist: "Artist A")
            ],
            trackKey: \Item.id,
            artistKey: \Item.artist
        )

        XCTAssertEqual(ranked.map(\.id), ["b-1", "a-1", "a-2"])
        XCTAssertEqual(feedback.score(forArtistKey: "artist a"), -1)
    }

    func testRepeatedFeedbackUsesBoundedScores() {
        var feedback = FeedPersonalization()
        for _ in 0..<8 {
            feedback.showMore(fromArtistKey: "Artist")
        }
        XCTAssertEqual(feedback.score(forArtistKey: "Artist"), 3)

        for _ in 0..<10 {
            feedback.showLess(fromArtistKey: "Artist")
        }
        XCTAssertEqual(feedback.score(forArtistKey: "Artist"), -3)
    }

    func testHideIsExplicitAndUndoRestoresTrack() {
        var feedback = FeedPersonalization()
        feedback.hide(trackKey: "track-1")

        XCTAssertTrue(feedback.isHidden(trackKey: "track-1"))
        XCTAssertTrue(feedback.canUndo)
        XCTAssertTrue(feedback.undoLastAction())
        XCTAssertFalse(feedback.isHidden(trackKey: "track-1"))
        XCTAssertFalse(feedback.canUndo)
    }

    func testUndoRestoresPreviousArtistScore() {
        var feedback = FeedPersonalization()
        feedback.showMore(fromArtistKey: "Artist")
        feedback.showMore(fromArtistKey: "Artist")
        XCTAssertEqual(feedback.score(forArtistKey: "Artist"), 2)

        XCTAssertTrue(feedback.undoLastAction())
        XCTAssertEqual(feedback.score(forArtistKey: "Artist"), 1)
    }

    func testResetClearsHiddenTracksAndArtistScores() {
        var feedback = FeedPersonalization()
        feedback.hide(trackKey: "track-1")
        feedback.showLess(fromArtistKey: "Artist")

        feedback.reset()

        XCTAssertFalse(feedback.hasFeedback)
        XCTAssertFalse(feedback.canUndo)
        XCTAssertEqual(feedback.hiddenTrackCount, 0)
        XCTAssertEqual(feedback.ratedArtistCount, 0)
    }

    func testStableWeightedOrderIsRepeatableForSameDaySeed() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 1_788_566_400)
        let seed = FeedPersonalization.daySeed(for: date, calendar: calendar)
        let items = (0..<20).map { Item(id: "track-\($0)", artist: "artist-\($0)") }
        let sources = [(items: items, weight: 2)]

        let first = FeedPersonalization.stableWeightedOrder(sources: sources, seed: seed, key: \Item.id)
        let second = FeedPersonalization.stableWeightedOrder(sources: sources, seed: seed, key: \Item.id)

        XCTAssertEqual(first, second)
        XCTAssertEqual(Set(first.map(\.id)), Set(items.map(\.id)))
    }
}
