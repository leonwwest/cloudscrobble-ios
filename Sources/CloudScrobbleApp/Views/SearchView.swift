import CloudScrobbleCore
import SwiftUI

struct SearchView: View {
    @StateObject var viewModel: SearchViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                controlCard

                if viewModel.isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(CloudTheme.sky)
                        Text("Searching…")
                            .font(.system(.subheadline, design: .serif))
                            .foregroundStyle(CloudTheme.muted)
                    }
                    .padding(.horizontal, 8)
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.system(.caption, design: .serif))
                        .foregroundStyle(CloudTheme.warning)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(CloudTheme.warning.opacity(0.1))
                        )
                }

                content
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.hidden)
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
        }
    }

    private var controlCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Search SoundCloud")
                .font(.system(.headline, design: .serif).weight(.bold))
                .foregroundStyle(CloudTheme.ink)

            TextField("Tracks, playlists, users", text: $viewModel.query)
                .cloudCredentialField()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.92))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(CloudTheme.sky.opacity(0.35), lineWidth: 1)
                )
                .onSubmit {
                    Task { await viewModel.runSearch(reset: true) }
                }

            Picker("Scope", selection: $viewModel.scope) {
                ForEach(SearchViewModel.Scope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)

            Button("Run Search") {
                Task { await viewModel.runSearch(reset: true) }
            }
            .buttonStyle(PrimaryPillButtonStyle())
        }
        .cloudCard()
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.scope {
        case .tracks:
            if viewModel.tracks.isEmpty {
                EmptyStateCard(
                    icon: "waveform.badge.magnifyingglass",
                    title: "No tracks yet",
                    subtitle: "Start with a search term and run search."
                )
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.tracks) { track in
                        TrackResultCard(track: track) {
                            Task { await viewModel.play(track: track) }
                        }
                        .task {
                            await viewModel.loadMoreIfNeeded(currentItemID: track.id)
                        }
                    }
                }
            }
        case .playlists:
            if viewModel.playlists.isEmpty {
                EmptyStateCard(
                    icon: "music.note.list",
                    title: "No playlists yet",
                    subtitle: "Search for playlists and open one to play its tracks."
                )
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.playlists) { playlist in
                        PlaylistResultCard(playlist: playlist) {
                            Task { await viewModel.open(playlist: playlist) }
                        }
                        .task {
                            await viewModel.loadMoreIfNeeded(currentItemID: playlist.id)
                        }
                    }
                }
            }
        case .users:
            if viewModel.users.isEmpty {
                EmptyStateCard(
                    icon: "person.2.crop.square.stack",
                    title: "No users yet",
                    subtitle: "Search for artists and open a profile."
                )
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.users) { user in
                        UserResultCard(user: user) {
                            Task { await viewModel.open(user: user) }
                        }
                        .task {
                            await viewModel.loadMoreIfNeeded(currentItemID: user.id)
                        }
                    }
                }
            }
        }
    }
}

private struct TrackResultCard: View {
    let track: SCTrack
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: track.artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(CloudTheme.sky.opacity(0.2))
                        .overlay(Image(systemName: "music.note").foregroundStyle(CloudTheme.sky))
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                    .foregroundStyle(CloudTheme.ink)
                    .lineLimit(2)
                Text(track.user.username)
                    .font(.system(.caption, design: .serif))
                    .foregroundStyle(CloudTheme.muted)
            }

            Spacer()

            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Circle().fill(CloudTheme.sky))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(CloudTheme.sky.opacity(0.20), lineWidth: 1)
        )
    }
}

private struct PlaylistResultCard: View {
    let playlist: SCPlaylist
    let onOpen: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(CloudTheme.sky)
                .frame(width: 42, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(CloudTheme.sky.opacity(0.15))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title)
                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                    .foregroundStyle(CloudTheme.ink)
                    .lineLimit(2)
                Text(playlist.user.username)
                    .font(.system(.caption, design: .serif))
                    .foregroundStyle(CloudTheme.muted)
            }

            Spacer()

            if let onOpen {
                Button("Open", action: onOpen)
                    .buttonStyle(SecondaryPillButtonStyle())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(CloudTheme.sky.opacity(0.20), lineWidth: 1)
        )
    }
}

private struct UserResultCard: View {
    let user: SCUser
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: user.avatarURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Circle()
                        .fill(CloudTheme.sky.opacity(0.2))
                        .overlay(Image(systemName: "person.fill").foregroundStyle(CloudTheme.sky))
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(Circle())

            Text(user.username)
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(CloudTheme.ink)

            Spacer()

            Button("Profile", action: onOpen)
                .buttonStyle(SecondaryPillButtonStyle())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(CloudTheme.sky.opacity(0.20), lineWidth: 1)
        )
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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.user.username)
                        .font(.system(.title2, design: .serif).weight(.bold))
                    Text("Public Profile")
                        .font(.system(.caption, design: .serif))
                        .foregroundStyle(CloudTheme.muted)
                }
                .cloudCard()

                Text("Tracks")
                    .font(.system(.headline, design: .serif).weight(.bold))
                ForEach(profile.tracks.prefix(20)) { track in
                    TrackResultCard(track: track) {
                        onPlayTrack(track)
                    }
                }

                Text("Playlists")
                    .font(.system(.headline, design: .serif).weight(.bold))
                ForEach(profile.playlists.prefix(20)) { playlist in
                    PlaylistResultCard(playlist: playlist, onOpen: nil)
                }
            }
            .padding()
        }
    }
}

private struct PlaylistTracksSheet: View {
    let tracks: [SCTrack]
    let onPlayAll: () -> Void
    let onPlayTrack: (SCTrack) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Playlist Tracks")
                        .font(.system(.title3, design: .serif).weight(.bold))
                    Spacer()
                    Button("Play All", action: onPlayAll)
                        .buttonStyle(PrimaryPillButtonStyle())
                        .frame(maxWidth: 160)
                }
                .cloudCard()

                ForEach(tracks) { track in
                    TrackResultCard(track: track) {
                        onPlayTrack(track)
                    }
                }
            }
            .padding()
        }
    }
}
