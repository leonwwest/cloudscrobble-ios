import CloudScrobbleCore
import Foundation

@MainActor
final class LibraryViewModel: ObservableObject {
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
    @Published private(set) var myPlaylists: [SCPlaylist] = []
    @Published private(set) var myLikedTracks: [SCTrack] = []
    @Published private(set) var myLikedPlaylists: [SCPlaylist] = []
    @Published private(set) var smartMixes: [SmartMix] = []
    @Published private(set) var selectedPlaylist: PlaylistTracksData?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingPlaylist = false
    @Published private(set) var errorMessage: String?

    private weak var session: AppSessionViewModel?

    init(session: AppSessionViewModel) {
        self.session = session
    }

    func refresh() async {
        guard let session else {
            errorMessage = "App session unavailable"
            return
        }

        guard let api = session.apiClient else {
            errorMessage = "Connect SoundCloud first"
            return
        }
        if session.soundCloudPublicMode && !session.soundCloudMockMode {
            me = nil
            myPlaylists = []
            myLikedTracks = []
            myLikedPlaylists = []
            smartMixes = []
            selectedPlaylist = nil
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

            me = try await meTask
            myPlaylists = playlistsPage.collection
            myLikedTracks = likedTracksPage.collection
            myLikedPlaylists = likedPlaylistsPage.collection
            smartMixes = Self.buildSmartMixes(from: likedTracksPage.collection)
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

    func play(mix: SmartMix) async {
        guard let session else {
            errorMessage = "App session unavailable"
            return
        }

        await session.play(tracks: mix.tracks, startAt: 0)
    }

    func open(playlist: SCPlaylist) async {
        guard let session, let api = session.apiClient else {
            errorMessage = "Connect SoundCloud first"
            return
        }

        isLoadingPlaylist = true
        defer { isLoadingPlaylist = false }

        do {
            let tracks = try await loadTracks(for: playlist, api: api)
            selectedPlaylist = PlaylistTracksData(playlist: playlist, tracks: tracks)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func play(playlist: SCPlaylist) async {
        guard let session, let api = session.apiClient else {
            errorMessage = "Connect SoundCloud first"
            return
        }

        isLoadingPlaylist = true
        defer { isLoadingPlaylist = false }

        do {
            let tracks = try await loadTracks(for: playlist, api: api)
            await session.play(tracks: tracks, startAt: 0)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
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

        await session.play(tracks: selectedPlaylist.tracks, startAt: 0)
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
        await session.play(tracks: selectedPlaylist.tracks, startAt: startIndex)
    }

    func clearPlaylistSelection() {
        selectedPlaylist = nil
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

    private static func buildSmartMixes(from tracks: [SCTrack]) -> [SmartMix] {
        let uniqueTracks = tracks.reduce(into: [SCTrack]()) { result, track in
            guard !result.contains(where: { $0.id == track.id }) else { return }
            result.append(track)
        }

        guard !uniqueTracks.isEmpty else { return [] }

        var mixes: [SmartMix] = [
            SmartMix(
                id: "daily-drops",
                title: "Daily Drops",
                subtitle: "\(min(uniqueTracks.count, 12)) tracks from your likes",
                tracks: Array(uniqueTracks.prefix(12)),
                iconName: "sparkles"
            )
        ]

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
}
