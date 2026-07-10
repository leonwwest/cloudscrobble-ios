import CloudScrobbleCore
import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    private enum Storage {
        static let cachedHomeKey = "cloudscrobble.cachedHome.v2"
        static let feedFeedbackKey = "cloudscrobble.feedFeedback.v2"
        static let legacyFeedFeedbackKey = "cloudscrobble.feedFeedback.v1"
    }

    private struct LegacyFeedFeedback: Codable {
        var hiddenTrackKeys: Set<String> = []
        var mutedArtistKeys: Set<String> = []
        var boostedArtistKeys: Set<String> = []
    }

    private enum PersonalStartEvent: Sendable {
        case profile(SCUser?)
        case ownedTracks([SCTrack]?)
        case feedTracks(SCPage<SCActivity>?)
        case feedActivities(SCPage<SCActivity>?)
        case playlists(SCPage<SCPlaylist>?)
        case likedTracks(SCPage<SCTrack>?)
        case likedPlaylists(SCPage<SCPlaylist>?)
        case followingTracks(SCPage<SCTrack>?)
        case lastFMTaste([SCTrack])
    }

    private enum DerivedStartEvent: Sendable {
        case stations([HomeMix])
        case discovery([SCTrack])
    }

    private struct CachedHome: Codable {
        let me: SCUser?
        let myTracks: [SCTrack]
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
    @Published private(set) var myTracks: [SCTrack] = []
    @Published private(set) var feedTracks: [SCTrack] = []
    @Published private(set) var followingTracks: [SCTrack] = []
    @Published private(set) var recommendedTracks: [SCTrack] = []
    @Published private(set) var homePlaylists: [SCPlaylist] = []
    @Published private(set) var likedTracks: [SCTrack] = []
    @Published private(set) var likedPlaylists: [SCPlaylist] = []
    @Published private(set) var homeMixes: [HomeMix] = []
    @Published private(set) var stationMixes: [HomeMix] = []
    @Published private(set) var selectedPlaylist: PlaylistTracksData?
    @Published private(set) var selectedMix: HomeMix?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingPlaylist = false
    @Published private(set) var isLoadingMoreFeed = false
    @Published private(set) var canLoadMoreFeed = false
    @Published private(set) var feedbackSummary: String?
    @Published private(set) var message: String?

    private weak var session: AppSessionViewModel?
    private var feedTrackNextHref: URL?
    private var feedActivityNextHref: URL?
    private var feedback: FeedPersonalization
    private var sourceMyTracks: [SCTrack] = []
    private var sourceFeedTracks: [SCTrack] = []
    private var sourceFollowingTracks: [SCTrack] = []
    private var sourceRecommendedTracks: [SCTrack] = []
    private var sourceLikedTracks: [SCTrack] = []
    private var sourcePlaylistTracks: [SCTrack] = []
    private var sourceLikedPlaylistTracks: [SCTrack] = []
    private var sourceLastFMTasteTracks: [SCTrack] = []
    private var sourceSupplementalTracks: [SCTrack] = []
    private var sourceStationMixes: [HomeMix] = []
    private var refreshGeneration = UUID()

    init(session: AppSessionViewModel) {
        self.session = session
        self.feedback = Self.loadFeedFeedback()
        restoreCachedHome()
    }

    var hasFeedFeedback: Bool {
        feedback.hasFeedback
    }

    var canUndoFeedback: Bool {
        feedback.canUndo
    }

    var feedbackManagementSummary: String {
        let artists = feedback.ratedArtistCount
        let tracks = feedback.hiddenTrackCount
        return String(localized: "\(artists) artists rated · \(tracks) tracks hidden")
    }

    func refresh() async {
        let generation = UUID()
        refreshGeneration = generation
        isLoadingMoreFeed = false

        guard let session else {
            isLoading = false
            message = String(localized: "App session unavailable")
            return
        }

        guard let api = session.apiClient else {
            isLoading = false
            message = hasHomeContent
                ? String(localized: "Showing cached Start. Connect SoundCloud to refresh.")
                : String(localized: "Connect SoundCloud first")
            return
        }

        isLoading = true
        defer {
            if refreshGeneration == generation {
                isLoading = false
            }
        }

        if session.soundCloudPublicMode && !session.soundCloudMockMode {
            await loadPublicStart(api: api, generation: generation)
        } else {
            await loadPersonalStart(api: api, generation: generation)
        }
    }

    func play(track: SCTrack, in context: [SCTrack]) async {
        guard let session else {
            message = String(localized: "App session unavailable")
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
            message = String(localized: "App session unavailable")
            return
        }

        await session.playNext(track: track)
    }

    func addToQueue(track: SCTrack) async {
        guard let session else {
            message = String(localized: "App session unavailable")
            return
        }

        await session.addToQueue(track: track)
    }

    func hide(track: SCTrack) {
        feedback.hide(trackKey: TrackIdentity.canonicalKey(for: track))
        persistFeedFeedback()
        rebuildVisibleHomeAfterFeedback()
        feedbackSummary = String(localized: "Track hidden from Start")
    }

    func lessLike(track: SCTrack) {
        feedback.showLess(fromArtistKey: Self.artistKey(for: track))
        persistFeedFeedback()
        rebuildVisibleHomeAfterFeedback()
        feedbackSummary = String(localized: "Showing less from \(TrackIdentity.displayMetadata(for: track).artist)")
    }

    func moreLike(track: SCTrack) {
        feedback.showMore(fromArtistKey: Self.artistKey(for: track))
        persistFeedFeedback()
        rebuildVisibleHomeAfterFeedback()
        feedbackSummary = String(localized: "Prioritizing \(TrackIdentity.displayMetadata(for: track).artist)")
    }

    func undoLastFeedback() {
        guard feedback.undoLastAction() else { return }
        persistFeedFeedback()
        rebuildVisibleHomeAfterFeedback()
        feedbackSummary = String(localized: "Last personalization undone")
    }

    func resetFeedFeedback() {
        feedback.reset()
        persistFeedFeedback()
        rebuildVisibleHomeAfterFeedback()
        feedbackSummary = String(localized: "Feed feedback reset")
    }

    func loadMoreFeed() async {
        guard !isLoadingMoreFeed, !isLoading, canLoadMoreFeed else { return }
        guard let session, let api = session.apiClient else {
            message = String(localized: "Connect SoundCloud first")
            return
        }

        let generation = refreshGeneration
        isLoadingMoreFeed = true
        defer {
            if refreshGeneration == generation {
                isLoadingMoreFeed = false
            }
        }

        var loadedTracks: [SCTrack] = []
        var loadedPlaylists: [SCPlaylist] = []

        if let nextHref = feedTrackNextHref {
            if let page = try? await api.homeFeedTracks(limit: 50, nextHref: nextHref) {
                guard isCurrentRefresh(generation) else { return }
                loadedTracks.append(contentsOf: page.collection.compactMap(\.track))
                feedTrackNextHref = page.nextHref
            } else {
                guard isCurrentRefresh(generation) else { return }
                feedTrackNextHref = nil
            }
        }

        if let nextHref = feedActivityNextHref {
            if let page = try? await api.homeFeed(limit: 30, nextHref: nextHref) {
                guard isCurrentRefresh(generation) else { return }
                loadedTracks.append(contentsOf: page.collection.compactMap(\.track))
                loadedPlaylists.append(contentsOf: page.collection.compactMap(\.playlist))
                feedActivityNextHref = page.nextHref
            } else {
                guard isCurrentRefresh(generation) else { return }
                feedActivityNextHref = nil
            }
        }

        guard isCurrentRefresh(generation) else { return }
        canLoadMoreFeed = feedTrackNextHref != nil || feedActivityNextHref != nil
        guard !loadedTracks.isEmpty || !loadedPlaylists.isEmpty else {
            message = canLoadMoreFeed
                ? String(localized: "No new Start tracks on this page.")
                : String(localized: "Start feed fully loaded.")
            return
        }

        sourceFeedTracks = Self.uniqueTracks(sourceFeedTracks + loadedTracks)
        sourceRecommendedTracks = Self.uniqueTracks(sourceRecommendedTracks + loadedTracks)
        homePlaylists = Self.uniquePlaylists(homePlaylists + loadedPlaylists)
        rebuildVisibleHomeAfterFeedback()
        persistCachedHome()
        message = loadedTracks.isEmpty
            ? String(localized: "Loaded more playlists.")
            : String(localized: "Loaded \(loadedTracks.count) more Start tracks.")
    }

    func play(mix: HomeMix) async {
        guard let session else {
            message = String(localized: "App session unavailable")
            return
        }

        await session.playPlaylist(tracks: mix.tracks, startAt: 0)
    }

    func open(mix: HomeMix) {
        selectedPlaylist = nil
        selectedMix = mix
        message = nil
    }

    func play(savedTrack: SavedPlaybackTrack) async {
        guard let session else {
            message = String(localized: "App session unavailable")
            return
        }

        await session.play(savedTrack: savedTrack)
    }

    func open(playlist: SCPlaylist) async {
        guard let session else {
            message = String(localized: "Connect SoundCloud first")
            return
        }

        isLoadingPlaylist = true
        defer { isLoadingPlaylist = false }

        do {
            let tracks = try await session.loadPlaylistTracks(for: playlist)
            selectedMix = nil
            selectedPlaylist = PlaylistTracksData(playlist: playlist, tracks: tracks)
            message = nil
        } catch {
            message = String(localized: "Playlist loading failed: \(error.localizedDescription)")
        }
    }

    func play(playlist: SCPlaylist) async {
        guard let session else {
            message = String(localized: "Connect SoundCloud first")
            return
        }

        isLoadingPlaylist = true
        defer { isLoadingPlaylist = false }

        await session.playPlaylist(playlist)
        message = nil
    }

    func playSelectedPlaylist() async {
        guard let session else {
            message = String(localized: "App session unavailable")
            return
        }
        guard let selectedPlaylist else {
            message = String(localized: "No playlist selected")
            return
        }

        await session.playPlaylist(tracks: selectedPlaylist.tracks, startAt: 0)
    }

    func playSelectedPlaylist(startingWith track: SCTrack) async {
        guard let session else {
            message = String(localized: "App session unavailable")
            return
        }
        guard let selectedPlaylist else {
            await session.play(track: track)
            return
        }

        let startIndex = selectedPlaylist.tracks.firstIndex(where: { $0.id == track.id }) ?? 0
        await session.playPlaylist(tracks: selectedPlaylist.tracks, startAt: startIndex)
    }

    func playSelectedMix() async {
        guard let selectedMix else {
            message = String(localized: "No mix selected")
            return
        }

        await play(mix: selectedMix)
    }

    func playSelectedMix(startingWith track: SCTrack) async {
        guard let session else {
            message = String(localized: "App session unavailable")
            return
        }
        guard let selectedMix else {
            await session.play(track: track)
            return
        }

        let startIndex = selectedMix.tracks.firstIndex(where: { $0.id == track.id }) ?? 0
        await session.playPlaylist(tracks: selectedMix.tracks, startAt: startIndex)
    }

    func clearPlaylistSelection() {
        selectedPlaylist = nil
    }

    func clearMixSelection() {
        selectedMix = nil
    }

    private var hasHomeContent: Bool {
        !feedTracks.isEmpty
            || !followingTracks.isEmpty
            || !recommendedTracks.isEmpty
            || !homePlaylists.isEmpty
            || !likedTracks.isEmpty
            || !likedPlaylists.isEmpty
            || !homeMixes.isEmpty
            || !stationMixes.isEmpty
    }

    private func loadPersonalStart(api: SoundCloudAPIClienting, generation: UUID) async {
        guard let session, isCurrentRefresh(generation) else { return }

        var errors: [String] = []
        var refreshedFeedTracks: [SCTrack]?
        var refreshedActivityTracks: [SCTrack]?
        var refreshedActivityPlaylists: [SCPlaylist]?
        var refreshedPlaylists: [SCPlaylist]?

        sourcePlaylistTracks = []
        sourceLikedPlaylistTracks = []
        sourceLastFMTasteTracks = []
        sourceSupplementalTracks = []
        sourceStationMixes = []

        await withTaskGroup(of: PersonalStartEvent.self) { group in
            group.addTask { .profile(try? await api.me()) }
            group.addTask { .feedTracks(try? await api.homeFeedTracks(limit: 50, nextHref: nil)) }
            group.addTask { .feedActivities(try? await api.homeFeed(limit: 30, nextHref: nil)) }
            group.addTask { .playlists(try? await api.myPlaylists(limit: 40, nextHref: nil)) }
            group.addTask { .likedTracks(try? await api.myLikedTracks(limit: 50, nextHref: nil)) }
            group.addTask { .likedPlaylists(try? await api.myLikedPlaylists(limit: 30, nextHref: nil)) }
            group.addTask { .followingTracks(try? await api.myFollowingTracks(limit: 50, nextHref: nil)) }
            group.addTask { .lastFMTaste(await session.lastFMTasteTracks(api: api, maxTracks: 72)) }

            while let event = await group.next() {
                guard isCurrentRefresh(generation) else {
                    group.cancelAll()
                    return
                }
                switch event {
                case .profile(let profile):
                    guard let profile else {
                        errors.append("profile")
                        continue
                    }
                    me = profile
                    group.addTask {
                        let page = try? await api.userTracks(urn: profile.urn, limit: 50, nextHref: nil)
                        return .ownedTracks(page?.collection)
                    }
                case .ownedTracks(let tracks):
                    guard let tracks else {
                        errors.append("own tracks")
                        continue
                    }
                    sourceMyTracks = Self.uniqueTracks(tracks)
                    rebuildVisibleHomeAfterFeedback(persist: false)
                case .feedTracks(let page):
                    guard let page else {
                        errors.append("Start tracks")
                        continue
                    }
                    refreshedFeedTracks = Self.uniqueTracks(page.collection.compactMap(\.track))
                    sourceFeedTracks = Self.uniqueTracks((refreshedFeedTracks ?? []) + (refreshedActivityTracks ?? []))
                    feedTrackNextHref = page.nextHref
                    rebuildVisibleHomeAfterFeedback(persist: false)
                case .feedActivities(let page):
                    guard let page else {
                        errors.append("Start feed")
                        continue
                    }
                    refreshedActivityTracks = Self.uniqueTracks(page.collection.compactMap(\.track))
                    refreshedActivityPlaylists = Self.uniquePlaylists(page.collection.compactMap(\.playlist))
                    sourceFeedTracks = Self.uniqueTracks((refreshedFeedTracks ?? []) + (refreshedActivityTracks ?? []))
                    homePlaylists = Self.uniquePlaylists((refreshedActivityPlaylists ?? []) + (refreshedPlaylists ?? []))
                    feedActivityNextHref = page.nextHref
                    rebuildVisibleHomeAfterFeedback(persist: false)
                case .playlists(let page):
                    guard let page else {
                        errors.append("playlists")
                        continue
                    }
                    refreshedPlaylists = Self.uniquePlaylists(page.collection)
                    homePlaylists = Self.uniquePlaylists((refreshedActivityPlaylists ?? []) + (refreshedPlaylists ?? []))
                case .likedTracks(let page):
                    guard let page else {
                        errors.append("liked tracks")
                        continue
                    }
                    sourceLikedTracks = Self.uniqueTracks(page.collection)
                    rebuildVisibleHomeAfterFeedback(persist: false)
                case .likedPlaylists(let page):
                    guard let page else {
                        errors.append("liked playlists")
                        continue
                    }
                    likedPlaylists = Self.uniquePlaylists(page.collection)
                case .followingTracks(let page):
                    guard let page else {
                        errors.append("following tracks")
                        continue
                    }
                    sourceFollowingTracks = Self.uniqueTracks(page.collection)
                    rebuildVisibleHomeAfterFeedback(persist: false)
                case .lastFMTaste(let tracks):
                    sourceLastFMTasteTracks = Self.uniqueTracks(tracks)
                    rebuildVisibleHomeAfterFeedback(persist: false)
                }
            }
        }
        guard isCurrentRefresh(generation) else { return }

        async let playlistTracksTask = loadTrackSamples(
            from: homePlaylists,
            api: api,
            maxPlaylists: 6,
            maxTracksPerPlaylist: 12
        )
        async let likedPlaylistTracksTask = loadTrackSamples(
            from: likedPlaylists,
            api: api,
            maxPlaylists: 4,
            maxTracksPerPlaylist: 10
        )
        let (playlistTracks, likedPlaylistTracks) = await (playlistTracksTask, likedPlaylistTracksTask)
        guard isCurrentRefresh(generation) else { return }
        sourcePlaylistTracks = playlistTracks
        sourceLikedPlaylistTracks = likedPlaylistTracks
        rebuildVisibleHomeAfterFeedback(persist: false)

        var seedTrackCandidates = sourceFeedTracks
        seedTrackCandidates += sourceMyTracks
        seedTrackCandidates += sourceFollowingTracks
        seedTrackCandidates += sourceLikedTracks
        seedTrackCandidates += playlistTracks
        seedTrackCandidates += likedPlaylistTracks
        seedTrackCandidates += sourceLastFMTasteTracks
        let uniqueSeedTracks = Self.uniqueTracks(seedTrackCandidates)
        let seedTracks = rankedFeedbackTracks(uniqueSeedTracks)
        var loadedStations: [HomeMix] = []
        var discoveryTracks: [SCTrack] = []
        let username = me?.username

        await withTaskGroup(of: DerivedStartEvent.self) { group in
            group.addTask { .stations(await self.stationMixes(from: seedTracks, api: api)) }
            group.addTask {
                .discovery(await self.discoveryFallbackTracks(
                    api: api,
                    existingCount: seedTracks.count,
                    username: username
                ))
            }

            for await event in group {
                guard isCurrentRefresh(generation) else {
                    group.cancelAll()
                    return
                }
                switch event {
                case .stations(let stations):
                    loadedStations = stations
                    sourceStationMixes = stations
                    rebuildVisibleHomeAfterFeedback(persist: false)
                case .discovery(let tracks):
                    discoveryTracks = tracks
                    sourceFeedTracks = Self.uniqueTracks(sourceFeedTracks + tracks)
                    rebuildVisibleHomeAfterFeedback(persist: false)
                }
            }
        }
        guard isCurrentRefresh(generation) else { return }

        if sourceFeedTracks.isEmpty {
            sourceFeedTracks = sourceLikedTracks
        }
        let stationTracks = Self.uniqueTracks(loadedStations.flatMap(\.tracks))
        sourceRecommendedTracks = Self.uniqueTracks(seedTracks + stationTracks + discoveryTracks)
        rebuildVisibleHomeAfterFeedback(persist: false)
        selectedPlaylist = nil
        selectedMix = nil
        canLoadMoreFeed = feedTrackNextHref != nil || feedActivityNextHref != nil
        persistCachedHome()

        if errors.isEmpty {
            message = nil
        } else if hasHomeContent {
            message = String(localized: "Showing partial Start. Could not refresh: \(errors.joined(separator: ", ")).")
        } else {
            message = String(localized: "Start loading failed: \(errors.joined(separator: ", ")).")
        }
    }

    private func loadPublicStart(api: SoundCloudAPIClienting, generation: UUID) async {
        async let discoveryTask = try? await api.searchTracks(query: "lofi", limit: 25, nextHref: nil)
        async let alternatesTask = try? await api.searchTracks(query: "new music", limit: 25, nextHref: nil)
        async let playlistsTask = try? await api.searchPlaylists(query: "weekly", limit: 15, nextHref: nil)
        let (discovery, alternates, playlists) = await (discoveryTask, alternatesTask, playlistsTask)
        guard isCurrentRefresh(generation) else { return }

        guard discovery != nil || alternates != nil || playlists != nil else {
            message = String(localized: "Public Start loading failed.")
            return
        }

        let discoveryTracks = discovery?.collection ?? []
        let alternateTracks = alternates?.collection ?? []
        me = nil
        sourceMyTracks = []
        sourceFeedTracks = Self.uniqueTracks(discoveryTracks)
        sourceFollowingTracks = []
        sourceLikedTracks = []
        sourcePlaylistTracks = []
        sourceLikedPlaylistTracks = []
        sourceLastFMTasteTracks = []
        sourceSupplementalTracks = Self.uniqueTracks(alternateTracks)
        sourceRecommendedTracks = Self.uniqueTracks(discoveryTracks + alternateTracks)
        sourceStationMixes = Self.buildFallbackStationMixes(from: sourceRecommendedTracks)
        homePlaylists = playlists?.collection ?? []
        likedPlaylists = []
        rebuildVisibleHomeAfterFeedback(persist: false)
        selectedPlaylist = nil
        selectedMix = nil
        canLoadMoreFeed = false
        persistCachedHome()
        message = String(localized: "Full SoundCloud login is needed for your personal Start. Showing public discovery.")
    }

    private func isCurrentRefresh(_ generation: UUID) -> Bool {
        !Task.isCancelled && refreshGeneration == generation
    }

    private func loadTrackSamples(
        from playlists: [SCPlaylist],
        api: SoundCloudAPIClienting,
        maxPlaylists: Int,
        maxTracksPerPlaylist: Int
    ) async -> [SCTrack] {
        let selectedPlaylists = Array(playlists.prefix(maxPlaylists))
        var indexedTracks: [(Int, [SCTrack])] = []

        for batchStart in stride(from: 0, to: selectedPlaylists.count, by: 3) {
            let batchEnd = min(batchStart + 3, selectedPlaylists.count)
            await withTaskGroup(of: (Int, [SCTrack]).self) { group in
                for index in batchStart..<batchEnd {
                    let playlist = selectedPlaylists[index]
                    group.addTask {
                        let tracks = (try? await Self.loadTracks(for: playlist, api: api)) ?? []
                        return (index, Array(tracks.prefix(maxTracksPerPlaylist)))
                    }
                }

                for await result in group {
                    indexedTracks.append(result)
                }
            }
        }

        return Self.uniqueTracks(
            indexedTracks.sorted { $0.0 < $1.0 }.flatMap(\.1)
        )
    }

    private func stationMixes(
        from seedTracks: [SCTrack],
        api: SoundCloudAPIClienting
    ) async -> [HomeMix] {
        let seeds = Array(Self.uniqueTracks(seedTracks).prefix(7))
        var relatedResults: [(Int, SCTrack, [SCTrack])] = []

        for batchStart in stride(from: 0, to: seeds.count, by: 3) {
            let batchEnd = min(batchStart + 3, seeds.count)
            await withTaskGroup(of: (Int, SCTrack, [SCTrack]).self) { group in
                for index in batchStart..<batchEnd {
                    let seed = seeds[index]
                    group.addTask {
                        let page = try? await api.relatedTracks(trackURN: seed.urn, limit: 30, nextHref: nil)
                        return (index, seed, page?.collection ?? [])
                    }
                }

                for await result in group {
                    relatedResults.append(result)
                }
            }
        }

        var stations: [HomeMix] = []
        var usedTracks = Set<String>()

        for (_, seed, relatedTracks) in relatedResults.sorted(by: { $0.0 < $1.0 }) {
            guard stations.count < 5 else { break }
            let stationTracks = Self.uniqueTracks([seed] + relatedTracks)
                .filter { track in
                    if track.id == seed.id { return true }
                    return !usedTracks.contains(track.id)
                }
            guard stationTracks.count >= 2 else { continue }

            stationTracks.prefix(24).forEach { usedTracks.insert($0.id) }
            stations.append(
                HomeMix(
                    id: "sender-\(seed.id)",
                    title: String(localized: "\(seed.user.username) Station"),
                    subtitle: String(localized: "Radio based on \(seed.title)"),
                    tracks: Array(stationTracks.prefix(24)),
                    iconName: "dot.radiowaves.left.and.right"
                )
            )
        }

        if !stations.isEmpty {
            return stations
        }

        return Self.buildFallbackStationMixes(from: seedTracks)
    }

    private static func buildFallbackStationMixes(from tracks: [SCTrack]) -> [HomeMix] {
        let dedupedTracks = uniqueTracks(tracks)
        guard !dedupedTracks.isEmpty else { return [] }

        return dedupedTracks.prefix(4).enumerated().map { index, seed in
            let rotated = Array(dedupedTracks.dropFirst(index)) + Array(dedupedTracks.prefix(index))
            return HomeMix(
                id: "sender-fallback-\(seed.id)",
                title: String(localized: "\(seed.user.username) Station"),
                subtitle: String(localized: "Radio based on \(seed.title)"),
                tracks: Array(rotated.prefix(20)),
                iconName: "dot.radiowaves.left.and.right"
            )
        }
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

        var indexedTracks: [(Int, [SCTrack])] = []
        for batchStart in stride(from: 0, to: queries.count, by: 3) {
            guard Self.uniqueTracks(indexedTracks.flatMap(\.1)).count < 18 else { break }
            let batchEnd = min(batchStart + 3, queries.count)

            await withTaskGroup(of: (Int, [SCTrack]).self) { group in
                for index in batchStart..<batchEnd {
                    let query = queries[index]
                    group.addTask {
                        let page = try? await api.searchTracks(query: query, limit: 20, nextHref: nil)
                        return (index, page?.collection ?? [])
                    }
                }

                for await result in group {
                    indexedTracks.append(result)
                }
            }
        }

        return Array(Self.uniqueTracks(indexedTracks.sorted { $0.0 < $1.0 }.flatMap(\.1)).prefix(18))
    }

    private nonisolated static func loadTracks(for playlist: SCPlaylist, api: SoundCloudAPIClienting) async throws -> [SCTrack] {
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

        let entries = Array((playlist.tracks ?? []).prefix(100))
        var indexedTracks: [(Int, SCTrack)] = []
        for batchStart in stride(from: 0, to: entries.count, by: 6) {
            let batchEnd = min(batchStart + 6, entries.count)
            await withTaskGroup(of: (Int, SCTrack?).self) { group in
                for index in batchStart..<batchEnd {
                    let entry = entries[index]
                    group.addTask {
                        (index, try? await api.track(urn: entry.urn))
                    }
                }

                for await (index, track) in group {
                    if let track {
                        indexedTracks.append((index, track))
                    }
                }
            }
        }

        let detailedTracks = indexedTracks.sorted { $0.0 < $1.0 }.map(\.1)

        guard !detailedTracks.isEmpty else {
            throw CloudScrobbleError.invalidResponse
        }

        return detailedTracks
    }

    private func rankedFeedbackTracks(_ tracks: [SCTrack]) -> [SCTrack] {
        feedback.ranked(
            Self.uniqueTracks(tracks),
            trackKey: { TrackIdentity.canonicalKey(for: $0) },
            artistKey: Self.artistKey(for:)
        )
    }

    private func rankedDiverseTracks(_ tracks: [SCTrack], limit: Int, maxPerArtist: Int) -> [SCTrack] {
        Self.diverseTracks(rankedFeedbackTracks(tracks), limit: limit, maxPerArtist: maxPerArtist)
    }

    private func rebuildVisibleHomeAfterFeedback(persist: Bool = true) {
        myTracks = rankedFeedbackTracks(sourceMyTracks)
        feedTracks = rankedDiverseTracks(
            sourceFeedTracks,
            limit: sourceFeedTracks.count,
            maxPerArtist: 2
        )
        followingTracks = rankedDiverseTracks(
            sourceFollowingTracks,
            limit: sourceFollowingTracks.count,
            maxPerArtist: 2
        )
        likedTracks = rankedFeedbackTracks(sourceLikedTracks)
        recommendedTracks = rankedFeedbackTracks(sourceRecommendedTracks)

        let supplementalTracks = rankedFeedbackTracks(sourceSupplementalTracks)
        homeMixes = Self.buildHomeMixes(
            feedTracks: feedTracks,
            followingTracks: followingTracks,
            ownedTracks: myTracks,
            likedTracks: Self.uniqueTracks(likedTracks + supplementalTracks),
            playlistTracks: rankedFeedbackTracks(sourcePlaylistTracks),
            likedPlaylistTracks: rankedFeedbackTracks(sourceLikedPlaylistTracks),
            lastFMTasteTracks: rankedFeedbackTracks(sourceLastFMTasteTracks),
            recommendedTracks: recommendedTracks,
            username: me?.username
        ).map { mix in
            HomeMix(
                id: mix.id,
                title: mix.title,
                subtitle: mix.subtitle,
                tracks: rankedFeedbackTracks(mix.tracks),
                iconName: mix.iconName
            )
        }.filter { !$0.tracks.isEmpty }

        stationMixes = sourceStationMixes.map { mix in
            HomeMix(
                id: mix.id,
                title: mix.title,
                subtitle: mix.subtitle,
                tracks: rankedFeedbackTracks(mix.tracks),
                iconName: mix.iconName
            )
        }.filter { !$0.tracks.isEmpty }

        if persist {
            persistCachedHome()
        }
    }

    private static func buildHomeMixes(
        feedTracks: [SCTrack],
        followingTracks: [SCTrack],
        ownedTracks: [SCTrack] = [],
        likedTracks: [SCTrack],
        playlistTracks: [SCTrack] = [],
        likedPlaylistTracks: [SCTrack] = [],
        lastFMTasteTracks: [SCTrack] = [],
        recommendedTracks: [SCTrack] = [],
        username: String?
    ) -> [HomeMix] {
        let dailyDrops = diverseTracks(feedTracks + followingTracks, limit: 24, maxPerArtist: 2)
        let weeklyWave = diverseTracks(followingTracks + feedTracks, limit: 24, maxPerArtist: 2)
        let personalPool = uniqueTracks(
            ownedTracks
                + lastFMTasteTracks
                + likedTracks
                + playlistTracks
                + likedPlaylistTracks
                + recommendedTracks
                + feedTracks
                + followingTracks
        )
        guard !dailyDrops.isEmpty || !weeklyWave.isEmpty || !personalPool.isEmpty else {
            return []
        }

        var mixes: [HomeMix] = []
        var usedMixTrackKeys = Set<String>()

        if !lastFMTasteTracks.isEmpty {
            let tracks = consumeDiverseTracks(
                from: lastFMTasteTracks,
                limit: 32,
                maxPerArtist: 3,
                minimumFallbackCount: 10,
                usedKeys: &usedMixTrackKeys
            )
            mixes.append(HomeMix(
                id: "lastfm-taste",
                title: String(localized: "Last.fm Taste"),
                subtitle: String(localized: "\(tracks.count) tracks from scrobbles and top artists"),
                tracks: tracks,
                iconName: "music.note.list"
            ))
        }

        if !personalPool.isEmpty {
            let shuffledTracks = consumeDiverseTracks(
                from: weightedShuffleTracks(
                    lastFMTasteTracks: lastFMTasteTracks,
                    likedTracks: likedTracks,
                    ownedTracks: ownedTracks,
                    playlistTracks: playlistTracks,
                    likedPlaylistTracks: likedPlaylistTracks,
                    recommendedTracks: recommendedTracks,
                    feedTracks: feedTracks,
                    followingTracks: followingTracks
                ),
                limit: 36,
                maxPerArtist: 3,
                minimumFallbackCount: 12,
                usedKeys: &usedMixTrackKeys
            )
            mixes.append(HomeMix(
                id: "shuffle-feed",
                title: String(localized: "Shuffle Feed"),
                subtitle: String(localized: "\(shuffledTracks.count) tracks weighted by Last.fm, likes, and Start"),
                tracks: shuffledTracks,
                iconName: "shuffle"
            ))
        }

        if !dailyDrops.isEmpty {
            let tracks = consumeDiverseTracks(
                from: dailyDrops,
                limit: 24,
                maxPerArtist: 2,
                minimumFallbackCount: 8,
                usedKeys: &usedMixTrackKeys
            )
            mixes.append(HomeMix(
                id: "daily-drops",
                title: String(localized: "Daily Drops"),
                subtitle: username.map { String(localized: "New tracks from \($0)'s Start") }
                    ?? String(localized: "New SoundCloud tracks"),
                tracks: tracks,
                iconName: "sparkles"
            ))
        }

        if !weeklyWave.isEmpty {
            let tracks = consumeDiverseTracks(
                from: weeklyWave,
                limit: 24,
                maxPerArtist: 2,
                minimumFallbackCount: 8,
                usedKeys: &usedMixTrackKeys
            )
            mixes.append(HomeMix(
                id: "weekly-wave",
                title: String(localized: "Weekly Wave"),
                subtitle: String(localized: "\(tracks.count) tracks from your feed and follows"),
                tracks: tracks,
                iconName: "waveform"
            ))
        }

        if !personalPool.isEmpty {
            let mixCount = min(4, max(1, Int(ceil(Double(personalPool.count) / 12.0))))
            for index in 0..<mixCount {
                let offset = (index * max(4, personalPool.count / max(mixCount, 1))) % personalPool.count
                let rotated = Array(personalPool.dropFirst(offset)) + Array(personalPool.prefix(offset))
                let tracks = consumeDiverseTracks(
                    from: rotated,
                    limit: 24,
                    maxPerArtist: 2,
                    minimumFallbackCount: 6,
                    usedKeys: &usedMixTrackKeys
                )
                guard !tracks.isEmpty else { continue }

                mixes.append(HomeMix(
                    id: "mein-mix-\(index + 1)",
                    title: String(localized: "My Mix \(index + 1)"),
                    subtitle: String(localized: "\(tracks.count) tracks from Last.fm, likes, playlists, and Start"),
                    tracks: tracks,
                    iconName: index.isMultiple(of: 2) ? "sparkles" : "waveform"
                ))
            }
        }

        if mixes.isEmpty, !personalPool.isEmpty {
            mixes.append(HomeMix(
                id: "start-fallback",
                title: String(localized: "More for you"),
                subtitle: String(localized: "\(min(personalPool.count, 24)) tracks from your SoundCloud library"),
                tracks: Array(personalPool.prefix(24)),
                iconName: "sparkles"
            ))
        }

        return mixes.filter { !$0.tracks.isEmpty }
    }

    private static func weightedShuffleTracks(
        lastFMTasteTracks: [SCTrack],
        likedTracks: [SCTrack],
        ownedTracks: [SCTrack],
        playlistTracks: [SCTrack],
        likedPlaylistTracks: [SCTrack],
        recommendedTracks: [SCTrack],
        feedTracks: [SCTrack],
        followingTracks: [SCTrack]
    ) -> [SCTrack] {
        FeedPersonalization.stableWeightedOrder(
            sources: [
                (items: lastFMTasteTracks, weight: 7),
                (items: likedTracks, weight: 3),
                (items: ownedTracks, weight: 2),
                (items: playlistTracks, weight: 2),
                (items: likedPlaylistTracks, weight: 2),
                (items: recommendedTracks, weight: 1),
                (items: feedTracks, weight: 1),
                (items: followingTracks, weight: 1)
            ],
            seed: FeedPersonalization.daySeed() + "|home-shuffle",
            key: { TrackIdentity.canonicalKey(for: $0) }
        )
    }

    private static func consumeDiverseTracks(
        from tracks: [SCTrack],
        limit: Int,
        maxPerArtist: Int,
        minimumFallbackCount: Int,
        usedKeys: inout Set<String>
    ) -> [SCTrack] {
        let unique = uniqueTracks(tracks)
        var selected = diverseTracks(
            unique.filter { !usedKeys.contains(TrackIdentity.canonicalKey(for: $0)) },
            limit: limit,
            maxPerArtist: maxPerArtist
        )

        if selected.count < minimumFallbackCount {
            let selectedKeys = Set(selected.map { TrackIdentity.canonicalKey(for: $0) })
            let unusedFallback = diverseTracks(
                unique.filter {
                    let key = TrackIdentity.canonicalKey(for: $0)
                    return !usedKeys.contains(key) && !selectedKeys.contains(key)
                },
                limit: limit - selected.count,
                maxPerArtist: maxPerArtist
            )
            selected.append(contentsOf: unusedFallback)
        }

        if selected.count < minimumFallbackCount {
            let selectedKeys = Set(selected.map { TrackIdentity.canonicalKey(for: $0) })
            let unavoidableOverlap = diverseTracks(
                unique.filter { !selectedKeys.contains(TrackIdentity.canonicalKey(for: $0)) },
                limit: limit - selected.count,
                maxPerArtist: maxPerArtist
            )
            selected.append(contentsOf: unavoidableOverlap)
        }

        selected.prefix(limit).forEach { usedKeys.insert(TrackIdentity.canonicalKey(for: $0)) }
        return Array(selected.prefix(limit))
    }

    private static func diverseTracks(_ tracks: [SCTrack], limit: Int, maxPerArtist: Int) -> [SCTrack] {
        guard limit > 0 else { return [] }

        let unique = uniqueTracks(tracks)
        var selected: [SCTrack] = []
        var artistCounts: [String: Int] = [:]

        for track in unique {
            let artistKey = TrackIdentity.displayMetadata(for: track).artist
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
                .lowercased()
            guard artistCounts[artistKey, default: 0] < maxPerArtist else {
                continue
            }

            selected.append(track)
            artistCounts[artistKey, default: 0] += 1
            if selected.count == limit { return selected }
        }

        if selected.count < limit {
            let selectedKeys = Set(selected.map { TrackIdentity.canonicalKey(for: $0) })
            selected.append(contentsOf: unique.filter { !selectedKeys.contains(TrackIdentity.canonicalKey(for: $0)) }.prefix(limit - selected.count))
        }

        return selected
    }

    private static func uniqueTracks(_ tracks: [SCTrack]) -> [SCTrack] {
        TrackIdentity.uniqueTracks(tracks)
    }

    private static func artistKey(for track: SCTrack) -> String {
        TrackIdentity.displayMetadata(for: track).artist
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func loadFeedFeedback() -> FeedPersonalization {
        if let data = UserDefaults.standard.data(forKey: Storage.feedFeedbackKey),
           let decoded = try? JSONDecoder().decode(FeedPersonalization.self, from: data) {
            return decoded
        }

        guard let legacyData = UserDefaults.standard.data(forKey: Storage.legacyFeedFeedbackKey),
              let legacy = try? JSONDecoder().decode(LegacyFeedFeedback.self, from: legacyData) else {
            return FeedPersonalization()
        }

        var scores = Dictionary(uniqueKeysWithValues: legacy.mutedArtistKeys.map { ($0, -2) })
        legacy.boostedArtistKeys.forEach { scores[$0] = 2 }
        return FeedPersonalization(hiddenTrackKeys: legacy.hiddenTrackKeys, artistScores: scores)
    }

    private func persistFeedFeedback() {
        guard let data = try? JSONEncoder().encode(feedback) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Storage.feedFeedbackKey)
        UserDefaults.standard.removeObject(forKey: Storage.legacyFeedFeedbackKey)
    }

    private func restoreCachedHome() {
        guard let data = UserDefaults.standard.data(forKey: Storage.cachedHomeKey),
              let cached = try? JSONDecoder().decode(CachedHome.self, from: data) else {
            return
        }

        me = cached.me
        sourceMyTracks = cached.myTracks
        sourceFeedTracks = cached.feedTracks
        sourceFollowingTracks = cached.followingTracks
        sourceRecommendedTracks = cached.recommendedTracks
        homePlaylists = cached.homePlaylists
        sourceLikedTracks = cached.likedTracks
        likedPlaylists = cached.likedPlaylists
        sourceStationMixes = Self.buildFallbackStationMixes(
            from: cached.feedTracks + cached.followingTracks + cached.myTracks + cached.likedTracks + cached.recommendedTracks
        )
        rebuildVisibleHomeAfterFeedback(persist: false)
    }

    private func persistCachedHome() {
        let cached = CachedHome(
            me: me,
            myTracks: sourceMyTracks,
            feedTracks: sourceFeedTracks,
            followingTracks: sourceFollowingTracks,
            recommendedTracks: sourceRecommendedTracks,
            homePlaylists: homePlaylists,
            likedTracks: sourceLikedTracks,
            likedPlaylists: likedPlaylists
        )
        guard let data = try? JSONEncoder().encode(cached) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Storage.cachedHomeKey)
    }
}
