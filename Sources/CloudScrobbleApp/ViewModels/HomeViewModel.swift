import CloudScrobbleCore
import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    private enum Storage {
        static let cachedHomeKey = "cloudscrobble.cachedHome.v1"
    }

    private struct CachedHome: Codable {
        let me: SCUser?
        let feedTracks: [SCTrack]
        let followingTracks: [SCTrack]
        let recommendedTracks: [SCTrack]
        let homePlaylists: [SCPlaylist]
        let likedTracks: [SCTrack]
        let likedPlaylists: [SCPlaylist]
    }

    struct HomeMix: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let tracks: [SCTrack]
        let iconName: String

        var artworkURLs: [URL] {
            Array(tracks.compactMap(\.artworkURL).prefix(4))
        }
    }

    struct PlaylistTracksData: Identifiable {
        let playlist: SCPlaylist
        let tracks: [SCTrack]

        var id: String { playlist.id }
    }

    @Published private(set) var me: SCUser?
    @Published private(set) var feedTracks: [SCTrack] = []
    @Published private(set) var followingTracks: [SCTrack] = []
    @Published private(set) var recommendedTracks: [SCTrack] = []
    @Published private(set) var homePlaylists: [SCPlaylist] = []
    @Published private(set) var likedTracks: [SCTrack] = []
    @Published private(set) var likedPlaylists: [SCPlaylist] = []
    @Published private(set) var homeMixes: [HomeMix] = []
    @Published private(set) var selectedPlaylist: PlaylistTracksData?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingPlaylist = false
    @Published private(set) var message: String?

    private weak var session: AppSessionViewModel?

    init(session: AppSessionViewModel) {
        self.session = session
        restoreCachedHome()
    }

    func refresh() async {
        guard let session else {
            message = "App session unavailable"
            return
        }

        guard let api = session.apiClient else {
            message = hasHomeContent
                ? "Showing cached Start. Connect SoundCloud to refresh."
                : "Connect SoundCloud first"
            return
        }

        isLoading = true
        defer { isLoading = false }

        if session.soundCloudPublicMode && !session.soundCloudMockMode {
            await loadPublicStart(api: api)
        } else {
            await loadPersonalStart(api: api)
        }
    }

    func play(track: SCTrack, in context: [SCTrack]) async {
        guard let session else {
            message = "App session unavailable"
            return
        }

        let queue = context.isEmpty ? [track] : context
        guard let startIndex = queue.firstIndex(where: { $0.id == track.id }) else {
            await session.play(track: track)
            return
        }

        await session.play(tracks: queue, startAt: startIndex, maxQueueLength: 40)
    }

    func playNext(track: SCTrack) async {
        guard let session else {
            message = "App session unavailable"
            return
        }

        await session.playNext(track: track)
    }

    func addToQueue(track: SCTrack) async {
        guard let session else {
            message = "App session unavailable"
            return
        }

        await session.addToQueue(track: track)
    }

    func play(mix: HomeMix) async {
        guard let session else {
            message = "App session unavailable"
            return
        }

        await session.play(tracks: mix.tracks, startAt: 0, maxQueueLength: 40)
    }

    func play(savedTrack: SavedPlaybackTrack) async {
        guard let session else {
            message = "App session unavailable"
            return
        }

        await session.play(savedTrack: savedTrack)
    }

    func open(playlist: SCPlaylist) async {
        guard let session, let api = session.apiClient else {
            message = "Connect SoundCloud first"
            return
        }

        isLoadingPlaylist = true
        defer { isLoadingPlaylist = false }

        do {
            let tracks = try await loadTracks(for: playlist, api: api)
            selectedPlaylist = PlaylistTracksData(playlist: playlist, tracks: tracks)
            message = nil
        } catch {
            message = "Playlist loading failed: \(error.localizedDescription)"
        }
    }

    func play(playlist: SCPlaylist) async {
        guard let session, let api = session.apiClient else {
            message = "Connect SoundCloud first"
            return
        }

        isLoadingPlaylist = true
        defer { isLoadingPlaylist = false }

        do {
            let tracks = try await loadTracks(for: playlist, api: api)
            await session.play(tracks: tracks, startAt: 0, maxQueueLength: 60)
            message = nil
        } catch {
            message = "Playlist playback failed: \(error.localizedDescription)"
        }
    }

    func playSelectedPlaylist() async {
        guard let session else {
            message = "App session unavailable"
            return
        }
        guard let selectedPlaylist else {
            message = "No playlist selected"
            return
        }

        await session.play(tracks: selectedPlaylist.tracks, startAt: 0, maxQueueLength: 60)
    }

    func playSelectedPlaylist(startingWith track: SCTrack) async {
        guard let session else {
            message = "App session unavailable"
            return
        }
        guard let selectedPlaylist else {
            await session.play(track: track)
            return
        }

        let startIndex = selectedPlaylist.tracks.firstIndex(where: { $0.id == track.id }) ?? 0
        await session.play(tracks: selectedPlaylist.tracks, startAt: startIndex, maxQueueLength: 60)
    }

    func clearPlaylistSelection() {
        selectedPlaylist = nil
    }

    private var hasHomeContent: Bool {
        !feedTracks.isEmpty
            || !followingTracks.isEmpty
            || !recommendedTracks.isEmpty
            || !homePlaylists.isEmpty
            || !likedTracks.isEmpty
            || !likedPlaylists.isEmpty
            || !homeMixes.isEmpty
    }

    private func loadPersonalStart(api: SoundCloudAPIClienting) async {
        var nextMe = me
        var nextFeedTracks = feedTracks
        var nextFollowingTracks = followingTracks
        var nextHomePlaylists = homePlaylists
        var nextLikedTracks = likedTracks
        var nextLikedPlaylists = likedPlaylists
        var errors: [String] = []

        do {
            nextMe = try await api.me()
        } catch {
            errors.append("profile")
        }

        do {
            let trackActivities = try await api.homeFeedTracks(limit: 50, nextHref: nil)
            nextFeedTracks = Self.uniqueTracks(trackActivities.collection.compactMap(\.track))
        } catch {
            errors.append("Start tracks")
        }

        do {
            let activities = try await api.homeFeed(limit: 30, nextHref: nil)
            let activityTracks = activities.collection.compactMap(\.track)
            let activityPlaylists = activities.collection.compactMap(\.playlist)
            nextFeedTracks = Self.uniqueTracks(nextFeedTracks + activityTracks)
            nextHomePlaylists = Self.uniquePlaylists(activityPlaylists + nextHomePlaylists)
        } catch {
            errors.append("Start feed")
        }

        do {
            let playlistsPage = try await api.myPlaylists(limit: 40, nextHref: nil)
            nextHomePlaylists = Self.uniquePlaylists(nextHomePlaylists + playlistsPage.collection)
        } catch {
            errors.append("playlists")
        }

        do {
            let likedTracksPage = try await api.myLikedTracks(limit: 50, nextHref: nil)
            nextLikedTracks = likedTracksPage.collection
        } catch {
            errors.append("liked tracks")
        }

        do {
            let likedPlaylistsPage = try await api.myLikedPlaylists(limit: 30, nextHref: nil)
            nextLikedPlaylists = likedPlaylistsPage.collection
        } catch {
            errors.append("liked playlists")
        }

        do {
            let followingTracksPage = try await api.myFollowingTracks(limit: 50, nextHref: nil)
            nextFollowingTracks = followingTracksPage.collection
        } catch {
            errors.append("following tracks")
        }

        let playlistTracks = await loadTrackSamples(
            from: nextHomePlaylists,
            api: api,
            maxPlaylists: 6,
            maxTracksPerPlaylist: 12
        )
        let likedPlaylistTracks = await loadTrackSamples(
            from: nextLikedPlaylists,
            api: api,
            maxPlaylists: 4,
            maxTracksPerPlaylist: 10
        )

        let seedTracks = Self.uniqueTracks(
            nextFeedTracks
                + nextFollowingTracks
                + nextLikedTracks
                + playlistTracks
                + likedPlaylistTracks
        )
        let relatedMixes = await relatedMixes(
            from: seedTracks,
            api: api,
            username: nextMe?.username
        )
        let relatedTracks = Self.uniqueTracks(relatedMixes.flatMap(\.tracks))
        let discoveryTracks = await discoveryFallbackTracks(
            api: api,
            existingCount: Self.uniqueTracks(seedTracks + relatedTracks).count,
            username: nextMe?.username
        )

        if nextFeedTracks.isEmpty {
            nextFeedTracks = nextLikedTracks
        }
        if nextFeedTracks.count < 8 {
            nextFeedTracks = Array(Self.uniqueTracks(nextFeedTracks + nextFollowingTracks + discoveryTracks).prefix(24))
        }

        let nextRecommended = Self.uniqueTracks(seedTracks + relatedTracks + discoveryTracks)

        me = nextMe
        feedTracks = nextFeedTracks
        followingTracks = nextFollowingTracks
        recommendedTracks = nextRecommended
        homePlaylists = nextHomePlaylists
        likedTracks = nextLikedTracks
        likedPlaylists = nextLikedPlaylists
        homeMixes = Self.buildHomeMixes(
            feedTracks: nextFeedTracks,
            followingTracks: nextFollowingTracks,
            likedTracks: nextLikedTracks,
            relatedMixes: relatedMixes,
            username: nextMe?.username
        )
        selectedPlaylist = nil
        persistCachedHome()

        if errors.isEmpty {
            message = nil
        } else if hasHomeContent {
            message = "Showing partial Start. Could not refresh: \(errors.joined(separator: ", "))."
        } else {
            message = "Start loading failed: \(errors.joined(separator: ", "))."
        }
    }

    private func loadPublicStart(api: SoundCloudAPIClienting) async {
        do {
            let discovery = try await api.searchTracks(query: "lofi", limit: 25, nextHref: nil)
            let alternates = try await api.searchTracks(query: "new music", limit: 25, nextHref: nil)
            let playlists = try await api.searchPlaylists(query: "weekly", limit: 15, nextHref: nil)
            let tracks = Self.uniqueTracks(discovery.collection + alternates.collection)

            me = nil
            feedTracks = discovery.collection
            followingTracks = []
            recommendedTracks = tracks
            homePlaylists = playlists.collection
            likedTracks = []
            likedPlaylists = []
            homeMixes = Self.buildHomeMixes(
                feedTracks: discovery.collection,
                followingTracks: [],
                likedTracks: alternates.collection,
                relatedMixes: [],
                username: nil
            )
            selectedPlaylist = nil
            message = "Full SoundCloud login is needed for your personal Start. Showing public discovery."
        } catch {
            message = "Public Start loading failed: \(error.localizedDescription)"
        }
    }

    private func loadTrackSamples(
        from playlists: [SCPlaylist],
        api: SoundCloudAPIClienting,
        maxPlaylists: Int,
        maxTracksPerPlaylist: Int
    ) async -> [SCTrack] {
        var tracks: [SCTrack] = []
        for playlist in playlists.prefix(maxPlaylists) {
            guard let playlistTracks = try? await loadTracks(for: playlist, api: api) else {
                continue
            }
            tracks.append(contentsOf: playlistTracks.prefix(maxTracksPerPlaylist))
        }
        return Self.uniqueTracks(tracks)
    }

    private func relatedMixes(
        from seedTracks: [SCTrack],
        api: SoundCloudAPIClienting,
        username: String?
    ) async -> [HomeMix] {
        var mixes: [HomeMix] = []
        var usedTracks = Set<String>()

        for seed in seedTracks.prefix(7) {
            guard mixes.count < 5 else { break }
            guard let page = try? await api.relatedTracks(trackURN: seed.urn, limit: 25, nextHref: nil) else {
                continue
            }

            let uniqueRelated = Self.uniqueTracks(page.collection)
                .filter { track in
                    guard track.id != seed.id else { return false }
                    return !usedTracks.contains(track.id)
                }
            guard uniqueRelated.count >= 2 else { continue }

            uniqueRelated.prefix(18).forEach { usedTracks.insert($0.id) }
            mixes.append(
                HomeMix(
                    id: "mein-mix-\(mixes.count + 1)-\(seed.id)",
                    title: "Mein Mix \(mixes.count + 1)",
                    subtitle: "\(uniqueRelated.prefix(18).count) ähnliche Tracks zu \(seed.title)",
                    tracks: Array(uniqueRelated.prefix(18)),
                    iconName: mixes.count.isMultiple(of: 2) ? "sparkles" : "dot.radiowaves.left.and.right"
                )
            )
        }

        return mixes
    }

    private func discoveryFallbackTracks(
        api: SoundCloudAPIClienting,
        existingCount: Int,
        username: String?
    ) async -> [SCTrack] {
        guard existingCount < 12 else { return [] }

        let queries = Self.uniqueQueries([
            username,
            "weekly wave",
            "daily drops",
            "new music",
            "lofi"
        ])

        var tracks: [SCTrack] = []
        for query in queries {
            guard Self.uniqueTracks(tracks).count < 18 else { break }
            guard let page = try? await api.searchTracks(query: query, limit: 20, nextHref: nil) else {
                continue
            }
            tracks.append(contentsOf: page.collection)
        }

        return Self.uniqueTracks(tracks)
    }

    private func loadTracks(for playlist: SCPlaylist, api: SoundCloudAPIClienting) async throws -> [SCTrack] {
        do {
            let page = try await api.playlistTracks(urn: playlist.urn, limit: 100, nextHref: nil)
            if !page.collection.isEmpty {
                return page.collection
            }
        } catch {
            if playlist.tracks?.isEmpty != false {
                throw error
            }
        }

        var detailedTracks: [SCTrack] = []
        for entry in (playlist.tracks ?? []).prefix(100) {
            do {
                detailedTracks.append(try await api.track(urn: entry.urn))
            } catch {
                continue
            }
        }

        guard !detailedTracks.isEmpty else {
            throw CloudScrobbleError.invalidResponse
        }

        return detailedTracks
    }

    private static func buildHomeMixes(
        feedTracks: [SCTrack],
        followingTracks: [SCTrack],
        likedTracks: [SCTrack],
        relatedMixes: [HomeMix],
        username: String?
    ) -> [HomeMix] {
        let dailyDrops = uniqueTracks(feedTracks + followingTracks)
        let weeklyWave = uniqueTracks(followingTracks + feedTracks)
        let fallback = uniqueTracks(likedTracks + feedTracks + followingTracks)
        guard !dailyDrops.isEmpty || !weeklyWave.isEmpty || !relatedMixes.isEmpty || !fallback.isEmpty else {
            return []
        }

        var mixes: [HomeMix] = []

        if !dailyDrops.isEmpty {
            mixes.append(HomeMix(
                id: "daily-drops",
                title: "Daily Drops",
                subtitle: username.map { "Neue Tracks aus \($0)s Start" } ?? "Neue SoundCloud Tracks",
                tracks: Array(dailyDrops.prefix(24)),
                iconName: "sparkles"
            ))
        }

        if !weeklyWave.isEmpty {
            mixes.append(HomeMix(
                id: "weekly-wave",
                title: "Weekly Wave",
                subtitle: "\(min(weeklyWave.count, 24)) Tracks von deinem Feed und Followings",
                tracks: Array(weeklyWave.prefix(24)),
                iconName: "waveform"
            ))
        }

        mixes.append(contentsOf: relatedMixes)

        if mixes.isEmpty, !fallback.isEmpty {
            mixes.append(HomeMix(
                id: "start-fallback",
                title: "Mehr für dich",
                subtitle: "\(min(fallback.count, 24)) Tracks aus deiner SoundCloud-Bibliothek",
                tracks: Array(fallback.prefix(24)),
                iconName: "sparkles"
            ))
        }

        return mixes
    }

    private static func uniqueTracks(_ tracks: [SCTrack]) -> [SCTrack] {
        var seen = Set<String>()
        return tracks.filter { track in
            seen.insert(track.id).inserted
        }
    }

    private static func uniqueQueries(_ queries: [String?]) -> [String] {
        var seen = Set<String>()
        return queries.compactMap { query in
            guard let normalized = query?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !normalized.isEmpty,
                  seen.insert(normalized.lowercased()).inserted else {
                return nil
            }
            return normalized
        }
    }

    private static func uniquePlaylists(_ playlists: [SCPlaylist]) -> [SCPlaylist] {
        var seen = Set<String>()
        return playlists.filter { playlist in
            seen.insert(playlist.id).inserted
        }
    }

    private func restoreCachedHome() {
        guard let data = UserDefaults.standard.data(forKey: Storage.cachedHomeKey),
              let cached = try? JSONDecoder().decode(CachedHome.self, from: data) else {
            return
        }

        me = cached.me
        feedTracks = cached.feedTracks
        followingTracks = cached.followingTracks
        recommendedTracks = cached.recommendedTracks
        homePlaylists = cached.homePlaylists
        likedTracks = cached.likedTracks
        likedPlaylists = cached.likedPlaylists
        homeMixes = Self.buildHomeMixes(
            feedTracks: cached.feedTracks,
            followingTracks: cached.followingTracks,
            likedTracks: cached.likedTracks,
            relatedMixes: [],
            username: cached.me?.username
        )
    }

    private func persistCachedHome() {
        let cached = CachedHome(
            me: me,
            feedTracks: feedTracks,
            followingTracks: followingTracks,
            recommendedTracks: recommendedTracks,
            homePlaylists: homePlaylists,
            likedTracks: likedTracks,
            likedPlaylists: likedPlaylists
        )
        guard let data = try? JSONEncoder().encode(cached) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Storage.cachedHomeKey)
    }
}
