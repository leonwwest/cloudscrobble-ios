import SwiftUI

struct ContentView: View {
    @StateObject private var session = AppSessionViewModel()

    @State private var lastFMUsername = ""
    @State private var lastFMPassword = ""
    @State private var headerVisible = false

    var body: some View {
        ZStack {
            CloudBackdrop()

            VStack(spacing: 14) {
                headerCard
                    .opacity(headerVisible ? 1 : 0)
                    .offset(y: headerVisible ? 0 : 12)

                TabView {
                    SearchView(viewModel: SearchViewModel(session: session))
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }

                    LibraryView(viewModel: LibraryViewModel(session: session))
                    .tabItem { Label("Library", systemImage: "books.vertical") }

                    PlayerView(controller: session.playerController)
                    .tabItem { Label("Player", systemImage: "play.circle.fill") }
                }
                .tint(CloudTheme.sky)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(CloudTheme.shell.opacity(0.95))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
                        .allowsHitTesting(false)
                )
                .shadow(color: .black.opacity(0.14), radius: 20, x: 0, y: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(14)
        }
        .task {
            await session.refreshConnectionState()
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                headerVisible = true
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CloudScrobble")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(CloudTheme.ink)
                    Text(session.isConfigured ? "Private iOS MVP" : "Missing environment config")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(CloudTheme.muted)
                }

                Spacer()

                if session.isBusy {
                    ProgressView()
                        .tint(CloudTheme.sky)
                }
            }

            HStack(spacing: 8) {
                StatusBadge(title: "SoundCloud", isConnected: session.soundCloudConnected)
                StatusBadge(title: "Last.fm", isConnected: session.lastFMConnected)
            }

            Button(session.soundCloudConnected ? "Disconnect SoundCloud" : "Connect SoundCloud") {
                Task {
                    if session.soundCloudConnected {
                        await session.disconnectSoundCloud()
                    } else {
                        await session.connectSoundCloud()
                    }
                }
            }
            .buttonStyle(PrimaryPillButtonStyle())

            VStack(alignment: .leading, spacing: 8) {
                Text("Last.fm Credentials")
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(CloudTheme.muted)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        usernameField
                        passwordField
                    }
                    VStack(spacing: 8) {
                        usernameField
                        passwordField
                    }
                }

                Button(session.lastFMConnected ? "Disconnect Last.fm" : "Connect Last.fm") {
                    Task {
                        if session.lastFMConnected {
                            await session.disconnectLastFM()
                        } else {
                            await session.connectLastFM(username: lastFMUsername, password: lastFMPassword)
                        }
                    }
                }
                .buttonStyle(SecondaryPillButtonStyle())
            }

            if let statusMessage = session.statusMessage {
                HStack(spacing: 8) {
                    Image(systemName: statusMessage.isLikelyError ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .foregroundStyle(statusMessage.isLikelyError ? CloudTheme.warning : CloudTheme.success)
                    Text(statusMessage)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(CloudTheme.ink)
                        .lineLimit(3)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            statusMessage.isLikelyError
                            ? CloudTheme.warning.opacity(0.12)
                            : CloudTheme.success.opacity(0.12)
                        )
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
                .allowsHitTesting(false)
            }
        }
        .cloudCard()
    }

    private var usernameField: some View {
        TextField("Last.fm username", text: $lastFMUsername)
            .cloudCredentialField()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(CloudTheme.sky.opacity(0.3), lineWidth: 1)
            )
    }

    private var passwordField: some View {
        SecureField("Last.fm password", text: $lastFMPassword)
            .cloudCredentialField()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(CloudTheme.sky.opacity(0.3), lineWidth: 1)
            )
    }
}

private extension String {
    var isLikelyError: Bool {
        let lowered = lowercased()
        return lowered.contains("error")
            || lowered.contains("failed")
            || lowered.contains("missing")
            || lowered.contains("invalid")
    }
}
