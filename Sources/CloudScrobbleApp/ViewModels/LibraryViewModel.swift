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

    init(session: AppSessionViewModel) {
        self.session = session
        restoreCachedLibrary()
    }

    func refresh() async {
        guard let session else {
            errorMessage = "App session unavailable"
            return
        }

        guard let api = session.apiClient else {
            errorMessage = hasLibraryContent
                ? "Showing cached library. Connect SoundCloud to refresh."
                : "Connect SoundCloud first"
            return
        }
        if session.soundCloudPublicMode && !session.soundCloudMockMode {
            me = nil
            myTracks = []
            myPlaylists = []
            myLikedTracks = []
            myLikedPlaylists = []
            smartMixes = []
            stationMixes = []
            selectedPlaylist = nil
            selectedMix = nil
            errorMessage = "Public Mode has no private /me library. Use full SoundCloud login for this tab."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            async let meTask = api.me()
            async let playlistsTask = api.myPlaylists(limit: 50, nextHref: nil)
            async let likedTracksTask = api.myLikedTracks(limit: 50, nextHref: nil)
            async let likedPlaylistsTask = api.myLikedPlaylists(limit: 50, nextHref: nil)

            let playlistsPage = try await playlistsTask
            let likedTracksPage = try await likedTracksTask
            let likedPlaylistsPage = try await likedPlaylistsTask

            let profile = try await meTask
            let tracksPage = try? await api.userTracks(urn: profile.urn, limit: 50, nextHref: nil)
            let ownedTracks = tracksPage?.collection ?? []
            let lastFMTasteTracks = await session.lastFMTasteTracks(api: api, maxTracks: 72)
            let libraryTracks = Self.uniqueTracks(lastFMTasteTracks + ownedTracks + likedTracksPage.collection)

            me = profile
            myTracks = ownedTracks
            myPlaylists = playlistsPage.collection
            myLikedTracks = likedTracksPage.collection
            myLikedPlaylists = likedPlaylistsPage.collection
            smartMixes = Self.buildSmartMixes(from: libraryTracks, lastFMTasteTracks: lastFMTasteTracks)
            stationMixes = await buildRelatedStations(from: libraryTracks, api: api)
            persistCachedLibrary()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func play(track: SCTrack) async {
        guard let session else {
            errorMessage = "App session unavailable"
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
            errorMessage = "App session unavailable"
            return
        }

        await session.playNext(track: track)
    }

    func addToQueue(track: SCTrack) async {
        guard let session else {
            errorMessage = "App session unavailable"
            return
        }

        await session.addToQueue(track: track)
    }

    func play(mix: SmartMix) async {
        guard let session else {
            errorMessage = "App session unavailable"
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
            errorMessage = "App session unavailable"
            return
        }

        await session.play(savedTrack: savedTrack)
    }

    func open(playlist: SCPlaylist) async {
        guard let session else {
            errorMessage = "Connect SoundCloud first"
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
            errorMessage = "Connect SoundCloud first"
            return
        }

        isLoadingPlaylist = true
        defer { isLoadingPlaylist = false }

        await session.playPlaylist(playlist)
        errorMessage = nil
    }

    func playSelectedPlaylist() async {
        guard let session else {
            errorMessage = "App session unavailable"
            return
        }
        guard let selectedPlaylist else {
            errorMessage = "No playlist selected"
            return
        }

        await session.playPlaylist(tracks: selectedPlaylist.tracks, startAt: 0)
    }

    func playSelectedPlaylist(startingWith track: SCTrack) async {
        guard let session else {
            errorMessage = "App session unavailable"
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
            errorMessage = "No mix selected"
            return
        }

        await play(mix: selectedMix)
    }

    func playSelectedMix(startingWith track: SCTrack) async {
        guard let session else {
            errorMessage = "App session unavailable"
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

        let shuffledTracks = Array(weightedShuffleTracks(
            lastFMTasteTracks: lastFMTasteTracks,
            libraryTracks: uniqueTracks
        ).prefix(50))
        var mixes: [SmartMix] = []

        if !lastFMTasteTracks.isEmpty {
            mixes.append(
                SmartMix(
                    id: "lastfm-taste",
                    title: "Last.fm Taste",
                    subtitle: "\(min(lastFMTasteTracks.count, 50)) Tracks aus Scrobbles und Top-Artists",
                    tracks: Array(lastFMTasteTracks.prefix(50)),
                    iconName: "music.note.list"
                )
            )
        }

        mixes.append(contentsOf: [
            SmartMix(
                id: "library-shuffle",
                title: "Likes Shuffle",
                subtitle: "\(shuffledTracks.count) Tracks stark gewichtet nach Last.fm und Likes",
                tracks: shuffledTracks,
                iconName: "shuffle"
            ),
            SmartMix(
                id: "daily-drops",
                title: "Daily Drops",
                subtitle: "\(min(uniqueTracks.count, 12)) tracks from your likes",
                tracks: Array(uniqueTracks.prefix(12)),
                iconName: "sparkles"
            )
        ])

        let mixCount = min(4, max(1, uniqueTracks.count))
        for offset in 0..<mixCount {
            let rotated = Array(uniqueTracks[offset...]) + Array(uniqueTracks[..<offset])
            mixes.append(
                SmartMix(
                    id: "your-mix-\(offset + 1)",
                    title: "Your Mix \(offset + 1)",
                    subtitle: "\(min(rotated.count, 12)) tracks tuned from your library",
                    tracks: Array(rotated.prefix(12)),
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
        let weightedTracks = repeated(lastFMTasteTracks, times: 7) + repeated(libraryTracks, times: 2)
        return uniqueTracks(weightedTracks.shuffled())
    }

    private static func repeated(_ tracks: [SCTrack], times: Int) -> [SCTrack] {
        guard times > 1 else { return tracks }
        return (0..<times).flatMap { _ in tracks }
    }

    private func buildRelatedStations(from tracks: [SCTrack], api: SoundCloudAPIClienting) async -> [SmartMix] {
        var stations: [SmartMix] = []
        var usedTracks = Set<String>()

        for seed in Self.uniqueTracks(tracks).prefix(6) {
            guard stations.count < 5 else { break }
            guard let page = try? await api.relatedTracks(trackURN: seed.urn, limit: 25, nextHref: nil) else {
                continue
            }

            let stationTracks = Self.uniqueTracks([seed] + page.collection)
                .filter { track in
                    if track.id == seed.id { return true }
                    return !usedTracks.contains(track.id)
                }
            guard stationTracks.count >= 2 else { continue }

            stationTracks.prefix(24).forEach { usedTracks.insert($0.id) }
            stations.append(
                SmartMix(
                    id: "station-\(seed.id)",
                    title: "\(seed.user.username) Sender",
                    subtitle: "Radio aus \(seed.title)",
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
                title: "\(seed.user.username) Sender",
                subtitle: "Radio aus \(seed.title)",
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
