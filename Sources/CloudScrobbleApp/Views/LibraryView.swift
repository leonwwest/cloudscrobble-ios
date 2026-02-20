import SwiftUI

struct LibraryView: View {
    @StateObject var viewModel: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("My Library")
                    .font(.headline)
                Spacer()
                Button("Refresh") {
                    Task { await viewModel.refresh() }
                }
                .buttonStyle(.bordered)
            }

            if let me = viewModel.me {
                Text("Signed in as \(me.username)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.isLoading {
                ProgressView()
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Playlists")
                        .font(.subheadline.bold())
                    List(viewModel.myPlaylists) { playlist in
                        Text(playlist.title)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Liked Tracks")
                        .font(.subheadline.bold())
                    List(viewModel.myLikedTracks) { track in
                        Button(track.title) {
                            Task { await viewModel.play(track: track) }
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Liked Playlists")
                        .font(.subheadline.bold())
                    List(viewModel.myLikedPlaylists) { playlist in
                        Text(playlist.title)
                    }
                }
            }
        }
        .task {
            await viewModel.refresh()
        }
    }
}
