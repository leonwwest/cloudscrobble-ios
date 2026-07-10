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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var session: AppSessionViewModel
    @StateObject private var homeViewModel: HomeViewModel
    @StateObject private var searchViewModel: SearchViewModel
    @StateObject private var libraryViewModel: LibraryViewModel
    @AppStorage("cloudscrobble.didShowOnboarding.v1") private var didShowOnboarding = false

    @State private var lastFMUsername = ""
    @State private var lastFMPassword = ""
    @State private var showLastFMSheet = false
    @State private var showSettingsSheet = false
    @State private var showOnboardingSheet = false
    @State private var showDiagnosticsSheet = false
    @State private var showResetSoundCloudConfirmation = false
    @State private var showResetLastFMConfirmation = false
    @State private var showResetAllConfirmation = false
    @State private var showResetScrobblePreferencesConfirmation = false
    @State private var deckVisible = false
    @State private var pendingLastFMScrobbles = 0
    @State private var selectedTab: AppTab = .home

    init() {
        let session = AppSessionViewModel()
        _session = StateObject(wrappedValue: session)
        _homeViewModel = StateObject(wrappedValue: HomeViewModel(session: session))
        _searchViewModel = StateObject(wrappedValue: SearchViewModel(session: session))
        _libraryViewModel = StateObject(wrappedValue: LibraryViewModel(session: session))
    }

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
                        HomeView(session: session, viewModel: homeViewModel)
                            .tabItem { Label("Start", systemImage: "house.fill") }
                            .tag(AppTab.home)

                        SearchView(viewModel: searchViewModel)
                            .tabItem { Label("Search", systemImage: "magnifyingglass") }
                            .tag(AppTab.search)

                        LibraryView(
                            session: session,
                            viewModel: libraryViewModel,
                            onOpenSearch: {
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                                    selectedTab = .search
                                }
                            }
                        )
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
                        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.86)) {
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
            withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.84)) {
                deckVisible = true
            }
            if !didShowOnboarding || ProcessInfo.processInfo.arguments.contains("-cloudscrobble-show-onboarding") {
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
                    Text(LocalizedStringKey(session.isConfigured ? "SoundCloud + Last.fm" : "Config missing"))
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
                .accessibilityIdentifier("settings-button")
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
        ConnectionSetupPanel(
            session: session,
            onFullLogin: {
                Task { await session.connectSoundCloud() }
            },
            onPublicMode: {
                Task { await session.connectSoundCloudPublicMode() }
            },
            onDemoMode: {
                Task { await session.connectSoundCloudDemoMode() }
            },
            onDisconnectSoundCloud: {
                Task { await session.disconnectSoundCloud() }
            },
            onLastFM: {
                if session.lastFMConnected {
                    Task { await session.disconnectLastFM() }
                } else {
                    showLastFMSheet = true
                }
            }
        )
    }

    private func statusToast(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: message.isLikelyError ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .foregroundStyle(message.isLikelyError ? CloudTheme.warning : CloudTheme.success)
            Text(LocalizedStringKey(message))
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
                        SettingsInfoRow(title: "Playback", value: playbackStatusText)
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
                            SettingsHintText("Public Mode keeps Search and playback available, while Library stays locked until full SoundCloud login.")
                        }

                        if session.soundCloudConnected && session.soundCloudMockMode {
                            SettingsHintText("Demo Mode uses local sample data only. Switch to Public Mode or full login for real audio.")
                        }

                        if !session.isConfigured {
                            SettingsHintText("Set SoundCloud app config values and rebuild the app.", isWarning: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cloudCard()

                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            showDiagnosticsSheet = true
                        } label: {
                            Label("Open diagnostics", systemImage: "stethoscope")
                        }
                        .buttonStyle(SecondaryPillButtonStyle())
                        .accessibilityIdentifier("open-diagnostics-button")

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
                            showResetScrobblePreferencesConfirmation = true
                        } label: {
                            Label("Reset scrobble corrections", systemImage: "pencil.slash")
                        }
                        .buttonStyle(SecondaryPillButtonStyle())

                        Button {
                            showResetSoundCloudConfirmation = true
                        } label: {
                            Label("Reset SoundCloud", systemImage: "link.badge.minus")
                        }
                        .buttonStyle(SecondaryPillButtonStyle())

                        Button {
                            showResetLastFMConfirmation = true
                        } label: {
                            Label("Reset Last.fm", systemImage: "dot.radiowaves.left.and.right")
                        }
                        .buttonStyle(SecondaryPillButtonStyle())

                        Button {
                            showResetAllConfirmation = true
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
            .sheet(isPresented: $showDiagnosticsSheet) {
                diagnosticsSheet
            }
        }
        .presentationDetents([.medium, .large])
        .confirmationDialog(
            "Reset SoundCloud connection?",
            isPresented: $showResetSoundCloudConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset SoundCloud", role: .destructive) {
                Task {
                    await session.disconnectSoundCloud()
                    await refreshDiagnostics()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Playback stops restoring until SoundCloud is connected again.")
        }
        .confirmationDialog(
            "Reset Last.fm connection?",
            isPresented: $showResetLastFMConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Last.fm", role: .destructive) {
                Task {
                    await session.disconnectLastFM()
                    await refreshDiagnostics()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved Last.fm session is removed. Pending scrobbles stay on this device.")
        }
        .confirmationDialog(
            "Reset all connections?",
            isPresented: $showResetAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset all connections", role: .destructive) {
                Task {
                    await session.resetConnections()
                    await refreshDiagnostics()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("SoundCloud and Last.fm must be connected again afterwards.")
        }
        .confirmationDialog(
            "Reset all scrobble corrections?",
            isPresented: $showResetScrobblePreferencesConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset scrobble corrections", role: .destructive) {
                Task {
                    await session.resetAllScrobblePreferences()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved metadata edits and track or artist exclusions will be removed. Existing Last.fm scrobbles are not changed.")
        }
    }

    private var onboardingSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Set up CloudScrobble")
                            .font(.system(.title2, design: .rounded).weight(.black))
                            .foregroundStyle(CloudTheme.ink)
                            .accessibilityIdentifier("onboarding-title")
                        Text("Choose how you want to use SoundCloud first. You can connect Last.fm for scrobbles right after.")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(CloudTheme.muted)
                            .lineSpacing(2)
                    }
                    .cloudCard()

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Step 1 of 2 · SoundCloud", systemImage: session.soundCloudConnected ? "checkmark.circle.fill" : "1.circle.fill")
                            .font(.system(.headline, design: .rounded).weight(.bold))
                            .foregroundStyle(CloudTheme.ink)
                        connectionActions
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cloudCard()

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Step 2 of 2 · Last.fm is optional", systemImage: session.lastFMConnected ? "checkmark.circle.fill" : "2.circle")
                            .font(.system(.headline, design: .rounded).weight(.bold))
                            .foregroundStyle(CloudTheme.ink)
                        SettingsInfoRow(title: "Feed", value: "You can hide tracks and boost or reduce artists.")
                        SettingsInfoRow(title: "Scrobbles", value: "The player stays quiet; see Diagnostics for details.")
                        SettingsInfoRow(title: "Offline", value: "Scrobbles stay queued and are sent later.")
                    }
                    .cloudCard()

                    Button {
                        didShowOnboarding = true
                        showOnboardingSheet = false
                    } label: {
                            Label(
                                LocalizedStringKey(session.soundCloudConnected ? "Get started" : "Continue without connection"),
                            systemImage: "checkmark.circle.fill"
                        )
                    }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .accessibilityIdentifier("onboarding-get-started-button")
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
                Text("Connect Last.fm")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(CloudTheme.ink)
                Text("CloudScrobble uses Last.fm for Now Playing and scrobbles. Playback works without Last.fm too.")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(CloudTheme.muted)

                LastFMSecurityNote()

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
                            lastFMPassword = ""
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

    private var diagnosticsSheet: some View {
        ScrobbleDiagnosticsView(controller: session.playerController) {
            Task { await refreshDiagnostics() }
        }
    }

    private func refreshDiagnostics() async {
        await session.playerController.refreshLastFMDiagnostics()
        pendingLastFMScrobbles = await session.pendingLastFMScrobbleCount()
    }

    private func scrobbleDateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private var playbackStatusText: String {
        if session.playerController.pendingScrobbleCount > 0 {
            return "\(session.playerController.pendingScrobbleCount) queued scrobbles"
        }
        if session.playerController.lastScrobbleError != nil {
            return "Last.fm needs attention"
        }
        if session.playerController.lastScrobbleSucceededAt != nil {
            return "Scrobbling is working"
        }
        return session.lastFMConnected ? "Ready to scrobble" : "Playback only"
    }
}

