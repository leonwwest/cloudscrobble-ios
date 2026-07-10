import Foundation

private struct StableWeightedCandidate<Value> {
    let item: Value
    var rank: UInt64
    let firstSeen: Int
}

public struct FeedPersonalization: Codable, Equatable, Sendable {
    public enum Action: Codable, Equatable, Sendable {
        case artistScore(artistKey: String, previousScore: Int?)
        case hideTrack(trackKey: String, wasHidden: Bool)
    }

    public private(set) var hiddenTrackKeys: Set<String>
    public private(set) var artistScores: [String: Int]
    public private(set) var lastAction: Action?

    public init(
        hiddenTrackKeys: Set<String> = [],
        artistScores: [String: Int] = [:],
        lastAction: Action? = nil
    ) {
        self.hiddenTrackKeys = hiddenTrackKeys
        self.artistScores = artistScores.reduce(into: [:]) { result, entry in
            let score = Self.clampedScore(entry.value)
            if score != 0 {
                result[Self.normalized(entry.key)] = score
            }
        }
        self.lastAction = lastAction
    }

    public var hiddenTrackCount: Int {
        hiddenTrackKeys.count
    }

    public var ratedArtistCount: Int {
        artistScores.count
    }

    public var hasFeedback: Bool {
        !hiddenTrackKeys.isEmpty || !artistScores.isEmpty
    }

    public var canUndo: Bool {
        lastAction != nil
    }

    public func isHidden(trackKey: String) -> Bool {
        hiddenTrackKeys.contains(trackKey)
    }

    public func score(forArtistKey artistKey: String) -> Int {
        artistScores[Self.normalized(artistKey), default: 0]
    }

    public mutating func showMore(fromArtistKey artistKey: String) {
        adjustArtistScore(artistKey, delta: 1)
    }

    public mutating func showLess(fromArtistKey artistKey: String) {
        adjustArtistScore(artistKey, delta: -1)
    }

    public mutating func hide(trackKey: String) {
        let wasHidden = hiddenTrackKeys.contains(trackKey)
        lastAction = .hideTrack(trackKey: trackKey, wasHidden: wasHidden)
        hiddenTrackKeys.insert(trackKey)
    }

    @discardableResult
    public mutating func undoLastAction() -> Bool {
        guard let action = lastAction else { return false }

        switch action {
        case .artistScore(let artistKey, let previousScore):
            if let previousScore, previousScore != 0 {
                artistScores[artistKey] = previousScore
            } else {
                artistScores.removeValue(forKey: artistKey)
            }
        case .hideTrack(let trackKey, let wasHidden):
            if wasHidden {
                hiddenTrackKeys.insert(trackKey)
            } else {
                hiddenTrackKeys.remove(trackKey)
            }
        }

        lastAction = nil
        return true
    }

    public mutating func reset() {
        hiddenTrackKeys.removeAll()
        artistScores.removeAll()
        lastAction = nil
    }

    public func ranked<Item>(
        _ items: [Item],
        trackKey: (Item) -> String,
        artistKey: (Item) -> String
    ) -> [Item] {
        items.enumerated()
            .filter { !isHidden(trackKey: trackKey($0.element)) }
            .sorted { lhs, rhs in
                let lhsScore = score(forArtistKey: artistKey(lhs.element))
                let rhsScore = score(forArtistKey: artistKey(rhs.element))
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    public static func daySeed(
        for date: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    public static func stableWeightedOrder<Item>(
        sources: [(items: [Item], weight: Int)],
        seed: String,
        key: (Item) -> String
    ) -> [Item] {
        var candidates: [String: StableWeightedCandidate<Item>] = [:]
        var firstSeen = 0

        for (sourceIndex, source) in sources.enumerated() {
            let weight = max(1, source.weight)
            var seenInSource = Set<String>()

            for item in source.items {
                let itemKey = key(item)
                guard seenInSource.insert(itemKey).inserted else { continue }

                var bestRank = UInt64.max
                for drawIndex in 0..<weight {
                    bestRank = min(
                        bestRank,
                        stableHash("\(seed)|\(sourceIndex)|\(drawIndex)|\(itemKey)")
                    )
                }

                if var existing = candidates[itemKey] {
                    existing.rank = min(existing.rank, bestRank)
                    candidates[itemKey] = existing
                } else {
                    candidates[itemKey] = StableWeightedCandidate(item: item, rank: bestRank, firstSeen: firstSeen)
                    firstSeen += 1
                }
            }
        }

        return candidates.values
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank {
                    return lhs.rank < rhs.rank
                }
                return lhs.firstSeen < rhs.firstSeen
            }
            .map(\.item)
    }

    private mutating func adjustArtistScore(_ artistKey: String, delta: Int) {
        let normalizedKey = Self.normalized(artistKey)
        let previousScore = artistScores[normalizedKey]
        let nextScore = Self.clampedScore((previousScore ?? 0) + delta)
        lastAction = .artistScore(artistKey: normalizedKey, previousScore: previousScore)

        if nextScore == 0 {
            artistScores.removeValue(forKey: normalizedKey)
        } else {
            artistScores[normalizedKey] = nextScore
        }
    }

    private static func clampedScore(_ score: Int) -> Int {
        min(3, max(-3, score))
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
