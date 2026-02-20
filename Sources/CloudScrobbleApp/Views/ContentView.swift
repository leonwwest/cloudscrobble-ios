import SwiftUI

struct ContentView: View {
    @StateObject private var session = AppSessionViewModel()

    @State private var lastFMUsername = ""
    @State private var lastFMPassword = ""

    var body: some View {
        VStack(spacing: 12) {
            header

            TabView {
                SearchView(viewModel: SearchViewModel(session: session))
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }

                LibraryView(viewModel: LibraryViewModel(session: session))
                    .tabItem { Label("Library", systemImage: "books.vertical") }

                PlayerView(controller: session.playerController)
                    .tabItem { Label("Player", systemImage: "play.circle") }
            }
        }
        .padding(12)
        .task {
            await session.refreshConnectionState()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CloudScrobble")
                        .font(.title2.bold())
                    Text(session.isConfigured ? "Private MVP build" : "Missing environment configuration")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if session.isBusy {
                    ProgressView()
                }
            }

            HStack(spacing: 10) {
                Button(session.soundCloudConnected ? "Disconnect SoundCloud" : "Connect SoundCloud") {
                    Task {
                        if session.soundCloudConnected {
                            await session.disconnectSoundCloud()
                        } else {
                            await session.connectSoundCloud()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)

                Text(session.soundCloudConnected ? "SoundCloud: Connected" : "SoundCloud: Not connected")
                    .font(.caption)
            }

            HStack(spacing: 8) {
                TextField("Last.fm username", text: $lastFMUsername)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)

                SecureField("Last.fm password", text: $lastFMPassword)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)

                Button(session.lastFMConnected ? "Disconnect Last.fm" : "Connect Last.fm") {
                    Task {
                        if session.lastFMConnected {
                            await session.disconnectLastFM()
                        } else {
                            await session.connectLastFM(username: lastFMUsername, password: lastFMPassword)
                        }
                    }
                }
                .buttonStyle(.bordered)

                Text(session.lastFMConnected ? "Last.fm: Connected" : "Last.fm: Not connected")
                    .font(.caption)
            }

            if let statusMessage = session.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