private struct ConnectionSetupPanel: View {
    @ObservedObject var session: AppSessionViewModel

    let onFullLogin: () -> Void
    let onPublicMode: () -> Void
    let onDemoMode: () -> Void
    let onDisconnectSoundCloud: () -> Void
    let onLastFM: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.soundCloudConnected {
                ConnectionModeRow(
                    title: activeModeTitle,
                    subtitle: activeModeSubtitle,
                    icon: activeModeIcon,
                    badge: "Active",
                    isActive: true,
                    isDisabled: true,
                    action: {}
                )

                HStack(spacing: 8) {
                    Button(action: onDisconnectSoundCloud) {
                        Label("Disconnect SoundCloud", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(SecondaryPillButtonStyle())
                    .accessibilityIdentifier("disconnect-soundcloud-button")

                    if session.soundCloudPublicMode || session.soundCloudMockMode {
                        Button(action: onFullLogin) {
                            Label("Full Login", systemImage: "link.circle.fill")
                        }
                        .buttonStyle(PrimaryPillButtonStyle())
                    }
                }
            } else {
                ConnectionModeRow(
                    title: "Full SoundCloud Login",
                    subtitle: "Real playback, personal feed, likes, playlists and library.",
                    icon: "link.circle.fill",
                    badge: "Best",
                    isPrimary: true,
                    accessibilityIdentifier: "connection-full-soundcloud-login",
                    action: onFullLogin
                )

                ConnectionModeRow(
                    title: "Public Test Mode",
                    subtitle: "Real public search and playback. Library stays locked.",
                    icon: "globe",
                    accessibilityIdentifier: "connection-public-test-mode",
                    action: onPublicMode
                )

                ConnectionModeRow(
                    title: "Demo Preview",
                    subtitle: "Local sample catalog only. No SoundCloud audio.",
                    icon: "sparkles",
                    accessibilityIdentifier: "connection-demo-preview",
                    action: onDemoMode
                )
            }

            Divider()
                .overlay(CloudTheme.line)

            ConnectionModeRow(
                title: session.lastFMConnected ? "Last.fm Connected" : "Last.fm Scrobbling",
                subtitle: session.lastFMConnected
                    ? "Now Playing and scrobbles are enabled."
                    : "Optional. Adds Now Playing, scrobble history and offline queue.",
                icon: session.lastFMConnected ? "checkmark.seal.fill" : "dot.radiowaves.left.and.right",
                badge: session.lastFMConnected ? "On" : nil,
                isActive: session.lastFMConnected,
                accessibilityIdentifier: "connection-lastfm-scrobbling",
                action: onLastFM
            )
        }
    }

