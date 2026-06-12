import CloudScrobbleCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct HomeView: View {
    @ObservedObject var session: AppSessionViewModel
    @ObservedObject private var playerController: PlayerScrobbleController
    @StateObject private var viewModel: HomeViewModel

    init(session: AppSessionViewModel, viewModel: HomeViewModel) {
        self.session = session
        _playerController = ObservedObject(wrappedValue: session.playerController)
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    private var homeRefreshID: String {
        [
            session.soundCloudConnected.description,
            session.soundCloudPublicMode.description,
            session.soundCloudMockMode.description
        ].joined(separator: ":")
    }

    private var selectedPlaylistBinding: Binding<HomeViewModel.PlaylistTracksData?> {
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
                HomeHeader(
                    user: viewModel.me,
                    isLoading: viewModel.isLoading || viewModel.isLoadingPlaylist
                ) {
                    Task { await viewModel.refresh() }
                }

                if let message = viewModel.message {
                    HomeMessageBanner(message: message)
                }

                if viewModel.isLoading && !hasHomeContent {
                    LoadingResultSkeletonList(count: 5)
                } else if !hasHomeContent {
                    EmptyStateCard(
                        icon: "house",
                        title: "Start is empty",
                        subtitle: "Connect SoundCloud with full login to load your personal Start page."
                    )
                } else {
                    if let featuredMix = viewModel.homeMixes.first {
                        HomeFeatureCard(mix: featuredMix) {
                            Task { await viewModel.play(mix: featuredMix) }
                        }
                    }

                    trackShelf(
                        title: "Mehr für dich",
                        icon: "sparkles",
                        tracks: viewModel.feedTracks
                    )

                    mixShelf(mixes: Array(viewModel.homeMixes.dropFirst()))

                    playlistShelf(
                        title: "Deine Playlists",
                        icon: "music.note.list",
                        playlists: viewModel.homePlaylists
                    )

                    recentShelf(tracks: Array(playerController.recentlyPlayed.prefix(12)))

                    trackShelf(
                        title: "Liked Tracks",
                        icon: "heart.fill",
                        tracks: viewModel.likedTracks
                    )

                    playlistShelf(
                        title: "Liked Playlists",
                        icon: "heart.rectangle.fill",
                        playlists: viewModel.likedPlaylists
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
        .task(id: homeRefreshID) {
            await viewModel.refresh()
        }
        .sheet(item: selectedPlaylistBinding) { data in
            HomePlaylistTracksSheet(
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

    private var hasHomeContent: Bool {
        !viewModel.feedTracks.isEmpty
            || !viewModel.recommendedTracks.isEmpty
            || !viewModel.homePlaylists.isEmpty
            || !viewModel.likedTracks.isEmpty
            || !viewModel.likedPlaylists.isEmpty
            || !viewModel.homeMixes.isEmpty
            || !playerController.recentlyPlayed.isEmpty
    }

    @ViewBuilder
    private func trackShelf(title: String, icon: String, tracks: [SCTrack]) -> some View {
        if !tracks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HomeSectionHeader(title: title, icon: icon)

                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(tracks.prefix(24)) { track in
                            HomeTrackCard(track: track) {
                                Task { await viewModel.play(track: track, in: tracks) }
                            } onPlayNext: {
                                Task { await viewModel.playNext(track: track) }
                            } onAddToQueue: {
                                Task { await viewModel.addToQueue(track: track) }
                            }
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder
    private func mixShelf(mixes: [HomeViewModel.HomeMix]) -> some View {
        if !mixes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HomeSectionHeader(title: "Für dich abgemischt", icon: "waveform")

                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(mixes) { mix in
                            HomeMixCard(mix: mix) {
                                Task { await viewModel.play(mix: mix) }
                            }
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder
    private func playlistShelf(title: String, icon: String, playlists: [SCPlaylist]) -> some View {
        if !playlists.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HomeSectionHeader(title: title, icon: icon)

                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(playlists.prefix(18)) { playlist in
                            HomePlaylistCard(playlist: playlist) {
                                Task { await viewModel.open(playlist: playlist) }
                            } onPlay: {
                                Task { await viewModel.play(playlist: playlist) }
                            }
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder
    private func recentShelf(tracks: [SavedPlaybackTrack]) -> some View {
        if !tracks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HomeSectionHeader(title: "Kürzlich gespielt", icon: "clock.arrow.circlepath")

                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(tracks) { track in
                            HomeRecentTrackCard(track: track) {
                                Task { await viewModel.play(savedTrack: track) }
                            }
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

private struct HomeHeader: View {
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
                        .overlay(Image(systemName: "house.fill").foregroundStyle(CloudTheme.sky))
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("Start")
                    .font(.system(.title2, design: .rounded).weight(.black))
                    .foregroundStyle(CloudTheme.ink)
                    .lineLimit(1)
                Text(user.map { "Personalisiert für \($0.username)" } ?? "SoundCloud Home")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(CloudTheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
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
            .accessibilityLabel("Refresh Start")
        }
        .cloudCard()
    }
}

private struct HomeMessageBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
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

private struct HomeFeatureCard: View {
    let mix: HomeViewModel.HomeMix
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            HomeArtworkMosaic(urls: mix.artworkURLs, iconName: mix.iconName)
                .frame(width: 112, height: 112)

            VStack(alignment: .leading, spacing: 6) {
                Text(mix.title)
                    .font(.system(.title3, design: .rounded).weight(.black))
                    .foregroundStyle(CloudTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(mix.subtitle)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(CloudTheme.muted)
                    .lineLimit(2)
                Text("\(mix.tracks.count) tracks")
                    .font(.system(.caption2, design: .rounded).weight(.bold))
                    .foregroundStyle(CloudTheme.sky)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button(action: onPlay) {
                Image(systemName: "play.fill")
            }
            .buttonStyle(IconCircleButtonStyle(isPrimary: true))
            .accessibilityLabel("Play \(mix.title)")
        }
        .cloudCard()
    }
}

private struct HomeSectionHeader: View {
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
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HomeTrackCard: View {
    @Environment(\.openURL) private var openURL

    let track: SCTrack
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottomTrailing) {
                HomeArtworkTile(url: track.artworkURL, iconName: "music.note")
                    .frame(width: 150, height: 150)

                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(CloudTheme.sky))
                        .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 4)
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel("Play \(track.title)")
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(.subheadline, design: .rounded).weight(.black))
                    .foregroundStyle(CloudTheme.ink)
                    .lineLimit(2)
                    .frame(height: 38, alignment: .top)
                Text(track.user.username)
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(CloudTheme.muted)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Menu {
                    Button(action: onPlayNext) {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    Button(action: onAddToQueue) {
                        Label("Add to Queue", systemImage: "text.badge.plus")
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
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(CloudTheme.elevatedStrong))
                }
                .accessibilityLabel("Track actions")

                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(width: 172, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(CloudTheme.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(CloudTheme.line, lineWidth: 1)
        )
    }

    private func copyToPasteboard(_ text: String) {
#if os(iOS)
        UIPasteboard.general.string = text
#endif
    }
}

private struct HomeMixCard: View {
    let mix: HomeViewModel.HomeMix
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottomLeading) {
                HomeArtworkMosaic(urls: mix.artworkURLs, iconName: mix.iconName)
                    .frame(width: 150, height: 150)

                Text(mix.title)
                    .font(.system(.title3, design: .rounded).weight(.black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: 132, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(CloudTheme.sky.opacity(0.94))
                    )
                    .padding(8)
            }

            Text(mix.subtitle)
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .foregroundStyle(CloudTheme.muted)
                .lineLimit(2)
                .frame(height: 30, alignment: .top)

            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(CloudTheme.sky))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(mix.title)")
        }
        .padding(10)
        .frame(width: 172, alignment: .leading)
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

private struct HomePlaylistCard: View {
    let playlist: SCPlaylist
    let onOpen: () -> Void
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(action: onOpen) {
                HomeArtworkTile(url: playlist.artworkURL, iconName: "music.note.list")
                    .frame(width: 150, height: 150)
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
        .frame(width: 172, alignment: .leading)
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

private struct HomeRecentTrackCard: View {
    let track: SavedPlaybackTrack
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottomTrailing) {
                HomeArtworkTile(url: track.artworkURL, iconName: "clock.arrow.circlepath")
                    .frame(width: 150, height: 150)

                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(CloudTheme.sky))
                        .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 4)
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel("Play \(track.title)")
            }

            Text(track.title)
                .font(.system(.subheadline, design: .rounded).weight(.black))
                .foregroundStyle(CloudTheme.ink)
                .lineLimit(2)
                .frame(height: 38, alignment: .top)
            Text(track.artistDisplay)
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .foregroundStyle(CloudTheme.muted)
                .lineLimit(1)
        }
        .padding(10)
        .frame(width: 172, alignment: .leading)
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

private struct HomePlaylistTracksSheet: View {
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
                    HomeArtworkTile(url: playlist.artworkURL ?? tracks.first?.artworkURL, iconName: "music.note.list")
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
                    HomeSheetTrackRow(track: track) {
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

private struct HomeSheetTrackRow: View {
    let track: SCTrack
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HomeArtworkTile(url: track.artworkURL, iconName: "music.note")
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(CloudTheme.ink)
                    .lineLimit(2)
                Text(track.user.username)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(CloudTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Menu {
                Button(action: onPlayNext) {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button(action: onAddToQueue) {
                    Label("Add to Queue", systemImage: "text.badge.plus")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(CloudTheme.ink)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(CloudTheme.elevatedStrong))
            }
            .accessibilityLabel("Track actions")

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

private struct HomeArtworkTile: View {
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
                            .font(.system(size: 24, weight: .semibold))
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

private struct HomeArtworkMosaic: View {
    let urls: [URL]
    let iconName: String

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        if urls.isEmpty {
            HomeArtworkTile(url: nil, iconName: iconName)
        } else if urls.count == 1 {
            HomeArtworkTile(url: urls[0], iconName: iconName)
        } else {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    HomeArtworkTile(url: urls.indices.contains(index) ? urls[index] : urls.first, iconName: iconName)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
