import CloudScrobbleCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct LibraryView: View {
    @ObservedObject var session: AppSessionViewModel
    @StateObject var viewModel: LibraryViewModel

    private var libraryRefreshID: String {
        [
            session.soundCloudConnected.description,
            session.soundCloudPublicMode.description,
            session.soundCloudMockMode.description
        ].joined(separator: ":")
    }

    private var selectedPlaylistBinding: Binding<LibraryViewModel.PlaylistTracksData?> {
        Binding(
            get: { viewModel.selectedPlaylist },
            set: { value in
                if value == nil {
                    viewModel.clearPlaylistSelection()
                }
            }
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                LibraryProfileHeader(
                    user: viewModel.me,
                    isLoading: viewModel.isLoading || viewModel.isLoadingPlaylist
                ) {
                    Task { await viewModel.refresh() }
                }

                if let errorMessage = viewModel.errorMessage {
                    LibraryMessageBanner(message: errorMessage)
                }

                if viewModel.isLoading && !hasLibraryContent {
                    LoadingResultSkeletonList(count: 5)
                } else if !hasLibraryContent {
                    EmptyStateCard(
                        icon: "books.vertical",
                        title: "No library content",
                        subtitle: "Connect SoundCloud with full login to load your playlists and likes."
                    )
                } else {
                    smartMixSection
                    playlistShelf(
                        title: "Your Playlists",
                        icon: "music.note.list",
                        playlists: viewModel.myPlaylists,
                        emptyText: "No playlists"
                    )
                    likedTracksSection
                    playlistShelf(
                        title: "Liked Playlists",
                        icon: "heart.rectangle.fill",
                        playlists: viewModel.myLikedPlaylists,
                        emptyText: "No liked playlists"
                    )
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 84)
        }
        .task(id: libraryRefreshID) {
            await viewModel.refresh()
        }
        .sheet(item: selectedPlaylistBinding) { data in
            LibraryPlaylistTracksSheet(
                playlist: data.playlist,
                tracks: data.tracks,
                onClose: {
                    viewModel.clearPlaylistSelection()
                },
                onPlayAll: {
                    Task {
                        await viewModel.playSelectedPlaylist()
                        await MainActor.run { viewModel.clearPlaylistSelection() }
                    }
                },
                onPlayTrack: { track in
                    Task {
                        await viewModel.playSelectedPlaylist(startingWith: track)
                        await MainActor.run { viewModel.clearPlaylistSelection() }
                    }
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

    private var hasLibraryContent: Bool {
        !viewModel.smartMixes.isEmpty
            || !viewModel.myPlaylists.isEmpty
            || !viewModel.myLikedTracks.isEmpty
            || !viewModel.myLikedPlaylists.isEmpty
    }

    @ViewBuilder
    private var smartMixSection: some View {
        if !viewModel.smartMixes.isEmpty {
            LibrarySectionHeader(title: "Made For You", icon: "sparkles")

            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(viewModel.smartMixes) { mix in
                        SmartMixCard(mix: mix) {
                            Task { await viewModel.play(mix: mix) }
                        }
                    }
                }
                .padding(.horizontal, 1)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var likedTracksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LibrarySectionHeader(title: "Liked Tracks", icon: "heart.fill")

            if viewModel.myLikedTracks.isEmpty {
                LibraryEmptyRow(text: "No liked tracks")
            } else {
                ForEach(viewModel.myLikedTracks.prefix(24)) { track in
                    LibraryTrackRow(track: track) {
                        Task { await viewModel.play(track: track) }
                    } onPlayNext: {
                        Task { await viewModel.playNext(track: track) }
                    } onAddToQueue: {
                        Task { await viewModel.addToQueue(track: track) }
                    }
                }
            }
        }
    }

    private func playlistShelf(
        title: String,
        icon: String,
        playlists: [SCPlaylist],
        emptyText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LibrarySectionHeader(title: title, icon: icon)

            if playlists.isEmpty {
                LibraryEmptyRow(text: emptyText)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(playlists) { playlist in
                            LibraryPlaylistCard(
                                playlist: playlist,
                                onOpen: {
                                    Task { await viewModel.open(playlist: playlist) }
                                },
                                onPlay: {
                                    Task { await viewModel.play(playlist: playlist) }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

private struct LibraryProfileHeader: View {
    let user: SCUser?
    let isLoading: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: user?.avatarURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Circle()
                        .fill(CloudTheme.elevatedStrong)
                        .overlay(Image(systemName: "person.fill").foregroundStyle(CloudTheme.sky))
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(user?.username ?? "My SoundCloud")
                    .font(.system(.title3, design: .rounded).weight(.black))
                    .foregroundStyle(CloudTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(user == nil ? "Library" : "Playlists, likes and mixes")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(CloudTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if isLoading {
                ProgressView()
                    .tint(CloudTheme.sky)
            }

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(IconCircleButtonStyle())
            .accessibilityLabel("Refresh library")
        }
        .cloudCard()
    }
}

private struct LibraryMessageBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(CloudTheme.warning)
            Text(message)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(CloudTheme.warning)
                .lineLimit(3)
        }
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
}

private struct LibrarySectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(CloudTheme.sky)
            Text(title)
                .font(.system(.headline, design: .rounded).weight(.black))
                .foregroundStyle(CloudTheme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LibraryEmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .foregroundStyle(CloudTheme.muted)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(CloudTheme.elevated.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(CloudTheme.line, lineWidth: 1)
            )
    }
}

private struct SmartMixCard: View {
    let mix: LibraryViewModel.SmartMix
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkMosaic(urls: mix.artworkURLs, iconName: mix.iconName)
                .frame(width: 148, height: 148)

            VStack(alignment: .leading, spacing: 3) {
                Text(mix.title)
                    .font(.system(.subheadline, design: .rounded).weight(.black))
                    .foregroundStyle(CloudTheme.ink)
                    .lineLimit(1)
                Text(mix.subtitle)
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(CloudTheme.muted)
                    .lineLimit(2)
                    .frame(height: 30, alignment: .top)
            }

            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(CloudTheme.sky))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(mix.title)")
        }
        .padding(10)
        .frame(width: 170, alignment: .leading)
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

private struct LibraryPlaylistCard: View {
    let playlist: SCPlaylist
    let onOpen: () -> Void
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(action: onOpen) {
                ArtworkTile(url: playlist.artworkURL, iconName: "music.note.list")
                    .frame(width: 148, height: 148)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(playlist.title)")

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.title)
                    .font(.system(.subheadline, design: .rounded).weight(.black))
                    .foregroundStyle(CloudTheme.ink)
                    .lineLimit(2)
                    .frame(height: 38, alignment: .top)
                Text(playlist.user.username)
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(CloudTheme.muted)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(CloudTheme.sky))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play \(playlist.title)")

                Button(action: onOpen) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(CloudTheme.ink)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(CloudTheme.elevatedStrong))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(playlist.title)")
            }
        }
        .padding(10)
        .frame(width: 170, alignment: .leading)
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

private struct LibraryTrackRow: View {
    @Environment(\.openURL) private var openURL

    let track: SCTrack
    let onPlay: () -> Void
    var onPlayNext: (() -> Void)?
    var onAddToQueue: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            ArtworkTile(url: track.artworkURL, iconName: "music.note")
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(CloudTheme.ink)
                    .lineLimit(2)
                Text("\(track.user.username) - \(durationText(track.durationMs))")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(CloudTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

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
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(CloudTheme.sky))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(track.title)")
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

    private func durationText(_ milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1000)
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    private var hasMenuActions: Bool {
        onPlayNext != nil || onAddToQueue != nil || track.permalinkURL != nil
    }

    private func copyToPasteboard(_ text: String) {
#if os(iOS)
        UIPasteboard.general.string = text
#endif
    }
}

private struct LibraryPlaylistTracksSheet: View {
    let playlist: SCPlaylist
    let tracks: [SCTrack]
    let onClose: () -> Void
    let onPlayAll: () -> Void
    let onPlayTrack: (SCTrack) -> Void
    let onPlayNextTrack: (SCTrack) -> Void
    let onAddToQueueTrack: (SCTrack) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ArtworkTile(url: playlist.artworkURL ?? tracks.first?.artworkURL, iconName: "music.note.list")
                        .frame(width: 74, height: 74)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(playlist.title)
                            .font(.system(.title3, design: .rounded).weight(.black))
                            .foregroundStyle(CloudTheme.ink)
                            .lineLimit(2)
                        Text("\(tracks.count) tracks")
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(CloudTheme.muted)
                    }

                    Spacer(minLength: 4)

                    HStack(spacing: 8) {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(CloudTheme.ink)
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(CloudTheme.elevatedStrong))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close playlist")

                        Button(action: onPlayAll) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 46, height: 46)
                                .background(Circle().fill(CloudTheme.sky))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play playlist")
                    }
                }
                .cloudCard()

                ForEach(tracks) { track in
                    LibraryTrackRow(track: track) {
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

private struct ArtworkTile: View {
    let url: URL?
    let iconName: String

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            default:
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(CloudTheme.elevatedStrong)
                    .overlay(
                        Image(systemName: iconName)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(CloudTheme.sky)
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(CloudTheme.line, lineWidth: 1)
        )
    }
}

private struct ArtworkMosaic: View {
    let urls: [URL]
    let iconName: String

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        if urls.isEmpty {
            ArtworkTile(url: nil, iconName: iconName)
        } else {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    ArtworkTile(url: urls.indices.contains(index) ? urls[index] : urls.first, iconName: iconName)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
