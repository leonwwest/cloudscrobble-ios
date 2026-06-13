import CloudScrobbleCore
import SwiftUI

struct ContentView: View {
    private enum AppTab {
        case home
        case search
        case library
        case player
    }

    @StateObject private var session = AppSessionViewModel()

    @State private var lastFMUsername = ""
    @State private var lastFMPassword = ""
    @State private var showLastFMSheet = false
    @State private var showSettingsSheet = false
    @State private var deckVisible = false
    @State private var pendingLastFMScrobbles = 0
    @State private var selectedTab: AppTab = .home

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                CloudBackdrop()

                VStack(spacing: 0) {
                    compactConnectionHeader
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .opacity(deckVisible ? 1 : 0)
                        .offset(y: deckVisible ? 0 : -10)

                    TabView(selection: $selectedTab) {
                        HomeView(session: session, viewModel: HomeViewModel(session: session))
                            .tabItem { Label("Start", systemImage: "house.fill") }
                            .tag(AppTab.home)

                        SearchView(viewModel: SearchViewModel(session: session))
                            .tabItem { Label("Search", systemImage: "magnifyingglass") }
                            .tag(AppTab.search)

                        LibraryView(session: session, viewModel: LibraryViewModel(session: session))
                            .tabItem { Label("Library", systemImage: "books.vertical") }
                            .tag(AppTab.library)

                        PlayerView(session: session)
                            .tabItem { Label("Player", systemImage: "play.circle.fill") }
                            .tag(AppTab.player)
                    }
                    .tint(CloudTheme.sky)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .safeAreaPadding(.top, 6)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)

                if let statusMessage = session.statusMessage {
                    statusToast(message: statusMessage)
                        .padding(.horizontal, 16)
                        .padding(.top, 72)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onTapGesture {
                            session.clearStatusMessage()
                        }
                }

