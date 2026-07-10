import CloudScrobbleCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct LibraryView: View {
    private enum LibraryScope: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case likes = "Likes"
        case playlists = "Playlists"
        case stations = "Stations"
        case history = "History"

        var id: String { rawValue }
    }

    @ObservedObject var session: AppSessionViewModel
    @ObservedObject private var playerController: PlayerScrobbleController
    @ObservedObject private var viewModel: LibraryViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scope: LibraryScope = .overview
    private let onOpenSearch: (() -> Void)?

    init(
        session: AppSessionViewModel,
        viewModel: LibraryViewModel,
        onOpenSearch: (() -> Void)? = nil
    ) {
        self.session = session
        self.onOpenSearch = onOpenSearch
        _playerController = ObservedObject(wrappedValue: session.playerController)
        _viewModel = ObservedObject(wrappedValue: viewModel)
    }

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

    private var selectedMixBinding: Binding<LibraryViewModel.SmartMix?> {
        Binding(
            get: { viewModel.selectedMix },
            set: { value in
                if value == nil {
                    viewModel.clearMixSelection()
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

                if isPublicLibraryLocked {
                    publicModeLockedView
                } else {
                    libraryScopeTabs

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
                        scopedContent
                    }
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
            guard !isPublicLibraryLocked else { return }
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
        .sheet(item: selectedMixBinding) { mix in
            LibraryMixTracksSheet(
                mix: mix,
                onClose: {
                    viewModel.clearMixSelection()
                },
                onPlayAll: {
                    Task {
                        await viewModel.playSelectedMix()
                        await MainActor.run { viewModel.clearMixSelection() }
                    }
                },
                onPlayTrack: { track in
                    Task {
                        await viewModel.playSelectedMix(startingWith: track)
                        await MainActor.run { viewModel.clearMixSelection() }
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
            || !viewModel.stationMixes.isEmpty
            || !playerController.recentlyPlayed.isEmpty
    }

    private var isPublicLibraryLocked: Bool {
        session.soundCloudConnected && session.soundCloudPublicMode && !session.soundCloudMockMode
    }

    private var publicModeLockedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(CloudTheme.sky)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(CloudTheme.sky.opacity(0.15)))

                VStack(alignment: .leading, spacing: 5) {
                    Text("Library requires Full Login")
                        .font(.system(.headline, design: .rounded).weight(.black))
                        .foregroundStyle(CloudTheme.ink)
                    Text("Public Mode can search and play public tracks, but it cannot access your likes, playlists, or profile.")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(CloudTheme.muted)
                        .lineSpacing(2)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Button {
                        Task { await session.reconnectSoundCloud() }
                    } label: {
                        Label("Full Login", systemImage: "link.circle.fill")
                    }
                    .buttonStyle(PrimaryPillButtonStyle())

                    Button {
                        onOpenSearch?()
                    } label: {
                        Label("Search public tracks", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(SecondaryPillButtonStyle())
                }

                VStack(spacing: 8) {
                    Button {
                        Task { await session.reconnectSoundCloud() }
                    } label: {
                        Label("Full Login", systemImage: "link.circle.fill")
                    }
                    .buttonStyle(PrimaryPillButtonStyle())

                    Button {
                        onOpenSearch?()
                    } label: {
                        Label("Search public tracks", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(SecondaryPillButtonStyle())
                }
            }

            if !playerController.recentlyPlayed.isEmpty {
                Divider()
                    .overlay(CloudTheme.line)

                recentSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cloudCard()
    }

    private var libraryScopeTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 18) {
                ForEach(LibraryScope.allCases) { tab in
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                            scope = tab
                        }
                    } label: {
                        Text(LocalizedStringKey(tab.rawValue))
                            .font(.system(.headline, design: .rounded).weight(.black))
                            .foregroundStyle(scope == tab ? CloudTheme.ink : CloudTheme.muted)
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) {
                                Capsule()
                                    .fill(scope == tab ? CloudTheme.ink : Color.clear)
                                    .frame(height: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show \(tab.rawValue)")
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var scopedContent: some View {
        switch scope {
        case .overview:
            recentSection
            smartMixSection
            stationSection
            playlistShelf(
                title: "Playlists",
                icon: "music.note.list",
                playlists: viewModel.myPlaylists,
                emptyText: "No playlists"
            )
            likedTracksSection
        case .likes:
            likedTracksSection
            playlistShelf(
                title: "Liked Playlists",
                icon: "heart.rectangle.fill",
                playlists: viewModel.myLikedPlaylists,
                emptyText: "No liked playlists"
            )
        case .playlists:
            playlistShelf(
                title: "Your Playlists",
                icon: "music.note.list",
                playlists: viewModel.myPlaylists,
                emptyText: "No playlists"
            )
            playlistShelf(
                title: "Liked Playlists",
                icon: "heart.rectangle.fill",
                playlists: viewModel.myLikedPlaylists,
                emptyText: "No liked playlists"
            )
        case .stations:
            stationSection
        case .history:
            recentSection
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LibrarySectionHeader(title: "Recently Played", icon: "clock.arrow.circlepath")

            if playerController.recentlyPlayed.isEmpty {
                LibraryEmptyRow(text: "No playback history yet")
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(playerController.recentlyPlayed.prefix(18)) { track in
                            LibraryRecentTrackCard(track: track) {
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

    @ViewBuilder
    private var smartMixSection: some View {
        if !viewModel.smartMixes.isEmpty {
            LibrarySectionHeader(title: "Made For You", icon: "sparkles")

            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(viewModel.smartMixes) { mix in
                        SmartMixCard(mix: mix) {
                            viewModel.open(mix: mix)
                        } onPlay: {
                            Task { await viewModel.play(mix: mix) }
                        }
                    }
                }
                .padding(.horizontal, 1)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var stationSection: some View {
        if !viewModel.stationMixes.isEmpty {
            LibrarySectionHeader(title: "Stations", icon: "dot.radiowaves.left.and.right")

            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(viewModel.stationMixes) { mix in
                        SmartMixCard(mix: mix) {
                            viewModel.open(mix: mix)
                        } onPlay: {
                            Task { await viewModel.play(mix: mix) }
                        }
                    }
                }
                .padding(.horizontal, 1)
            }
            .scrollIndicators(.hidden)
        } else if scope == .stations {
            LibraryEmptyRow(text: "No stations yet")
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
            CachedArtworkImage(url: user?.avatarURL, iconName: "person.fill", maxPixelSize: 180)
            .frame(width: 54, height: 54)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                if let user {
                    Text(user.username)
                        .font(.system(.title3, design: .rounded).weight(.black))
                        .foregroundStyle(CloudTheme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                } else {
                    Text("My SoundCloud")
                        .font(.system(.title3, design: .rounded).weight(.black))
                        .foregroundStyle(CloudTheme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }

                Text(LocalizedStringKey(user == nil ? "Library" : "Playlists, likes and mixes"))
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
            Text(LocalizedStringKey(message))
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
            Text(LocalizedStringKey(title))
                .font(.system(.headline, design: .rounded).weight(.black))
                .foregroundStyle(CloudTheme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LibraryEmptyRow: View {
    let text: String

    var body: some View {
        Text(LocalizedStringKey(text))
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
    let onOpen: () -> Void
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(action: onOpen) {
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
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(mix.title)")

            HStack(spacing: 8) {
                Button(action: onOpen) {
                    Label("Tracks", systemImage: "list.bullet")
                }
                .buttonStyle(SecondaryPillButtonStyle())
                .accessibilityLabel("Show \(mix.title) tracks")

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
                VStack(alignment: .leading, spacing: 9) {
                    ArtworkTile(url: playlist.artworkURL, iconName: "music.note.list")
                        .frame(width: 148, height: 148)

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
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(playlist.title)")

            HStack(spacing: 8) {
                Button(action: onOpen) {
                    Label("Tracks", systemImage: "list.bullet")
                }
                .buttonStyle(SecondaryPillButtonStyle())
                .accessibilityLabel("Show \(playlist.title) tracks")

                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(CloudTheme.sky))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play \(playlist.title)")
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

private struct LibraryRecentTrackCard: View {
    let track: SavedPlaybackTrack
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkTile(url: track.artworkURL, iconName: "clock.arrow.circlepath")
                    .frame(width: 148, height: 148)

                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
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
                Text(displayMetadata.track)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(CloudTheme.ink)
                    .lineLimit(2)
                Text("\(displayMetadata.artist) - \(durationText(track.durationMs))")
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

    private var displayMetadata: LastFMTrackMeta {
        TrackIdentity.displayMetadata(for: track)
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
    }
}

private struct LibraryMixTracksSheet: View {
    let mix: LibraryViewModel.SmartMix
    let onClose: () -> Void
    let onPlayAll: () -> Void
    let onPlayTrack: (SCTrack) -> Void
    let onPlayNextTrack: (SCTrack) -> Void
    let onAddToQueueTrack: (SCTrack) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ArtworkMosaic(urls: mix.artworkURLs, iconName: mix.iconName)
                        .frame(width: 74, height: 74)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(mix.title)
                            .font(.system(.title3, design: .rounded).weight(.black))
                            .foregroundStyle(CloudTheme.ink)
                            .lineLimit(2)
                        Text("\(mix.tracks.count) tracks")
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(CloudTheme.muted)
                        Text(mix.subtitle)
                            .font(.system(.caption2, design: .rounded).weight(.semibold))
                            .foregroundStyle(CloudTheme.muted)
                            .lineLimit(2)
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
                        .accessibilityLabel("Close collection")

                        Button(action: onPlayAll) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 46, height: 46)
                                .background(Circle().fill(CloudTheme.sky))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play \(mix.title)")
                    }
                }
                .cloudCard()

                ForEach(mix.tracks) { track in
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
    }
}

private struct ArtworkTile: View {
    let url: URL?
    let iconName: String

    var body: some View {
        CachedArtworkImage(url: url, iconName: iconName)
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
