import CloudScrobbleCore
import SwiftUI

struct SearchView: View {
    @StateObject var viewModel: SearchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search tracks, playlists, users", text: $viewModel.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await viewModel.runSearch(reset: true) }
                    }

                Picker("Scope", selection: $viewModel.scope) {
                    ForEach(SearchViewModel.Scope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                Button("Search") {
                    Task { await viewModel.runSearch(reset: true) }
                }
                .buttonStyle(.borderedProminent)
            }

            if viewModel.isLoading {
                ProgressView()
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            contentList
        }
        .sheet(item: Binding(
            get: {
                viewModel.selectedUserProfile.map { profile in
                    UserProfileSheetModel(profile: profile)
                }
            },
            set: { _ in viewModel.closeUserProfile() }
        )) { model in
            UserProfileSheet(profile: model.profile, onPlayTrack: { track in
                Task { await viewModel.play(track: track) }
            })
        }
        .sheet(isPresented: Binding(
            get: { !viewModel.selectedPlaylistTracks.isEmpty },
            set: { isPresented in
                if !isPresented {
                    viewModel.clearPlaylistSelection()
                }
            }
        )) {
            PlaylistTracksSheet(
                tracks: viewModel.selectedPlaylistTracks,
                onPlayAll: {
                    Task { await viewModel.playSelectedPlaylist() }
                },
                onPlayTrack: { track in
                    Task { await viewModel.play(track: track) }
                }
            )
            .frame(minWidth: 480, minHeight: 360)
        }
    }

    @ViewBuilder
    private var contentList: some View {
        switch viewModel.scope {
        case .tracks:
            List(viewModel.tracks) { track in
                Button {
                    Task { await viewModel.play(track: track) }
                } label: {
                    VStack(alignment: .leading) {
                        Text(track.title)
                        Text(track.user.username)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .task {
                    await viewModel.loadMoreIfNeeded(currentItemID: track.id)
                }
            }
        case .playlists:
            List(viewModel.playlists) { playlist in
                HStack {
                    VStack(alignment: .leading) {
                        Text(playlist.title)
                        Text(playlist.user.username)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Open") {
                        Task { await viewModel.open(playlist: playlist) }
                    }
                    .buttonStyle(.bordered)
                }
                .task {
                    await viewModel.loadMoreIfNeeded(currentItemID: playlist.id)
                }
            }
        case .users:
            List(viewModel.users) { user in
                HStack {
                    Text(user.username)
                    Spacer()
                    Button("Profile") {
                        Task { await viewModel.open(user: user) }
                    }
                    .buttonStyle(.bordered)
                }
                .task {
                    await viewModel.loadMoreIfNeeded(currentItemID: user.id)
                }
            }
        }
    }
}

private struct UserProfileSheetModel: Identifiable {
    let profile: SearchViewModel.UserProfileData
    var id: String { profile.user.id }
}

private struct UserProfileSheet: View {
    let profile: SearchViewModel.UserProfileData
    let onPlayTrack: (SCTrack) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(profile.user.username)
                .font(.title3.bold())

            Text("Tracks")
                .font(.headline)

            List(profile.tracks.prefix(20)) { track in
                Button(track.title) {
                    onPlayTrack(track)
                }
                .buttonStyle(.plain)
            }

            Text("Playlists")
                .font(.headline)

            List(profile.playlists.prefix(20)) { playlist in
                Text(playlist.title)
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 420)
    }
}

private struct PlaylistTracksSheet: View {
    let tracks: [SCTrack]
    let onPlayAll: () -> Void
    let onPlayTrack: (SCTrack) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Playlist Tracks")
                    .font(.headline)
                Spacer()
                Button("Play All", action: onPlayAll)
                    .buttonStyle(.borderedProminent)
            }

            List(tracks) { track in
                Button(track.title) {
                    onPlayTrack(track)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
    }
}
