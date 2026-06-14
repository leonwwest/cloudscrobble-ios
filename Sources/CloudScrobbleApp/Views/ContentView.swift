import CloudScrobbleCore
import SwiftUI

struct ContentView: View {
    private enum AppTab {
        case home
        case search
        case library
        case player
    }

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = AppSessionViewModel()
    @AppStorage("cloudscrobble.didShowOnboarding.v1") private var didShowOnboarding = false

    @State private var lastFMUsername = ""
    @State private var lastFMPassword = ""
    @State private var showLastFMSheet = false
    @State private var showSettingsSheet = false
    @State private var showOnboardingSheet = false
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
        .sheet(isPresented: $showOnboardingSheet) {
            onboardingSheet
        }
        .task {
            await session.refreshConnectionState()
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.84)) {
                deckVisible = true
            }
            if !didShowOnboarding {
                didShowOnboarding = true
                showOnboardingSheet = true
            }
        }
        .onOpenURL { url in
            Task {
                await session.handleIncomingOAuthCallback(url)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await session.retryPendingLastFMScrobbles()
                await refreshDiagnostics()
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
                StatusBadge(title: session.networkStatusLabel, isConnected: session.isNetworkReachable)
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
                        SettingsInfoRow(title: "Network", value: session.networkStatusLabel)
                        SettingsInfoRow(title: "Pending scrobbles", value: "\(pendingLastFMScrobbles)")
                        if let lastScrobbleSucceededAt = session.playerController.lastScrobbleSucceededAt {
                            SettingsInfoRow(title: "Last scrobble", value: scrobbleDateText(lastScrobbleSucceededAt))
                        }
                        if let lastScrobbleError = session.playerController.lastScrobbleError {
                            SettingsInfoRow(title: "Last.fm error", value: lastScrobbleError)
                        }
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
                            Text("Set SoundCloud app config values and rebuild the app.")
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

    private var onboardingSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("CloudScrobble einrichten")
                            .font(.system(.title2, design: .rounded).weight(.black))
                            .foregroundStyle(CloudTheme.ink)
                        Text("Verbinde SoundCloud fürs echte Playback und Last.fm für Now Playing plus Scrobbles.")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(CloudTheme.muted)
                            .lineSpacing(2)
                    }
                    .cloudCard()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Verbindungen")
                            .font(.system(.headline, design: .rounded).weight(.bold))
                            .foregroundStyle(CloudTheme.ink)
                        connectionActions
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cloudCard()

                    VStack(alignment: .leading, spacing: 8) {
                        SettingsInfoRow(title: "Feed", value: "Du kannst Tracks ausblenden und Artists boosten oder reduzieren.")
                        SettingsInfoRow(title: "Scrobbles", value: "Im Player siehst du gesendete, queued und fehlgeschlagene Events.")
                        SettingsInfoRow(title: "Offline", value: "Die App zeigt Netzwerkstatus und cached Cover im Feed.")
                    }
                    .cloudCard()

                    Button {
                        showOnboardingSheet = false
                    } label: {
                        Label("Loslegen", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(PrimaryPillButtonStyle())
                }
                .padding(16)
            }
            .background(CloudBackdrop())
            .navigationTitle("Setup")
            .cloudInlineNavigationTitle()
            .toolbar {
#if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        showOnboardingSheet = false
                    }
                }
#else
                ToolbarItem {
                    Button("Close") {
                        showOnboardingSheet = false
                    }
                }
#endif
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
        await session.playerController.refreshLastFMDiagnostics()
        pendingLastFMScrobbles = await session.pendingLastFMScrobbleCount()
    }

    private func scrobbleDateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct MiniPlayerBar: View {
    @ObservedObject var controller: PlayerScrobbleController
    let onOpenPlayer: () -> Void

    var body: some View {
        if let item = controller.currentItem {
            HStack(spacing: 10) {
                CachedArtworkImage(url: item.artworkURL, iconName: "music.note", maxPixelSize: 180)
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
                    Text(miniStatusText)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(controller.lastScrobbleError == nil ? CloudTheme.seafoam : CloudTheme.warning)
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

    private var miniStatusText: String {
        var parts: [String] = []
        if let currentIndex = controller.currentIndex, !controller.queue.isEmpty {
            parts.append("\(currentIndex + 1)/\(controller.queue.count)")
        }
        if controller.pendingScrobbleCount > 0 {
            parts.append("\(controller.pendingScrobbleCount) pending")
        } else if controller.lastScrobbleError != nil {
            parts.append("Scrobble error")
        } else if controller.lastScrobbleSucceededAt != nil {
            parts.append("Scrobble OK")
        }
        return parts.isEmpty ? "Ready" : parts.joined(separator: " - ")
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
