import XCTest
@testable import CloudScrobbleCore

final class ScrobbleQueueStoreTests: XCTestCase {
    private func makeStore() -> UserDefaultsScrobbleQueueStore {
        let suite = "cloudscrobble.tests.queue.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return UserDefaultsScrobbleQueueStore(defaults: defaults, key: "pending")
    }

    private final class MockKeychain: KeychainQueueMigrating, @unchecked Sendable {
        var entries: [String: Data] = [:]

        func load(account: String) throws -> Data? {
            entries[account]
        }

        func delete(account: String) {
            entries[account] = nil
        }
    }

    func testLoadEmptyWhenNothingPersisted() throws {
        let store = makeStore()
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testSaveAndLoadRoundTrips() throws {
        let store = makeStore()
        let queue = [
            PendingScrobble(meta: LastFMTrackMeta(artist: "A", track: "T"), timestamp: 1_700_000_001),
            PendingScrobble(meta: LastFMTrackMeta(artist: "B", track: "U"), timestamp: 1_700_000_002)
        ]
        try store.save(queue)

        let loaded = try store.load()
        XCTAssertEqual(loaded, queue)
    }

    func testSaveEmptyClears() throws {
        let store = makeStore()
        try store.save([PendingScrobble(meta: LastFMTrackMeta(artist: "A", track: "T"), timestamp: 1)])
        XCTAssertFalse(try store.load().isEmpty)

        try store.save([])
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testClearRemovesQueue() throws {
        let store = makeStore()
        try store.save([PendingScrobble(meta: LastFMTrackMeta(artist: "A", track: "T"), timestamp: 1)])
        try store.clear()
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testMigrateMovesQueueOutOfKeychainAndIsIdempotent() throws {
        let keychain = MockKeychain()
        let account = "lastfm.pending.scrobbles"

        let queue = [
            PendingScrobble(meta: LastFMTrackMeta(artist: "A", track: "T"), timestamp: 1_700_000_001)
        ]
        keychain.entries[account] = try JSONEncoder().encode(queue)

        let store = makeStore()
        store.migrate(from: keychain, account: account)

        XCTAssertEqual(try store.load(), queue)
        XCTAssertNil(keychain.entries[account], "Keychain entry must be removed after migration")

        // Second migration is a no-op and does not wipe the migrated data.
        store.migrate(from: keychain, account: account)
        XCTAssertEqual(try store.load(), queue)
    }

    func testMigrateWithCorruptKeychainDataClearsAndDoesNotCrash() throws {
        let keychain = MockKeychain()
        let account = "lastfm.pending.scrobbles"
        keychain.entries[account] = Data("not-json".utf8)

        let store = makeStore()
        store.migrate(from: keychain, account: account)

        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertNil(keychain.entries[account])
    }
}
