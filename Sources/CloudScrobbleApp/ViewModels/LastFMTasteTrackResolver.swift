import CloudScrobbleCore
import Foundation

enum LastFMTasteTrackResolver {
    static func resolveTracks(
        from profile: LastFMTasteProfile?,
        api: SoundCloudAPIClienting,
        maxTracks: Int = 48
    ) async -> [SCTrack] {
        guard let profile else { return [] }

        let recentQueries = profile.recentTracks
            .prefix(18)
            .map { "\($0.artist) \($0.name)" }
        let artistQueries = profile.topArtists
            .sorted { $0.playcount > $1.playcount }
            .prefix(12)
            .map(\.name)
        let artistDeepCutQueries = profile.topArtists
            .prefix(6)
            .map { "\($0.name) latest" }
        let queryPlans = uniqueQueries(Array(recentQueries) + Array(artistQueries) + Array(artistDeepCutQueries))
            .prefix(30)
            .map { query in
                (query: query, limit: query.contains(" ") ? 5 : 8)
            }

        var tracks: [SCTrack] = []
        for batch in queryPlans.chunked(size: 6) {
            guard uniqueTracks(tracks).count < maxTracks else { break }

            await withTaskGroup(of: [SCTrack].self) { group in
                for plan in batch {
                    group.addTask {
                        guard let page = try? await api.searchTracks(
                            query: plan.query,
                            limit: plan.limit,
                            nextHref: nil
                        ) else {
                            return []
                        }
                        return page.collection
                    }
                }

                for await result in group {
                    tracks.append(contentsOf: result)
                }
            }
        }

        return Array(uniqueTracks(tracks).prefix(maxTracks))
    }

    private static func uniqueTracks(_ tracks: [SCTrack]) -> [SCTrack] {
        TrackIdentity.uniqueTracks(tracks)
    }

    private static func uniqueQueries(_ queries: [String]) -> [String] {
        var seen = Set<String>()
        return queries.compactMap { query in
            let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty,
                  seen.insert(normalized.lowercased()).inserted else {
                return nil
            }
            return normalized
        }
    }
}

private extension Array {
    func chunked(size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}
