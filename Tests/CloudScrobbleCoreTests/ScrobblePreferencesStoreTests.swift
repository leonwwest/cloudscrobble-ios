import XCTest
@testable import CloudScrobbleCore

final class ScrobblePreferencesStoreTests: XCTestCase {
    func testMetadataOverridePersistsAndCanBeReset() async throws {
        let suite = try makeSuite()
        let key = "preferences"
        let store = ScrobblePreferencesStore(userDefaultsSuiteName: suite, storageKey: key)
        let fallback = LastFMTrackMeta(artist: "Uploader", track: "Raw title")
        let corrected = LastFMTrackMeta(artist: "Artist", track: "Track")

        await store.setMetadataOverride(corrected, for: "urn:track:1")

        let restoredStore = ScrobblePreferencesStore(userDefaultsSuiteName: suite, storageKey: key)
        var configuration = await restoredStore.configuration(for: "urn:track:1", fallback: fallback)
        XCTAssertEqual(configuration.metadata, corrected)
        XCTAssertTrue(configuration.isScrobblingEnabled)

        await restoredStore.resetMetadataOverride(for: "urn:track:1")
        configuration = await restoredStore.configuration(for: "urn:track:1", fallback: fallback)
        XCTAssertEqual(configuration.metadata, fallback)
    }

    func testTrackAndArtistExclusionsAreIndependentAndReversible() async throws {
        let suite = try makeSuite()
        let store = ScrobblePreferencesStore(userDefaultsSuiteName: suite, storageKey: "preferences")
        let metadata = LastFMTrackMeta(artist: "Beyoncé", track: "Track")

        await store.setTrackExcluded(true, trackURN: "urn:track:1")
        var configuration = await store.configuration(for: "urn:track:1", fallback: metadata)
        XCTAssertTrue(configuration.isTrackExcluded)
        XCTAssertFalse(configuration.isScrobblingEnabled)

        await store.setTrackExcluded(false, trackURN: "urn:track:1")
        await store.setArtistExcluded(true, artist: "BEYONCE")
        configuration = await store.configuration(for: "urn:track:2", fallback: metadata)
        XCTAssertTrue(configuration.isArtistExcluded)
        XCTAssertFalse(configuration.isScrobblingEnabled)

        await store.setArtistExcluded(false, artist: "beyoncé")
        configuration = await store.configuration(for: "urn:track:2", fallback: metadata)
        XCTAssertTrue(configuration.isScrobblingEnabled)
    }

    func testResetAllPreservesAutomaticMetadataAndClearsUserPreferences() async throws {
        let suite = try makeSuite()
        let key = "preferences"
        let store = ScrobblePreferencesStore(userDefaultsSuiteName: suite, storageKey: key)
        let automatic = LastFMTrackMeta(artist: "Automatic Artist", track: "Automatic Track")
        let corrected = LastFMTrackMeta(artist: "Corrected Artist", track: "Corrected Track")

        await store.registerAutomaticMetadata(automatic, for: "urn:track:1")
        await store.setMetadataOverride(corrected, for: "urn:track:1")
        await store.setTrackExcluded(true, trackURN: "urn:track:1")
        await store.setArtistExcluded(true, artist: corrected.artist)
        await store.resetAll()

        let restoredStore = ScrobblePreferencesStore(userDefaultsSuiteName: suite, storageKey: key)
        let restoredAutomatic = await restoredStore.automaticMetadata(for: "urn:track:1")
        XCTAssertEqual(restoredAutomatic, automatic)
        let configuration = await restoredStore.configuration(for: "urn:track:1", fallback: automatic)
        XCTAssertEqual(configuration.metadata, automatic)
        XCTAssertTrue(configuration.isScrobblingEnabled)
        XCTAssertFalse(configuration.isTrackExcluded)
        XCTAssertFalse(configuration.isArtistExcluded)
    }

    private func makeSuite() throws -> String {
        let suite = "ScrobblePreferencesStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw XCTSkip("Could not create isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suite)
        return suite
    }
}
