import Foundation

public protocol ScrobbleQueueStoreing: Sendable {
    func load() throws -> [PendingScrobble]
    func save(_ queue: [PendingScrobble]) throws
    func clear() throws
}

/// Minimal Keychain surface needed for one-time queue migration. Conforming
/// to a protocol (rather than the concrete `KeychainStore`) keeps migration
/// testable without touching the real macOS Keychain.
public protocol KeychainQueueMigrating: Sendable {
    func load(account: String) throws -> Data?
    func delete(account: String)
}

extension KeychainStore: KeychainQueueMigrating {}

public final class UserDefaultsScrobbleQueueStore: ScrobbleQueueStoreing, @unchecked Sendable {
    public static let defaultKey = "cloudscrobble.pendingScrobbles.v1"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsScrobbleQueueStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() throws -> [PendingScrobble] {
        guard let data = defaults.data(forKey: key) else {
            return []
        }
        do {
            return try JSONDecoder().decode([PendingScrobble].self, from: data)
        } catch {
            // Corrupt data is discarded rather than propagated: callers cannot
            // recover, and persisting the corruption would block all future
            // scrobbles. Removing it here lets the queue restart cleanly.
            defaults.removeObject(forKey: key)
            return []
        }
    }

    public func save(_ queue: [PendingScrobble]) throws {
        guard !queue.isEmpty else {
            try clear()
            return
        }
        let data = try JSONEncoder().encode(queue)
        defaults.set(data, forKey: key)
    }

    public func clear() throws {
        defaults.removeObject(forKey: key)
    }

    /// One-time migration from the legacy Keychain-backed queue. Safe to call
    /// on every launch: once UserDefaults holds data, the Keychain entry is
    /// removed and subsequent calls are no-ops.
    public func migrate(from keychain: KeychainQueueMigrating, account: String) {
        guard defaults.data(forKey: key) == nil else {
            // Already migrated; just ensure no stale Keychain entry lingers.
            keychain.delete(account: account)
            return
        }

        guard let data = try? keychain.load(account: account), !data.isEmpty else {
            keychain.delete(account: account)
            return
        }

        if let decoded = try? JSONDecoder().decode([PendingScrobble].self, from: data), !decoded.isEmpty {
            try? save(decoded)
        }
        // Remove the Keychain entry regardless of decode outcome so the queue
        // no longer lives in the Keychain.
        keychain.delete(account: account)
    }
}
