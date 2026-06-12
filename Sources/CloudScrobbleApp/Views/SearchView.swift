import CloudScrobbleCore
import SwiftUI

struct SearchView: View {
    @StateObject var viewModel: SearchViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                controlCard

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(CloudTheme.warning)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(CloudTheme.warning.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(CloudTheme.warning.opacity(0.24), lineWidth: 1)
                        )
                }

                content
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 84)
        }
        .onChange(of: viewModel.query) { _, _ in
            viewModel.scheduleSearch()
        }
        .onChange(of: viewModel.scope) { _, _ in
            viewModel.scheduleSearch(immediate: true)
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
                    Task { await viewModel.playSelectedPlaylist(startingWith: track) }
                }
            )
        }
    }

    private var controlCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .foregroundStyle(CloudTheme.sky)
                Text("Search")
                    .font(.system(.title3, design: .rounded).weight(.black))
                    .foregroundStyle(CloudTheme.ink)
                Spacer()
                Button {
                    Task { await viewModel.runSearch(reset: true) }
                } label: {
                    Image(systemName: "arrow.forward")
                }
                .buttonStyle(IconCircleButtonStyle())
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(CloudTheme.muted)
                TextField("Tracks, playlists, users", text: $viewModel.query)
                    .cloudCredentialField()
                    .foregroundStyle(CloudTheme.ink)
                    .onSubmit {
                        Task { await viewModel.runSearch(reset: true) }
                    }

                if !viewModel.query.isEmpty {
                    Button {
                        viewModel.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .foregroundStyle(CloudTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(CloudTheme.elevatedStrong)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(CloudTheme.line, lineWidth: 1)
            )

            Picker("Scope", selection: $viewModel.scope) {
                ForEach(SearchViewModel.Scope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
        }
        .cloudCard()
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.scope {
        case .tracks:
            if viewModel.isLoading && viewModel.tracks.isEmpty {
                LoadingResultSkeletonList()
            } else if viewModel.tracks.isEmpty {
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
            if viewModel.isLoading && viewModel.playlists.isEmpty {
                LoadingResultSkeletonList(showsArtwork: false)
            } else if viewModel.playlists.isEmpty {
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
            if viewModel.isLoading && viewModel.users.isEmpty {
                LoadingResultSkeletonList()
            } else if viewModel.users.isEmpty {
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
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(CloudTheme.elevatedStrong)
                        .overlay(Image(systemName: "music.note").foregroundStyle(CloudTheme.sky))
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(CloudTheme.ink)
                    .lineLimit(2)
                Text(track.user.username)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(CloudTheme.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(CloudTheme.line, lineWidth: 1)
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
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(CloudTheme.sky.opacity(0.15))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(CloudTheme.ink)
                    .lineLimit(2)
                Text(playlist.user.username)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(CloudTheme.muted)
            }

            Spacer()

            if let onOpen {
                Button(action: onOpen) {
                    Label("Open", systemImage: "chevron.right")
                }
                    .buttonStyle(SecondaryPillButtonStyle())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(CloudTheme.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(CloudTheme.line, lineWidth: 1)
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
                        .fill(CloudTheme.elevatedStrong)
                        .overlay(Image(systemName: "person.fill").foregroundStyle(CloudTheme.sky))
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(Circle())

            Text(user.username)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(CloudTheme.ink)

            Spacer()

            Button(action: onOpen) {
                Label("Profile", systemImage: "person.crop.circle")
            }
                .buttonStyle(SecondaryPillButtonStyle())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(CloudTheme.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(CloudTheme.line, lineWidth: 1)
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
                        .font(.system(.title2, design: .rounded).weight(.black))
                        .foregroundStyle(CloudTheme.ink)
                    Text("Public Profile")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(CloudTheme.muted)
                }
                .cloudCard()

                Text("Tracks")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(CloudTheme.ink)
                ForEach(profile.tracks.prefix(20)) { track in
                    TrackResultCard(track: track) {
                        onPlayTrack(track)
                    }
                }

                Text("Playlists")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(CloudTheme.ink)
                ForEach(profile.playlists.prefix(20)) { playlist in
                    PlaylistResultCard(playlist: playlist, onOpen: nil)
                }
            }
            .padding()
        }
        .background(CloudBackdrop())
        .preferredColorScheme(.dark)
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
                        .font(.system(.title3, design: .rounded).weight(.black))
                        .foregroundStyle(CloudTheme.ink)
                    Spacer()
                    Button(action: onPlayAll) {
                        Label("Play All", systemImage: "play.fill")
                    }
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
        .background(CloudBackdrop())
        .preferredColorScheme(.dark)
    }
}
