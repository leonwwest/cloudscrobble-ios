import CloudScrobbleCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

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
            }, onPlayNextTrack: { track in
                Task { await viewModel.playNext(track: track) }
            }, onAddToQueueTrack: { track in
                Task { await viewModel.addToQueue(track: track) }
            }, onOpenPlaylist: { playlist in
                Task {
                    await MainActor.run { viewModel.closeUserProfile() }
                    await viewModel.open(playlist: playlist)
                }
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
                },
                onPlayNextTrack: { track in
                    Task { await viewModel.playNext(track: track) }
                },
                onAddToQueueTrack: { track in
                    Task { await viewModel.addToQueue(track: track) }
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
                        } onPlayNext: {
                            Task { await viewModel.playNext(track: track) }
                        } onAddToQueue: {
                            Task { await viewModel.addToQueue(track: track) }
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
    @Environment(\.openURL) private var openURL

    let track: SCTrack
    let onPlay: () -> Void
    var onPlayNext: (() -> Void)?
    var onAddToQueue: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            CachedArtworkImage(url: track.artworkURL, iconName: "music.note", maxPixelSize: 180)
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(displayMetadata.track)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(CloudTheme.ink)
                    .lineLimit(2)
                Text(displayMetadata.artist)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(CloudTheme.muted)
            }

            Spacer()

            if hasMenuActions {
                Menu {
                    if let onPlayNext {
                        Button(action: onPlayNext) {
                            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                    }

                    if let onAddToQueue {
                        Button(action: onAddToQueue) {
                            Label("Add to Queue", systemImage: "text.badge.plus")
                        }
                    }

                    if let permalinkURL = track.permalinkURL {
                        Button {
                            openURL(permalinkURL)
                        } label: {
                            Label("Open in SoundCloud", systemImage: "safari")
                        }

                        Button {
                            copyToPasteboard(permalinkURL.absoluteString)
                        } label: {
                            Label("Copy Link", systemImage: "doc.on.doc")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(CloudTheme.ink)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(CloudTheme.elevatedStrong))
                }
                .accessibilityLabel("Track actions")
            }

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

    private var hasMenuActions: Bool {
        onPlayNext != nil || onAddToQueue != nil || track.permalinkURL != nil
    }

    private func copyToPasteboard(_ text: String) {
#if os(iOS)
        UIPasteboard.general.string = text
#endif
    }

    private var displayMetadata: LastFMTrackMeta {
        TrackIdentity.displayMetadata(for: track)
    }
}

private struct PlaylistResultCard: View {
    let playlist: SCPlaylist
    let onOpen: (() -> Void)?

    var body: some View {
        Button(action: { onOpen?() }) {
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

                if onOpen != nil {
                    Label("Open", systemImage: "chevron.right")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(CloudTheme.ink)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(CloudTheme.elevatedStrong))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(onOpen == nil)
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
            CachedArtworkImage(url: user.avatarURL, iconName: "person.fill", maxPixelSize: 160)
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
    let onPlayNextTrack: (SCTrack) -> Void
    let onAddToQueueTrack: (SCTrack) -> Void
    let onOpenPlaylist: (SCPlaylist) -> Void

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
                    } onPlayNext: {
                        onPlayNextTrack(track)
                    } onAddToQueue: {
                        onAddToQueueTrack(track)
                    }
                }

                Text("Playlists")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(CloudTheme.ink)
                ForEach(profile.playlists.prefix(20)) { playlist in
                    PlaylistResultCard(playlist: playlist) {
                        onOpenPlaylist(playlist)
                    }
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
    let onPlayNextTrack: (SCTrack) -> Void
    let onAddToQueueTrack: (SCTrack) -> Void

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
                    } onPlayNext: {
                        onPlayNextTrack(track)
                    } onAddToQueue: {
                        onAddToQueueTrack(track)
                    }
                }
            }
            .padding()
        }
        .background(CloudBackdrop())
        .preferredColorScheme(.dark)
    }
}
