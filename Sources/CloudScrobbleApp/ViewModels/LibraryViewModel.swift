import CloudScrobbleCore
import Foundation

@MainActor
final class LibraryViewModel: ObservableObject {
    private enum Storage {
        static let cachedLibraryKey = "cloudscrobble.cachedLibrary.v2"
    }

    private struct CachedLibrary: Codable {
        let me: SCUser?
        let myTracks: [SCTrack]
        let myPlaylists: [SCPlaylist]
        let myLikedTracks: [SCTrack]
        let myLikedPlaylists: [SCPlaylist]
    }

    struct SmartMix: Identifiable {
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
    @Published private(set) var myPlaylists: [SCPlaylist] = []
    @Published private(set) var myLikedTracks: [SCTrack] = []
    @Published private(set) var myLikedPlaylists: [SCPlaylist] = []
    @Published private(set) var smartMixes: [SmartMix] = []
    @Published private(set) var stationMixes: [SmartMix] = []
    @Published private(set) var selectedPlaylist: PlaylistTracksData?
    @Published private(set) var selectedMix: SmartMix?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingPlaylist = false
    @Published private(set) var errorMessage: String?

    private weak var session: AppSessionViewModel?
    private var refreshGeneration = UUID()

    init(session: AppSessionViewModel) {
        self.session = session
        restoreCachedLibrary()
    }

