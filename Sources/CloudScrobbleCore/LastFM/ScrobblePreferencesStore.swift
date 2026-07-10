import Foundation

public struct ScrobbleTrackConfiguration: Equatable, Sendable {
    public let metadata: LastFMTrackMeta
    public let isScrobblingEnabled: Bool
    public let isTrackExcluded: Bool
    public let isArtistExcluded: Bool

    public init(
        metadata: LastFMTrackMeta,
        isScrobblingEnabled: Bool,
        isTrackExcluded: Bool,
        isArtistExcluded: Bool
    ) {
        self.metadata = metadata
        self.isScrobblingEnabled = isScrobblingEnabled
        self.isTrackExcluded = isTrackExcluded
        self.isArtistExcluded = isArtistExcluded
    }
}

/// Stores user corrections and explicit scrobble exclusions. SoundCloud
/// metadata is often uploader-oriented, so preferences are keyed by the stable
/// track URN and applied every time a stream is resolved.
public actor ScrobblePreferencesStore {
    private struct PersistedState: Codable {
        var metadataOverrides: [String: LastFMTrackMeta] = [:]
        var excludedTrackURNs: Set<String> = []
        var excludedArtistKeys: Set<String> = []
        var automaticMetadata: [String: LastFMTrackMeta] = [:]

        private enum CodingKeys: String, CodingKey {
            case metadataOverrides
            case excludedTrackURNs
            case excludedArtistKeys
            case automaticMetadata
        }

        init(
            metadataOverrides: [String: LastFMTrackMeta] = [:],
            excludedTrackURNs: Set<String> = [],
            excludedArtistKeys: Set<String> = [],
            automaticMetadata: [String: LastFMTrackMeta] = [:]
        ) {
            self.metadataOverrides = metadataOverrides
            self.excludedTrackURNs = excludedTrackURNs
            self.excludedArtistKeys = excludedArtistKeys
            self.automaticMetadata = automaticMetadata
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            metadataOverrides = try container.decodeIfPresent(
                [String: LastFMTrackMeta].self,
                forKey: .metadataOverrides
            ) ?? [:]
            excludedTrackURNs = try container.decodeIfPresent(
                Set<String>.self,
                forKey: .excludedTrackURNs
            ) ?? []
            excludedArtistKeys = try container.decodeIfPresent(
                Set<String>.self,
                forKey: .excludedArtistKeys
            ) ?? []
            automaticMetadata = try container.decodeIfPresent(
                [String: LastFMTrackMeta].self,
                forKey: .automaticMetadata
            ) ?? [:]
        }
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private var state: PersistedState

    public init(
        userDefaultsSuiteName: String? = nil,
        storageKey: String = "cloudscrobble.scrobblePreferences.v1"
    ) {
        let defaults = userDefaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) {
            state = decoded
        } else {
            state = PersistedState()
        }
    }

    public func configuration(
        for trackURN: String,
        fallback metadata: LastFMTrackMeta
    ) -> ScrobbleTrackConfiguration {
        let resolved = state.metadataOverrides[trackURN] ?? metadata
        let isTrackExcluded = state.excludedTrackURNs.contains(trackURN)
        let isArtistExcluded = state.excludedArtistKeys.contains(Self.artistKey(resolved.artist))
        return ScrobbleTrackConfiguration(
            metadata: resolved,
            isScrobblingEnabled: !isTrackExcluded && !isArtistExcluded,
            isTrackExcluded: isTrackExcluded,
            isArtistExcluded: isArtistExcluded
        )
    }

    public func setMetadataOverride(_ metadata: LastFMTrackMeta?, for trackURN: String) {
        if let metadata,
           let artist = Self.nonEmpty(metadata.artist),
           let track = Self.nonEmpty(metadata.track) {
            state.metadataOverrides[trackURN] = LastFMTrackMeta(artist: artist, track: track)
        } else {
            state.metadataOverrides.removeValue(forKey: trackURN)
        }
        persist()
    }

    /// Remembers the mapper-produced baseline separately from a user override,
    /// so resetting corrections also works while the network is unavailable.
    public func registerAutomaticMetadata(_ metadata: LastFMTrackMeta, for trackURN: String) {
        registerAutomaticMetadata([trackURN: metadata])
    }

    /// Batch form avoids repeatedly encoding a growing dictionary while a
    /// long playlist is resolved progressively.
    public func registerAutomaticMetadata(_ metadataByTrackURN: [String: LastFMTrackMeta]) {
        var didChange = false
        for (trackURN, metadata) in metadataByTrackURN {
            guard let artist = Self.nonEmpty(metadata.artist),
                  let track = Self.nonEmpty(metadata.track) else {
                continue
            }
            let normalized = LastFMTrackMeta(artist: artist, track: track)
            guard state.automaticMetadata[trackURN] != normalized else { continue }
            state.automaticMetadata[trackURN] = normalized
            didChange = true
        }
        if didChange {
            persist()
        }
    }

    public func automaticMetadata(for trackURN: String) -> LastFMTrackMeta? {
        state.automaticMetadata[trackURN]
    }

    public func setTrackExcluded(_ excluded: Bool, trackURN: String) {
        if excluded {
            state.excludedTrackURNs.insert(trackURN)
        } else {
            state.excludedTrackURNs.remove(trackURN)
        }
        persist()
    }

    public func setArtistExcluded(_ excluded: Bool, artist: String) {
        let key = Self.artistKey(artist)
        guard !key.isEmpty else { return }
        if excluded {
            state.excludedArtistKeys.insert(key)
        } else {
            state.excludedArtistKeys.remove(key)
        }
        persist()
    }

    public func resetMetadataOverride(for trackURN: String) {
        state.metadataOverrides.removeValue(forKey: trackURN)
        persist()
    }

    public func resetAll() {
        let automaticMetadata = state.automaticMetadata
        state = PersistedState(automaticMetadata: automaticMetadata)
        if automaticMetadata.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func artistKey(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