                if selectedTab != .player, session.playerController.currentItem != nil {
                    MiniPlayerBar(controller: session.playerController) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                            selectedTab = .player
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 70)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.medium ... .large)
        .sheet(isPresented: $showLastFMSheet) {
            lastFMSheet
        }
        .sheet(isPresented: $showSettingsSheet) {
            settingsSheet
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

    private var compactConnectionHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CloudScrobble")
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundStyle(CloudTheme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)
                    Text(session.isConfigured ? "SoundCloud + Last.fm" : "Config missing")
                        .font(.system(.caption2, design: .rounded).weight(.semibold))
                        .foregroundStyle(CloudTheme.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if session.isBusy {
                    ProgressView()
                        .tint(CloudTheme.sky)
                }

                Button {
                    showSettingsSheet = true
                } label: {
                    Image(systemName: "gearshape.fill")
                }
                .buttonStyle(IconCircleButtonStyle())
                .accessibilityLabel("Open settings")
            }

            HStack(spacing: 7) {
                StatusBadge(title: session.soundCloudMockMode ? "Demo" : "SoundCloud", isConnected: session.soundCloudConnected)
                StatusBadge(title: "Last.fm", isConnected: session.lastFMConnected)
                Spacer(minLength: 0)
            }

            if session.isBusy {
                ProgressView(value: 0.72)
                    .progressViewStyle(.linear)
                    .tint(CloudTheme.sky)
            }
        }
        .cloudCard()
    }

    private var connectionActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                soundCloudButton
                    .layoutPriority(1)
                lastFMButton
                    .fixedSize(horizontal: true, vertical: false)
                modeButtons
                    .fixedSize(horizontal: true, vertical: false)
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    soundCloudButton
                        .layoutPriority(1)
                    lastFMButton
                        .fixedSize(horizontal: true, vertical: false)
                }

                modeButtons
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var soundCloudButton: some View {
        Button {
            Task {
                if session.soundCloudConnected {
                    await session.disconnectSoundCloud()
                } else {
                    await session.connectSoundCloud()
                }
            }
        } label: {
            Label(session.soundCloudConnected ? "Disconnect" : "Connect", systemImage: session.soundCloudConnected ? "xmark.circle.fill" : "link.circle.fill")
        }
        .buttonStyle(PrimaryPillButtonStyle())
    }

    private var lastFMButton: some View {
        Button {
            Task {
                if session.lastFMConnected {
                    await session.disconnectLastFM()
                } else {
                    showLastFMSheet = true
                }
            }
        } label: {
            Label(session.lastFMConnected ? "Last.fm Off" : "Last.fm", systemImage: session.lastFMConnected ? "bolt.slash.fill" : "dot.radiowaves.left.and.right")
        }
        .buttonStyle(SecondaryPillButtonStyle())
    }

    @ViewBuilder
    private var modeButtons: some View {
        if !session.soundCloudConnected {
            HStack(spacing: 8) {
                Button {
                    Task { await session.connectSoundCloudPublicMode() }
                } label: {
                    Image(systemName: "globe")
                }
                .buttonStyle(IconCircleButtonStyle())
                .accessibilityLabel("Use SoundCloud Public Mode")

                Button {
                    Task { await session.connectSoundCloudDemoMode() }
                } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(IconCircleButtonStyle())
                .accessibilityLabel("Use Demo Mode")
            }
        }
    }

    private func statusToast(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: message.isLikelyError ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .foregroundStyle(message.isLikelyError ? CloudTheme.warning : CloudTheme.success)
            Text(message)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(CloudTheme.ink)
                .lineLimit(2)

            if message.needsSoundCloudReconnect {
                Spacer(minLength: 4)
                Button {
                    Task { await session.reconnectSoundCloud() }
                } label: {
                    Label("Reconnect", systemImage: "link")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(IconCircleButtonStyle())
                .accessibilityLabel("Reconnect SoundCloud")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(CloudTheme.shell.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.45), lineWidth: 1)
        )
            .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 3)
    }

    private var settingsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsInfoRow(title: "SoundCloud", value: session.soundCloudModeLabel)
                        SettingsInfoRow(title: "Last.fm", value: session.lastFMConnected ? "Connected" : "Off")
                        SettingsInfoRow(title: "Pending scrobbles", value: "\(pendingLastFMScrobbles)")
                        SettingsInfoRow(title: "Worker", value: session.tokenBrokerDisplayURL)
                    }
                    .cloudCard()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Connections")
                            .font(.system(.headline, design: .rounded).weight(.bold))
                            .foregroundStyle(CloudTheme.ink)

                        connectionActions

                        if session.soundCloudConnected && session.soundCloudPublicMode {
                            Text("Public Mode active: search/playback enabled, private /me endpoints disabled.")
                                .font(.system(.caption2, design: .serif))
                                .foregroundStyle(CloudTheme.muted)
                        }

                        if session.soundCloudConnected && session.soundCloudMockMode {
                            Text("Demo Mode active: mock catalog only. Connect SoundCloud or Public Mode for real audio.")
                                .font(.system(.caption2, design: .serif))
                                .foregroundStyle(CloudTheme.muted)
                        }

                        if !session.isConfigured {
                            Text("Set app config values and start backend at `SOUNDCLOUD_TOKEN_BROKER_BASE_URL`.")
                                .font(.system(.caption2, design: .serif))
                                .foregroundStyle(CloudTheme.warning)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cloudCard()

                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            Task {
                                await session.refreshConnectionState()
                                await refreshDiagnostics()
                            }
                        } label: {
                            Label("Refresh status", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(SecondaryPillButtonStyle())

                        Button {
                            Task {
                                await session.reconnectSoundCloud()
                                await refreshDiagnostics()
                            }
                        } label: {
                            Label("Reconnect SoundCloud", systemImage: "link")
                        }
                        .buttonStyle(SecondaryPillButtonStyle())

                        Button {
                            Task {
                                await session.disconnectSoundCloud()
                                await refreshDiagnostics()
                            }
                        } label: {
                            Label("Reset SoundCloud", systemImage: "link.badge.minus")
                        }
                        .buttonStyle(SecondaryPillButtonStyle())

                        Button {
                            Task {
                                await session.disconnectLastFM()
                                await refreshDiagnostics()
                            }
                        } label: {
                            Label("Reset Last.fm", systemImage: "dot.radiowaves.left.and.right")
                        }
                        .buttonStyle(SecondaryPillButtonStyle())

                        Button {
                            Task {
                                await session.resetConnections()
                                await refreshDiagnostics()
                            }
                        } label: {
                            Label("Reset all connections", systemImage: "trash")
                        }
                        .buttonStyle(SecondaryPillButtonStyle())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cloudCard()
                }
                .padding(16)
            }
            .background(CloudBackdrop())
            .navigationTitle("Settings")
            .cloudInlineNavigationTitle()
            .toolbar {
#if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        showSettingsSheet = false
                    }
                }