    func refresh() async {
        let generation = UUID()
        refreshGeneration = generation

        guard let session else {
            isLoading = false
            errorMessage = String(localized: "App session unavailable")
            return
        }

        guard let api = session.apiClient else {
            isLoading = false
            errorMessage = hasLibraryContent
                ? String(localized: "Showing cached library. Connect SoundCloud to refresh.")
                : String(localized: "Connect SoundCloud first")
            return
        }
        if session.soundCloudPublicMode && !session.soundCloudMockMode {
            isLoading = false
            me = nil
            myTracks = []
            myPlaylists = []
            myLikedTracks = []
            myLikedPlaylists = []
            smartMixes = []
            stationMixes = []
            selectedPlaylist = nil
            selectedMix = nil
            errorMessage = String(localized: "Public Mode has no private library. Use full SoundCloud login for this tab.")
            return
        }

        isLoading = true
        defer {
            if refreshGeneration == generation {
                isLoading = false
            }
        }

        do {
            async let meTask = api.me()
            async let playlistsTask = api.myPlaylists(limit: 50, nextHref: nil)
            async let likedTracksTask = api.myLikedTracks(limit: 50, nextHref: nil)
            async let likedPlaylistsTask = api.myLikedPlaylists(limit: 50, nextHref: nil)

            let (profile, playlistsPage, likedTracksPage, likedPlaylistsPage) = try await (
                meTask,
                playlistsTask,
                likedTracksTask,
                likedPlaylistsTask
            )
            guard isCurrentRefresh(generation) else { return }
            let tracksPage = try? await api.userTracks(urn: profile.urn, limit: 50, nextHref: nil)
            let ownedTracks = tracksPage?.collection ?? []
            let lastFMTasteTracks = await session.lastFMTasteTracks(api: api, maxTracks: 72)
            let libraryTracks = Self.uniqueTracks(lastFMTasteTracks + ownedTracks + likedTracksPage.collection)
            let relatedStations = await buildRelatedStations(from: libraryTracks, api: api)
            guard isCurrentRefresh(generation) else { return }

            me = profile
            myTracks = ownedTracks
            myPlaylists = playlistsPage.collection
            myLikedTracks = likedTracksPage.collection
            myLikedPlaylists = likedPlaylistsPage.collection
            smartMixes = Self.buildSmartMixes(from: libraryTracks, lastFMTasteTracks: lastFMTasteTracks)
            stationMixes = relatedStations
            persistCachedLibrary()
            errorMessage = nil
        } catch {
            if isCurrentRefresh(generation) {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func isCurrentRefresh(_ generation: UUID) -> Bool {
        !Task.isCancelled && refreshGeneration == generation
    }

    func play(track: SCTrack) async {
        guard let session else {
            errorMessage = String(localized: "App session unavailable")
            return
        }

        let context = myLikedTracks.isEmpty ? [track] : myLikedTracks
        guard let startIndex = context.firstIndex(where: { $0.id == track.id }) else {
            await session.play(track: track)
            return
        }

        await session.play(tracks: context, startAt: startIndex)
    }

    func playNext(track: SCTrack) async {
        guard let session else {
            errorMessage = String(localized: "App session unavailable")
            return
        }

        await session.playNext(track: track)
    }

    func addToQueue(track: SCTrack) async {
        guard let session else {
            errorMessage = String(localized: "App session unavailable")
            return
        }

        await session.addToQueue(track: track)
    }

    func play(mix: SmartMix) async {
        guard let session else {
            errorMessage = String(localized: "App session unavailable")
            return
        }

        await session.playPlaylist(tracks: mix.tracks, startAt: 0)
    }

    func open(mix: SmartMix) {
        selectedPlaylist = nil
        selectedMix = mix
        errorMessage = nil
    }

    func play(savedTrack: SavedPlaybackTrack) async {
        guard let session else {
            errorMessage = String(localized: "App session unavailable")
            return
        }

        await session.play(savedTrack: savedTrack)
    }

    func open(playlist: SCPlaylist) async {
        guard let session else {
            errorMessage = String(localized: "Connect SoundCloud first")
            return
        }

        isLoadingPlaylist = true
        defer { isLoadingPlaylist = false }

        do {
            let tracks = try await session.loadPlaylistTracks(for: playlist)
            selectedMix = nil
            selectedPlaylist = PlaylistTracksData(playlist: playlist, tracks: tracks)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func play(playlist: SCPlaylist) async {
        guard let session else {
            errorMessage = String(localized: "Connect SoundCloud first")
            return
        }

        isLoadingPlaylist = true
        defer { isLoadingPlaylist = false }

        await session.playPlaylist(playlist)
        errorMessage = nil
    }

    func playSelectedPlaylist() async {
        guard let session else {
            errorMessage = String(localized: "App session unavailable")
            return
        }
        guard let selectedPlaylist else {
            errorMessage = String(localized: "No playlist selected")
            return
        }

        await session.playPlaylist(tracks: selectedPlaylist.tracks, startAt: 0)
    }

    func playSelectedPlaylist(startingWith track: SCTrack) async {
        guard let session else {
            errorMessage = String(localized: "App session unavailable")
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
            errorMessage = String(localized: "No mix selected")
            return
        }

        await play(mix: selectedMix)
    }

    func playSelectedMix(startingWith track: SCTrack) async {
        guard let session else {
            errorMessage = String(localized: "App session unavailable")
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

    private var hasLibraryContent: Bool {
        !myTracks.isEmpty || !myPlaylists.isEmpty || !myLikedTracks.isEmpty || !myLikedPlaylists.isEmpty || !stationMixes.isEmpty
    }

    private static func buildSmartMixes(from tracks: [SCTrack], lastFMTasteTracks: [SCTrack] = []) -> [SmartMix] {
        let uniqueTracks = Self.uniqueTracks(tracks)

        guard !uniqueTracks.isEmpty else { return [] }

        let shuffledPool = weightedShuffleTracks(
            lastFMTasteTracks: lastFMTasteTracks,
            libraryTracks: uniqueTracks
        )
        let dailyPool = FeedPersonalization.stableWeightedOrder(
            sources: [(items: uniqueTracks, weight: 1)],
            seed: FeedPersonalization.daySeed() + "|library-daily",
            key: { TrackIdentity.canonicalKey(for: $0) }
        )
        var mixes: [SmartMix] = []
        var usedTrackKeys = Set<String>()

        if !lastFMTasteTracks.isEmpty {
            let tasteTracks = consumeMixTracks(
                from: lastFMTasteTracks,
                limit: 24,
                minimumFallbackCount: 8,
                usedKeys: &usedTrackKeys
            )
            if !tasteTracks.isEmpty {
                mixes.append(
                    SmartMix(
                        id: "lastfm-taste",
                        title: String(localized: "Last.fm Taste"),
                        subtitle: String(localized: "\(tasteTracks.count) tracks from scrobbles and top artists"),
                        tracks: tasteTracks,
                        iconName: "music.note.list"
                    )
                )
            }
        }

        let shuffledTracks = consumeMixTracks(
            from: shuffledPool,
            limit: 36,
            minimumFallbackCount: 10,
            usedKeys: &usedTrackKeys
        )
        if !shuffledTracks.isEmpty {
            mixes.append(
                SmartMix(
                    id: "library-shuffle",
                    title: String(localized: "Likes Shuffle"),
                    subtitle: String(localized: "\(shuffledTracks.count) tracks weighted heavily by Last.fm and likes"),
                    tracks: shuffledTracks,
                    iconName: "shuffle"
                )
            )
        }

        let dailyTracks = consumeMixTracks(
            from: dailyPool,
            limit: 12,
            minimumFallbackCount: 6,
            usedKeys: &usedTrackKeys
        )
        if !dailyTracks.isEmpty {
            mixes.append(
                SmartMix(
                    id: "daily-drops",
                    title: String(localized: "Daily Drops"),
                    subtitle: String(localized: "\(dailyTracks.count) tracks from your likes"),
                    tracks: dailyTracks,
                    iconName: "sparkles"
                )
            )
        }

        let mixCount = min(4, max(1, Int(ceil(Double(uniqueTracks.count) / 12.0))))
        for offset in 0..<mixCount {
            let startIndex = (offset * max(1, uniqueTracks.count / mixCount)) % uniqueTracks.count
            let rotated = Array(uniqueTracks.dropFirst(startIndex)) + Array(uniqueTracks.prefix(startIndex))
            let mixTracks = consumeMixTracks(
                from: rotated,
                limit: 12,
                minimumFallbackCount: 4,
                usedKeys: &usedTrackKeys
            )
            guard !mixTracks.isEmpty else { continue }
            mixes.append(
                SmartMix(
                    id: "your-mix-\(offset + 1)",
                    title: String(localized: "Your Mix \(offset + 1)"),
                    subtitle: String(localized: "\(mixTracks.count) tracks tuned from your library"),
                    tracks: mixTracks,
                    iconName: offset.isMultiple(of: 2) ? "waveform" : "dot.radiowaves.left.and.right"
                )
            )
        }

        return mixes
    }

    private static func weightedShuffleTracks(
        lastFMTasteTracks: [SCTrack],
        libraryTracks: [SCTrack]
    ) -> [SCTrack] {
        FeedPersonalization.stableWeightedOrder(
            sources: [
                (items: lastFMTasteTracks, weight: 7),
                (items: libraryTracks, weight: 2)
            ],
            seed: FeedPersonalization.daySeed() + "|library-shuffle",
            key: { TrackIdentity.canonicalKey(for: $0) }
        )
    }

    private static func consumeMixTracks(
        from tracks: [SCTrack],
        limit: Int,
        minimumFallbackCount: Int,
        usedKeys: inout Set<String>
    ) -> [SCTrack] {
        let unique = uniqueTracks(tracks)
        var selected = Array(unique.filter {
            !usedKeys.contains(TrackIdentity.canonicalKey(for: $0))
        }.prefix(limit))

        if selected.count < minimumFallbackCount {
            let selectedKeys = Set(selected.map { TrackIdentity.canonicalKey(for: $0) })
            selected.append(contentsOf: unique.filter {
                !selectedKeys.contains(TrackIdentity.canonicalKey(for: $0))
            }.prefix(limit - selected.count))
        }

        selected.forEach { usedKeys.insert(TrackIdentity.canonicalKey(for: $0)) }
        return selected
    }

    private func buildRelatedStations(from tracks: [SCTrack], api: SoundCloudAPIClienting) async -> [SmartMix] {
        let seeds = Array(Self.uniqueTracks(tracks).prefix(6))
        var relatedResults: [(Int, SCTrack, [SCTrack])] = []

        for batchStart in stride(from: 0, to: seeds.count, by: 3) {
            let batchEnd = min(batchStart + 3, seeds.count)
            await withTaskGroup(of: (Int, SCTrack, [SCTrack]).self) { group in
                for index in batchStart..<batchEnd {
                    let seed = seeds[index]
                    group.addTask {
                        let page = try? await api.relatedTracks(trackURN: seed.urn, limit: 25, nextHref: nil)
                        return (index, seed, page?.collection ?? [])
                    }
                }

                for await result in group {
                    relatedResults.append(result)
                }
            }
        }

        var stations: [SmartMix] = []
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
                SmartMix(
                    id: "station-\(seed.id)",
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

        return Self.buildFallbackStations(from: tracks)
    }

    private static func buildFallbackStations(from tracks: [SCTrack]) -> [SmartMix] {
        let dedupedTracks = uniqueTracks(tracks)
        guard !dedupedTracks.isEmpty else { return [] }

        return dedupedTracks.prefix(4).enumerated().map { index, seed in
            let rotated = Array(dedupedTracks.dropFirst(index)) + Array(dedupedTracks.prefix(index))
            return SmartMix(
                id: "fallback-station-\(seed.id)",
                title: String(localized: "\(seed.user.username) Station"),
                subtitle: String(localized: "Radio based on \(seed.title)"),
                tracks: Array(rotated.prefix(20)),
                iconName: "dot.radiowaves.left.and.right"
            )
        }
    }

    private static func uniqueTracks(_ tracks: [SCTrack]) -> [SCTrack] {
        TrackIdentity.uniqueTracks(tracks)
    }

    private func restoreCachedLibrary() {
        guard let data = UserDefaults.standard.data(forKey: Storage.cachedLibraryKey),
              let cached = try? JSONDecoder().decode(CachedLibrary.self, from: data) else {
            return
        }

        me = cached.me
        myTracks = cached.myTracks
        myPlaylists = cached.myPlaylists
        myLikedTracks = cached.myLikedTracks
        myLikedPlaylists = cached.myLikedPlaylists
        let libraryTracks = Self.uniqueTracks(cached.myTracks + cached.myLikedTracks)
        smartMixes = Self.buildSmartMixes(from: libraryTracks)
        stationMixes = Self.buildFallbackStations(from: libraryTracks)
    }

    private func persistCachedLibrary() {
        let cached = CachedLibrary(
            me: me,
            myTracks: myTracks,
            myPlaylists: myPlaylists,
            myLikedTracks: myLikedTracks,
            myLikedPlaylists: myLikedPlaylists
        )
        guard let data = try? JSONEncoder().encode(cached) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Storage.cachedLibraryKey)
    }
}
