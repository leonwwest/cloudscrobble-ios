import SwiftUI

struct LibraryView: View {
    @StateObject var viewModel: LibraryViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(CloudTheme.warning)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(CloudTheme.warning.opacity(0.1))
                        )
                }

                if viewModel.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(CloudTheme.sky)
                        Text("Refreshing library…")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(CloudTheme.muted)
                    }
                    .padding(.horizontal, 6)
                }

                librarySections
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Library")
        .cloudInlineNavigationTitle()
        .task {
            await viewModel.refresh()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("My SoundCloud")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(CloudTheme.ink)
                Text(viewModel.me.map { "Signed in as \($0.username)" } ?? "Connect SoundCloud to load private data")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(CloudTheme.muted)
            }

            Spacer()

            Button("Refresh") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(SecondaryPillButtonStyle())
        }
        .cloudCard()
    }

    @ViewBuilder
    private var librarySections: some View {
        if viewModel.myPlaylists.isEmpty && viewModel.myLikedTracks.isEmpty && viewModel.myLikedPlaylists.isEmpty && !viewModel.isLoading {
            EmptyStateCard(
                icon: "books.vertical",
                title: "No library content",
                subtitle: "After connecting SoundCloud, refresh this tab to load your playlists and likes."
            )
        } else {
            LibrarySectionCard(
                title: "Playlists",
                icon: "music.note.list"
            ) {
                if viewModel.myPlaylists.isEmpty {
                    Text("No playlists")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(CloudTheme.muted)
                } else {
                    ForEach(viewModel.myPlaylists) { playlist in
                        row(title: playlist.title, subtitle: playlist.user.username, actionLabel: nil, action: nil)
                    }
                }
            }

            LibrarySectionCard(
                title: "Liked Tracks",
                icon: "heart.fill"
            ) {
                if viewModel.myLikedTracks.isEmpty {
                    Text("No liked tracks")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(CloudTheme.muted)
                } else {
                    ForEach(viewModel.myLikedTracks) { track in
                        row(title: track.title, subtitle: track.user.username, actionLabel: "Play") {
                            Task { await viewModel.play(track: track) }
                        }
                    }
                }
            }

            LibrarySectionCard(
                title: "Liked Playlists",
                icon: "star.fill"
            ) {
                if viewModel.myLikedPlaylists.isEmpty {
                    Text("No liked playlists")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(CloudTheme.muted)
                } else {
                    ForEach(viewModel.myLikedPlaylists) { playlist in
                        row(title: playlist.title, subtitle: playlist.user.username, actionLabel: nil, action: nil)
                    }
                }
            }
        }
    }

    private func row(
        title: String,
        subtitle: String,
        actionLabel: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(CloudTheme.ink)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(CloudTheme.muted)
            }

            Spacer()

            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(SecondaryPillButtonStyle())
            }
        }
        .padding(.vertical, 6)
        .overlay(
            Divider().offset(y: 18),
            alignment: .bottom
        )
    }
}

private struct LibrarySectionCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(CloudTheme.sky)
                Text(title)
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(CloudTheme.ink)
            }

            content
        }
        .cloudCard()
    }
}

