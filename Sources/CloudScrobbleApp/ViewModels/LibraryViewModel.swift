import CloudScrobbleCore
import Foundation

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var me: SCUser?
    @Published private(set) var myPlaylists: [SCPlaylist] = []
    @Published private(set) var myLikedTracks: [SCTrack] = []
    @Published private(set) var myLikedPlaylists: [SCPlaylist] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private unowned let session: AppSessionViewModel

    init(session: AppSessionViewModel) {
        self.session = session
    }

    func refresh() async {
        guard let api = session.apiClient else {
            errorMessage = "Connect SoundCloud first"
            return
        }
        if session.soundCloudPublicMode {
            me = nil
            myPlaylists = []
            myLikedTracks = []
            myLikedPlaylists = []
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
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func play(track: SCTrack) async {
        await session.play(track: track)
    }
}
