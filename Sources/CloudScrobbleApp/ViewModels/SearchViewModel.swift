import CloudScrobbleCore
import Foundation

@MainActor
final class SearchViewModel: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case tracks = "Tracks"
        case playlists = "Playlists"
        case users = "Users"

        var id: String { rawValue }
    }

    @Published var query = ""
    @Published var scope: Scope = .tracks
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingNextPage = false
    @Published private(set) var hasPerformedSearch = false
    @Published private(set) var errorMessage: String?

    @Published private(set) var tracks: [SCTrack] = []
    @Published private(set) var playlists: [SCPlaylist] = []
    @Published private(set) var users: [SCUser] = []

    @Published private(set) var selectedUserProfile: UserProfileData?
    @Published private(set) var selectedPlaylistTracks: [SCTrack] = []

    private var tracksNextHref: URL?
    private var playlistsNextHref: URL?
    private var usersNextHref: URL?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()

    private weak var session: AppSessionViewModel?

    struct UserProfileData {
        let user: SCUser
        let tracks: [SCTrack]
        let playlists: [SCPlaylist]
    }

    init(session: AppSessionViewModel) {
        self.session = session
    }

    deinit {
        searchTask?.cancel()
    }

    func scheduleSearch(immediate: Bool = false) {
        searchTask?.cancel()
        searchGeneration = UUID()
        isLoading = false
        isLoadingNextPage = false

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearResults()
            errorMessage = nil
            return
        }

        guard trimmed.count >= 2 else {
            clearResults()
            errorMessage = nil
            return
        }

        let delay: UInt64 = immediate ? 0 : 420_000_000
        searchTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.runSearch(reset: true)
        }
    }

    func runSearch(reset: Bool = true) async {
        guard let session else {
            errorMessage = String(localized: "App session unavailable")
            return
        }

        guard let api = session.apiClient else {
            errorMessage = String(localized: "Connect SoundCloud first")
            return
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearResults()
            return
        }

        let requestedScope = scope
        let generation: UUID
        if reset {
            generation = UUID()
            searchGeneration = generation
            hasPerformedSearch = true
            isLoading = true
        } else {
            generation = searchGeneration
            guard !isLoadingNextPage else { return }
            isLoadingNextPage = true
        }
        defer {
            if searchGeneration == generation {
                if reset {
                    isLoading = false
                } else {
                    isLoadingNextPage = false
                }
            }
        }

        do {
            switch requestedScope {
            case .tracks:
                let page = try await api.searchTracks(
                    query: trimmed,
                    limit: 25,
                    nextHref: reset ? nil : tracksNextHref
                )
                guard requestIsCurrent(query: trimmed, scope: requestedScope, generation: generation) else { return }
                tracks = reset ? page.collection : Self.uniqueByID(tracks + page.collection)
                tracksNextHref = page.nextHref
            case .playlists:
                let page = try await api.searchPlaylists(
                    query: trimmed,
                    limit: 25,
                    nextHref: reset ? nil : playlistsNextHref
                )
                guard requestIsCurrent(query: trimmed, scope: requestedScope, generation: generation) else { return }
                playlists = reset ? page.collection : Self.uniqueByID(playlists + page.collection)
                playlistsNextHref = page.nextHref
            case .users:
                let page = try await api.searchUsers(
                    query: trimmed,
                    limit: 25,
                    nextHref: reset ? nil : usersNextHref
                )
                guard requestIsCurrent(query: trimmed, scope: requestedScope, generation: generation) else { return }
                users = reset ? page.collection : Self.uniqueByID(users + page.collection)
                usersNextHref = page.nextHref
            }

            guard requestIsCurrent(query: trimmed, scope: requestedScope, generation: generation) else { return }
            errorMessage = nil
        } catch {
            guard !Task.isCancelled,
                  requestIsCurrent(query: trimmed, scope: requestedScope, generation: generation) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreIfNeeded(currentItemID: String) async {
        guard !isLoading, !isLoadingNextPage else { return }
        switch scope {
        case .tracks:
            guard tracks.last?.id == currentItemID, tracksNextHref != nil else { return }
        case .playlists:
            guard playlists.last?.id == currentItemID, playlistsNextHref != nil else { return }
        case .users:
            guard users.last?.id == currentItemID, usersNextHref != nil else { return }
        }

        await runSearch(reset: false)
    }

    func play(track: SCTrack) async {
        guard let session else {
            errorMessage = String(localized: "App session unavailable")
            return
        }

        let contextTracks = playbackContext(for: track)
        guard let startIndex = contextTracks.firstIndex(where: { $0.id == track.id }) else {
            await session.play(track: track)
            return
        }

        await session.play(tracks: contextTracks, startAt: startIndex)
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

    func open(playlist: SCPlaylist) async {
        guard let session else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            selectedPlaylistTracks = try await session.loadPlaylistTracks(for: playlist)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func playSelectedPlaylist() async {
        guard let session else {
            errorMessage = String(localized: "App session unavailable")
            return
        }

        await session.playPlaylist(tracks: selectedPlaylistTracks, startAt: 0)
    }

    func playSelectedPlaylist(startingWith track: SCTrack) async {
        guard let session else {
            errorMessage = String(localized: "App session unavailable")
            return
        }

        guard let startIndex = selectedPlaylistTracks.firstIndex(where: { $0.id == track.id }) else {
            await session.play(track: track)
            return
        }

        await session.playPlaylist(tracks: selectedPlaylistTracks, startAt: startIndex)
    }

    func open(user: SCUser) async {
        guard let session, let api = session.apiClient else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            async let tracks = api.userTracks(urn: user.urn, limit: 25, nextHref: nil)
            async let playlists = api.userPlaylists(urn: user.urn, limit: 25, nextHref: nil)
            let tracksPage = try await tracks
            let playlistsPage = try await playlists

            let profile = UserProfileData(
                user: user,
                tracks: tracksPage.collection,
                playlists: playlistsPage.collection
            )
            selectedUserProfile = profile
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func closeUserProfile() {
        selectedUserProfile = nil
    }

    func clearPlaylistSelection() {
        selectedPlaylistTracks = []
    }

    private func playbackContext(for track: SCTrack) -> [SCTrack] {
        switch scope {
        case .tracks:
            return tracks.isEmpty ? [track] : tracks
        case .playlists:
            return selectedPlaylistTracks.isEmpty ? [track] : selectedPlaylistTracks
        case .users:
            return [track]
        }
    }

    private func clearResults() {
        tracks = []
        playlists = []
        users = []
        selectedPlaylistTracks = []
        selectedUserProfile = nil
        tracksNextHref = nil
        playlistsNextHref = nil
        usersNextHref = nil
        hasPerformedSearch = false
        isLoadingNextPage = false
    }

    private func requestIsCurrent(query requestedQuery: String, scope requestedScope: Scope, generation: UUID) -> Bool {
        searchGeneration == generation
            && scope == requestedScope
            && query.trimmingCharacters(in: .whitespacesAndNewlines) == requestedQuery
    }

    private static func uniqueByID<T: Identifiable>(_ values: [T]) -> [T] where T.ID: Hashable {
        var seen = Set<T.ID>()
        return values.filter { seen.insert($0.id).inserted }
    }
}
