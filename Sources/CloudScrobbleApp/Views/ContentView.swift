import SwiftUI

struct ContentView: View {
    @StateObject private var session = AppSessionViewModel()

    @State private var lastFMUsername = ""
    @State private var lastFMPassword = ""
    @State private var showLastFMSheet = false
    @State private var deckVisible = false

    var body: some View {
        ZStack {
            CloudBackdrop()

            TabView {
                SearchView(viewModel: SearchViewModel(session: session))
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }

                LibraryView(viewModel: LibraryViewModel(session: session))
                    .tabItem { Label("Library", systemImage: "books.vertical") }

                PlayerView(controller: session.playerController)
                    .tabItem { Label("Player", systemImage: "play.circle.fill") }
            }
            .tint(CloudTheme.sky)
            .safeAreaInset(edge: .top, spacing: 8) {
                connectionDeck
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .opacity(deckVisible ? 1 : 0)
                    .offset(y: deckVisible ? 0 : -10)
            }
            .safeAreaInset(edge: .bottom, spacing: 10) {
                if let statusMessage = session.statusMessage {
                    statusToast(message: statusMessage)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
        }
        .sheet(isPresented: $showLastFMSheet) {
            lastFMSheet
        }
        .task {
            await session.refreshConnectionState()
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.84)) {
                deckVisible = true
            }
        }
        .onOpenURL { url in
            Task {
                await session.handleIncomingOAuthCallback(url)
            }
        }
    }

    private var connectionDeck: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CloudScrobble")
                        .font(.system(size: 32, weight: .bold, design: .serif))
                        .foregroundStyle(CloudTheme.ink)
                    Text(session.isConfigured ? "SoundCloud Player + Last.fm Scrobbling" : "Config missing in Run Scheme")
                        .font(.system(.caption, design: .serif))
                        .foregroundStyle(CloudTheme.muted)
                }

                Spacer(minLength: 8)

                if session.isBusy {
                    ProgressView()
                        .tint(CloudTheme.sky)
                }
            }

            HStack(spacing: 10) {
                StatusBadge(title: "SoundCloud", isConnected: session.soundCloudConnected)
                StatusBadge(title: "Last.fm", isConnected: session.lastFMConnected)
            }

            if session.soundCloudConnected && session.soundCloudPublicMode {
                Text("Public Mode active: search/playback enabled, private /me endpoints disabled.")
                    .font(.system(.caption2, design: .serif))
                    .foregroundStyle(CloudTheme.muted)
            }

            HStack(spacing: 8) {
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

                Button(session.lastFMConnected ? "Disconnect Last.fm" : "Last.fm Login") {
                    Task {
                        if session.lastFMConnected {
                            await session.disconnectLastFM()
                        } else {
                            showLastFMSheet = true
                        }
                    }
                }
                .buttonStyle(SecondaryPillButtonStyle())
            }

            if !session.soundCloudConnected {
                Button("Use SoundCloud Public Mode") {
                    Task { await session.connectSoundCloudPublicMode() }
                }
                .buttonStyle(SecondaryPillButtonStyle())
            }

            if !session.isConfigured {
                Text("Set Run Scheme env vars and start backend at `SOUNDCLOUD_TOKEN_BROKER_BASE_URL`.")
                    .font(.system(.caption2, design: .serif))
                    .foregroundStyle(CloudTheme.warning)
            }
        }
        .cloudCard()
    }

    private func statusToast(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: message.isLikelyError ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .foregroundStyle(message.isLikelyError ? CloudTheme.warning : CloudTheme.success)
            Text(message)
                .font(.system(.caption, design: .serif))
                .foregroundStyle(CloudTheme.ink)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 3)
    }

    private var lastFMSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Last.fm Credentials")
                    .font(.system(.title3, design: .serif).weight(.bold))
                    .foregroundStyle(CloudTheme.ink)
                Text("Required for `updateNowPlaying` and `track.scrobble`.")
                    .font(.system(.caption, design: .serif))
                    .foregroundStyle(CloudTheme.muted)

                TextField("Last.fm username", text: $lastFMUsername)
                    .cloudCredentialField()
                    .textContentType(.username)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.95))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(CloudTheme.sky.opacity(0.35), lineWidth: 1)
                    )

                SecureField("Last.fm password", text: $lastFMPassword)
                    .cloudCredentialField()
                    .textContentType(.password)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.95))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(CloudTheme.sky.opacity(0.35), lineWidth: 1)
                    )

                Button("Connect Last.fm") {
                    Task {
                        await session.connectLastFM(username: lastFMUsername, password: lastFMPassword)
                        if session.lastFMConnected {
                            showLastFMSheet = false
                        }
                    }
                }
                .buttonStyle(PrimaryPillButtonStyle())

                Spacer(minLength: 0)
            }
            .padding(16)
            .background(CloudBackdrop().opacity(0.20))
            .navigationTitle("Connect Last.fm")
            .cloudInlineNavigationTitle()
            .toolbar {
#if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        showLastFMSheet = false
                    }
                }
#else
                ToolbarItem {
                    Button("Close") {
                        showLastFMSheet = false
                    }
                }
#endif
            }
        }
        .presentationDetents([.fraction(0.50), .medium])
    }
}

private extension String {
    var isLikelyError: Bool {
        let lowered = lowercased()
        return lowered.contains("error")
            || lowered.contains("failed")
            || lowered.contains("missing")
            || lowered.contains("invalid")
            || lowered.contains("canceled")
    }
}
