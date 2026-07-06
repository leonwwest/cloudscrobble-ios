import Foundation

/// Owns the UserDefaults-backed persistence for playback snapshots, recently
/// played tracks, and scrobble history. Extracted from `PlayerScrobbleController`
/// so the controller no longer mixes raw storage I/O with playback logic.
///
/// Not an actor: accessed only from the `@MainActor` controller.
@MainActor
final class PlaybackPersistenceStore {
    enum Key {
        static let savedPlaybackSnapshot = "cloudscrobble.savedPlaybackSnapshot.v1"
        static let recentlyPlayed = "cloudscrobble.recentlyPlayed.v1"
        static let scrobbleHistory = "cloudscrobble.scrobbleHistory.v1"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Snapshot

    func loadSnapshot() -> SavedPlaybackSnapshot? {
        guard let data = defaults.data(forKey: Key.savedPlaybackSnapshot) else {
            return nil
        }
        return try? JSONDecoder().decode(SavedPlaybackSnapshot.self, from: data)
    }

    func saveSnapshot(_ snapshot: SavedPlaybackSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Key.savedPlaybackSnapshot)
    }

    func clearSnapshot() {
        defaults.removeObject(forKey: Key.savedPlaybackSnapshot)
    }

    // MARK: - Recently played

    func loadRecentlyPlayed() -> [SavedPlaybackTrack] {
        guard let data = defaults.data(forKey: Key.recentlyPlayed),
              let decoded = try? JSONDecoder().decode([SavedPlaybackTrack].self, from: data) else {
            return []
        }
        return decoded
    }

    func saveRecentlyPlayed(_ tracks: [SavedPlaybackTrack]) {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        defaults.set(data, forKey: Key.recentlyPlayed)
    }

    func clearRecentlyPlayed() {
        defaults.removeObject(forKey: Key.recentlyPlayed)
    }

    // MARK: - Scrobble history

    func loadScrobbleHistory() -> [ScrobbleHistoryEntry] {
        guard let data = defaults.data(forKey: Key.scrobbleHistory),
              let decoded = try? JSONDecoder().decode([ScrobbleHistoryEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    func saveScrobbleHistory(_ entries: [ScrobbleHistoryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Key.scrobbleHistory)
    }

    func clearScrobbleHistory() {
        defaults.removeObject(forKey: Key.scrobbleHistory)
    }
}