#else
                ToolbarItem {
                    Button("Close") {
                        showSettingsSheet = false
                    }
                }
#endif
            }
            .task {
                await refreshDiagnostics()
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var lastFMSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Last.fm Credentials")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(CloudTheme.ink)
                Text("Required for `updateNowPlaying` and `track.scrobble`.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(CloudTheme.muted)

                TextField("Last.fm username", text: $lastFMUsername)
                    .cloudCredentialField()
                    .textContentType(.username)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(CloudTheme.elevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(CloudTheme.line, lineWidth: 1)
                    )

                SecureField("Last.fm password", text: $lastFMPassword)
                    .cloudCredentialField()
                    .textContentType(.password)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(CloudTheme.elevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(CloudTheme.line, lineWidth: 1)
                    )

                Button {
                    Task {
                        await session.connectLastFM(username: lastFMUsername, password: lastFMPassword)
                        if session.lastFMConnected {
                            showLastFMSheet = false
                        }
                    }
                } label: {
                    Label("Connect Last.fm", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(PrimaryPillButtonStyle())

                Spacer(minLength: 0)
            }
            .padding(16)
            .background(CloudBackdrop())
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

    private func refreshDiagnostics() async {
        pendingLastFMScrobbles = await session.pendingLastFMScrobbleCount()
    }
}

private struct MiniPlayerBar: View {
    @ObservedObject var controller: PlayerScrobbleController
    let onOpenPlayer: () -> Void

    var body: some View {
        if let item = controller.currentItem {
            HStack(spacing: 10) {
                AsyncImage(url: item.artworkURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(CloudTheme.elevatedStrong)
                            .overlay(Image(systemName: "music.note").foregroundStyle(CloudTheme.sky))
                    }
                }
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(CloudTheme.ink)
                        .lineLimit(1)
                    Text(item.artistDisplay)
                        .font(.system(.caption2, design: .rounded).weight(.semibold))
                        .foregroundStyle(CloudTheme.muted)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpenPlayer)

                Spacer(minLength: 8)

                Button {
                    controller.togglePlayback()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(IconCircleButtonStyle())
                .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

                Button {
                    controller.next()
                } label: {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(IconCircleButtonStyle())
                .accessibilityLabel("Next track")
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(CloudTheme.shell.opacity(0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 10)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpenPlayer)
            .accessibilityLabel("Open player")
        }
    }
}

private struct SettingsInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(.caption2, design: .rounded).weight(.bold))
                .foregroundStyle(CloudTheme.muted)
                .textCase(.uppercase)
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(CloudTheme.ink)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            || lowered.contains("expired")
            || lowered.contains("unavailable")
            || lowered.contains("http 401")
    }

    var needsSoundCloudReconnect: Bool {
        let lowered = lowercased()
        return lowered.contains("soundcloud session expired")
            || lowered.contains("http 401")
            || lowered.contains("missing or invalid")
    }
}