    private var activeModeTitle: String {
        if session.soundCloudMockMode {
            return "Demo Preview"
        }
        if session.soundCloudPublicMode {
            return "Public Test Mode"
        }
        return "Full SoundCloud Login"
    }

    private var activeModeSubtitle: String {
        if session.soundCloudMockMode {
            return "Sample catalog only. Connect SoundCloud for real streams."
        }
        if session.soundCloudPublicMode {
            return "Public search and playback are available. Library needs full login."
        }
        return "Personal feed, likes, playlists and playback are available."
    }

    private var activeModeIcon: String {
        if session.soundCloudMockMode {
            return "sparkles"
        }
        if session.soundCloudPublicMode {
            return "globe"
        }
        return "link.circle.fill"
    }
}

private struct ConnectionModeRow: View {
    let title: String
    let subtitle: String
    let icon: String
    var badge: String?
    var isPrimary = false
    var isActive = false
    var isDisabled = false
    var accessibilityIdentifier: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(isPrimary ? .white : CloudTheme.sky)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(isPrimary ? CloudTheme.sky : CloudTheme.sky.opacity(0.15)))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(LocalizedStringKey(title))
                            .font(.system(.subheadline, design: .rounded).weight(.black))
                            .foregroundStyle(CloudTheme.ink)
                            .lineLimit(2)

                        if let badge {
                            Text(LocalizedStringKey(badge))
                                .font(.system(size: 10, weight: .black, design: .rounded))
                                .foregroundStyle(isPrimary ? .white : CloudTheme.sky)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule(style: .continuous).fill(CloudTheme.sky.opacity(isPrimary ? 0.95 : 0.16)))
                        }
                    }

                    Text(LocalizedStringKey(subtitle))
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(CloudTheme.muted)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 4)

                Image(systemName: isActive ? "checkmark.circle.fill" : "chevron.right")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(isActive ? CloudTheme.success : CloudTheme.muted)
                    .padding(.top, 3)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isPrimary ? CloudTheme.sky.opacity(0.13) : CloudTheme.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isPrimary ? CloudTheme.sky.opacity(0.35) : CloudTheme.line, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(Text(LocalizedStringKey(title)))
        .accessibilityIdentifier(accessibilityIdentifier ?? title)
    }
}

private struct SettingsHintText: View {
    let text: String
    var isWarning = false

    init(_ text: String, isWarning: Bool = false) {
        self.text = text
        self.isWarning = isWarning
    }

    var body: some View {
            Text(LocalizedStringKey(text))
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .foregroundStyle(isWarning ? CloudTheme.warning : CloudTheme.muted)
            .lineLimit(3)
    }
}

private struct LastFMSecurityNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("What is stored", systemImage: "lock.shield.fill")
                .font(.system(.caption, design: .rounded).weight(.black))
                .foregroundStyle(CloudTheme.ink)

            Text("Your password is only sent to the token broker to obtain a Last.fm session key. The app then stores only that session key in the Keychain.")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(CloudTheme.muted)
                .lineSpacing(2)
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
            Text(LocalizedStringKey(title))
                .font(.system(.caption2, design: .rounded).weight(.bold))
                .foregroundStyle(CloudTheme.muted)
                .textCase(.uppercase)
            Text(LocalizedStringKey(value))
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
