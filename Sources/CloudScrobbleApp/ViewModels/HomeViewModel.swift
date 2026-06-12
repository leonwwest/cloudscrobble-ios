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
            || !recommendedTracks.isEmpty
            || !homePlaylists.isEmpty
            || !likedTracks.isEmpty
            || !likedPlaylists.isEmpty
            || !homeMixes.isEmpty
    }

    private func loadPersonalStart(api: SoundCloudAPIClienting) async {
        var nextMe = me
        var nextFeedTracks = feedTracks
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
                + nextLikedTracks
                + playlistTracks
                + likedPlaylistTracks
        )
        let fallbackTracks = await discoveryFallbackTracks(
            api: api,
            existingCount: seedTracks.count,
            username: nextMe?.username
        )

        if nextFeedTracks.isEmpty {
            nextFeedTracks = nextLikedTracks
        }
        if nextFeedTracks.count < 8 {
            nextFeedTracks = Array(Self.uniqueTracks(nextFeedTracks + seedTracks + fallbackTracks).prefix(24))
        }

        let nextRecommended = Self.uniqueTracks(seedTracks + fallbackTracks)

        me = nextMe
        feedTracks = nextFeedTracks
        recommendedTracks = nextRecommended
        homePlaylists = nextHomePlaylists
        likedTracks = nextLikedTracks
        likedPlaylists = nextLikedPlaylists
        homeMixes = Self.buildHomeMixes(from: nextRecommended, username: nextMe?.username)
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
            recommendedTracks = tracks
            homePlaylists = playlists.collection
            likedTracks = []
            likedPlaylists = []
            homeMixes = Self.buildHomeMixes(from: tracks, username: nil)
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

    private static func buildHomeMixes(from tracks: [SCTrack], username: String?) -> [HomeMix] {
        let uniqueTracks = uniqueTracks(tracks)
        guard !uniqueTracks.isEmpty else { return [] }

        var mixes: [HomeMix] = [
            HomeMix(
                id: "daily-drops",
                title: "Daily Drops",
                subtitle: username.map { "Neue Picks für \($0)" } ?? "Neue SoundCloud Picks",
                tracks: Array(uniqueTracks.prefix(18)),
                iconName: "sparkles"
            ),
            HomeMix(
                id: "weekly-wave",
                title: "Weekly Wave",
                subtitle: "\(min(uniqueTracks.count, 20)) Tracks aus deinem Start",
                tracks: Self.rotated(uniqueTracks, by: max(1, uniqueTracks.count / 3), limit: 20),
                iconName: "waveform"
            )
        ]

        for offset in 0..<5 {
            let tracks = Self.rotated(uniqueTracks, by: offset * 3 + 1, limit: 18)
            guard !tracks.isEmpty else { continue }
            mixes.append(
                HomeMix(
                    id: "mein-mix-\(offset + 1)",
                    title: "Mein Mix \(offset + 1)",
                    subtitle: "\(tracks.count) Tracks aus Feed, Likes und Playlists",
                    tracks: tracks,
                    iconName: offset.isMultiple(of: 2) ? "sparkles" : "dot.radiowaves.left.and.right"
                )
            )
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

    private static func rotated(_ tracks: [SCTrack], by offset: Int, limit: Int) -> [SCTrack] {
        guard !tracks.isEmpty else { return [] }
        let normalizedOffset = offset % tracks.count
        let rotated = Array(tracks.dropFirst(normalizedOffset)) + Array(tracks.prefix(normalizedOffset))
        return Array(rotated.prefix(limit))
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
        recommendedTracks = cached.recommendedTracks
        homePlaylists = cached.homePlaylists
        likedTracks = cached.likedTracks
        likedPlaylists = cached.likedPlaylists
        homeMixes = Self.buildHomeMixes(from: cached.recommendedTracks, username: cached.me?.username)
    }

    private func persistCachedHome() {
        let cached = CachedHome(
            me: me,
            feedTracks: feedTracks,
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
