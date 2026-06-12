import CloudScrobbleCore
import Foundation

@MainActor
final class AppSessionViewModel: ObservableObject {
    private struct PendingSoundCloudAuthorization {
        let state: String
        let codeVerifier: String
        let redirectURI: String
    }

    @Published var soundCloudConnected = false
    @Published var soundCloudPublicMode = false
    @Published var soundCloudMockMode = false
    @Published var lastFMConnected = false
    @Published var isBusy = false
    @Published var statusMessage: String? {
        didSet {
            scheduleStatusDismissal(for: statusMessage)
        }
    }

    let playerController: PlayerScrobbleController

    private(set) var config: AppConfig?
    private let browserClient = SystemBrowserClient()

    private let soundCloudAuthService: SoundCloudAuthService?
    private let realSoundCloudAPIClient: SoundCloudAPIClient?
    private let realPlaybackResolver: PlaybackResolver?
    private let mockSoundCloudAPIClient: MockSoundCloudAPIClient
    private let mockPlaybackResolver: PlaybackResolver
    private var activeSoundCloudAPIClient: SoundCloudAPIClienting?
    private var activePlaybackResolver: PlaybackResolving?

    private let lastFMAuthService: LastFMAuthenticating?
    private let lastFMScrobbleService: LastFMScrobbleSending?
    private var pendingSoundCloudAuthorization: PendingSoundCloudAuthorization?
    private var statusDismissalTask: Task<Void, Never>?
    private var didAttemptPlaybackRestore = false

    init(config: AppConfig? = AppConfig.load()) {
        self.config = config

        let keychain = KeychainStore(service: "com.cloudscrobble.private")
        let mockSoundCloudAPIClient = MockSoundCloudAPIClient()
        self.mockSoundCloudAPIClient = mockSoundCloudAPIClient
        self.mockPlaybackResolver = PlaybackResolver(api: mockSoundCloudAPIClient)

        if let config {
            let soundCloudAuthService = SoundCloudAuthService(
                config: SoundCloudAuthConfiguration(
                    clientID: config.soundCloudClientID,
                    tokenBrokerBaseURL: config.tokenBrokerBaseURL
                ),
                keychain: keychain
            )
            let tokenProvider = SoundCloudTokenProvider(authService: soundCloudAuthService)
            let soundCloudAPIClient = SoundCloudAPIClient(tokenProvider: tokenProvider)
            let playbackResolver = PlaybackResolver(api: soundCloudAPIClient)

            let lastFMAuthService = LastFMProxyAuthService(
                baseURL: config.tokenBrokerBaseURL,
                keychain: keychain
            )
            let lastFMScrobbleService = LastFMProxyScrobbleService(
                baseURL: config.tokenBrokerBaseURL,
                authService: lastFMAuthService,
                keychain: keychain
            )

            self.soundCloudAuthService = soundCloudAuthService
            self.realSoundCloudAPIClient = soundCloudAPIClient
            self.realPlaybackResolver = playbackResolver
            self.lastFMAuthService = lastFMAuthService
            self.lastFMScrobbleService = lastFMScrobbleService
        } else {
            self.soundCloudAuthService = nil
            self.realSoundCloudAPIClient = nil
            self.realPlaybackResolver = nil
            self.lastFMAuthService = nil
            self.lastFMScrobbleService = nil
            let missing = AppConfig.missingConfigurationKeys()
            if missing.isEmpty {
                statusMessage = "Missing app configuration. Demo Mode can still be used without SoundCloud API."
            } else {
                statusMessage = "Missing app config values: \(missing.joined(separator: ", ")). Demo Mode is available."
            }
        }

        self.activeSoundCloudAPIClient = nil
        self.activePlaybackResolver = nil

        playerController = PlayerScrobbleController(lastFMScrobbler: nil)

        Task {
            await refreshConnectionState()
        }
    }

    var isConfigured: Bool {
        config != nil
    }

    var tokenBrokerDisplayURL: String {
        config?.tokenBrokerBaseURL.absoluteString ?? "Missing"
    }

    var soundCloudModeLabel: String {
        if soundCloudMockMode {
            return "Demo"
        }
        if soundCloudPublicMode {
            return "Public"
        }
        return soundCloudConnected ? "Authenticated" : "Off"
    }

    var apiClient: SoundCloudAPIClienting? {
        guard soundCloudConnected else { return nil }
        return activeSoundCloudAPIClient
    }

    func clearStatusMessage() {
        statusMessage = nil
    }

    func pendingLastFMScrobbleCount() async -> Int {
        guard let lastFMScrobbleService else { return 0 }
        return await lastFMScrobbleService.pendingScrobbleCount()
    }

    func resetConnections() async {
        await disconnectSoundCloud()
        await disconnectLastFM()
        statusMessage = "Connections reset"
    }

    func refreshConnectionState() async {
        if soundCloudMockMode {
            activateMockMode()
        } else if let soundCloudAuthService {
            if let token = await soundCloudAuthService.cachedToken() {
                activateRealMode(isPublicMode: token.refreshToken == nil)
            } else {
                deactivateSoundCloudMode()
            }
        } else {
            deactivateSoundCloudMode()
        }

        guard let lastFMAuthService else {
            lastFMConnected = false
            playerController.setLastFMScrobbler(nil)
            return
        }
        let hasLastFMSession = await lastFMAuthService.cachedSession() != nil
        lastFMConnected = hasLastFMSession
        playerController.setLastFMScrobbler(hasLastFMSession ? lastFMScrobbleService : nil)

        await restoreSavedPlaybackIfPossible()
    }

    func connectSoundCloud() async {
        guard let config, let soundCloudAuthService else {
            statusMessage = "Missing app configuration. Fill .env values first."
            return
        }

        do {
            let callbackScheme = try callbackScheme(from: config.soundCloudRedirectURI)
            try validateRedirectSchemeRegistration(callbackScheme)
        } catch {
            statusMessage = "SoundCloud config error: \(error.localizedDescription)"
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let pkce = PKCE.generate()
            let state = PKCE.randomState()
            let authURL = try await soundCloudAuthService.makeAuthorizationURL(
                codeChallenge: pkce.codeChallenge,
                state: state,
                redirectURI: config.soundCloudRedirectURI
            )

            pendingSoundCloudAuthorization = PendingSoundCloudAuthorization(
                state: state,
                codeVerifier: pkce.codeVerifier,
                redirectURI: config.soundCloudRedirectURI
            )

            _ = try callbackScheme(from: config.soundCloudRedirectURI)
            try browserClient.open(url: authURL)
            statusMessage = "Continue SoundCloud login in browser and return to the app."
        } catch {
            pendingSoundCloudAuthorization = nil
            statusMessage = normalizedAuthErrorMessage(error)
        }
    }

    func connectSoundCloudPublicMode() async {
        guard let soundCloudAuthService, realSoundCloudAPIClient != nil, realPlaybackResolver != nil else {
            statusMessage = "Missing app configuration. Fill .env values first."
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            _ = try await soundCloudAuthService.fetchClientCredentialsToken()
            pendingSoundCloudAuthorization = nil
            activateRealMode(isPublicMode: true)
            await restoreSavedPlaybackIfPossible()
            statusMessage = "SoundCloud connected in Public Mode (no /me library)."
        } catch {
            statusMessage = "Public Mode connection failed: \(error.localizedDescription)"
        }
    }

    func connectSoundCloudDemoMode() async {
        pendingSoundCloudAuthorization = nil
        activateMockMode()
        statusMessage = "Demo Mode enabled: local mock catalog + test stream are active."
    }

    func handleIncomingOAuthCallback(_ url: URL) async {
        guard let soundCloudAuthService, let pending = pendingSoundCloudAuthorization else {
            return
        }

        do {
            let expectedScheme = try callbackScheme(from: pending.redirectURI)
            guard url.scheme?.lowercased() == expectedScheme.lowercased() else {
                return
            }

            let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let oauthError = queryItems.first(where: { $0.name == "error" })?.value {
                pendingSoundCloudAuthorization = nil
                statusMessage = "SoundCloud authorization failed: \(oauthError)"
                return
            }

            guard queryItems.first(where: { $0.name == "state" })?.value == pending.state else {
                pendingSoundCloudAuthorization = nil
                throw CloudScrobbleError.oauthStateMismatch
            }

            guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                pendingSoundCloudAuthorization = nil
                throw CloudScrobbleError.oauthCallbackMissingCode
            }

            _ = try await soundCloudAuthService.exchangeAuthorizationCode(
                code,
                codeVerifier: pending.codeVerifier,
                redirectURI: pending.redirectURI
            )

            pendingSoundCloudAuthorization = nil
            activateRealMode(isPublicMode: false)
            await restoreSavedPlaybackIfPossible()
            statusMessage = "SoundCloud connected"
        } catch {
            pendingSoundCloudAuthorization = nil
            statusMessage = "SoundCloud callback failed: \(error.localizedDescription)"
        }
    }

    func connectLastFM(username: String, password: String) async {
        guard let lastFMAuthService, let lastFMScrobbleService else {
            statusMessage = "Missing Last.fm configuration."
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            _ = try await lastFMAuthService.authenticate(username: username, password: password)
            playerController.setLastFMScrobbler(lastFMScrobbleService)
            try await lastFMScrobbleService.flushPendingScrobbles()
            let pending = await lastFMScrobbleService.pendingScrobbleCount()
            lastFMConnected = true
            statusMessage = pending == 0 ? "Last.fm connected" : "Last.fm connected (\(pending) pending scrobbles)"
        } catch {
            statusMessage = "Last.fm login failed: \(error.localizedDescription)"
        }
    }

    func disconnectSoundCloud() async {
        if let soundCloudAuthService {
            try? await soundCloudAuthService.clearCachedToken()
        }
        pendingSoundCloudAuthorization = nil
        playerController.clearSavedPlaybackSnapshot()
        deactivateSoundCloudMode()
    }

    func disconnectLastFM() async {
        guard let lastFMAuthService else { return }
        try? await lastFMAuthService.clearSession()
        lastFMConnected = false
        playerController.setLastFMScrobbler(nil)
    }

    func play(track: SCTrack) async {
        guard let playbackResolver = activePlaybackResolver else {
            statusMessage = "Playback resolver unavailable"
            return
        }

        do {
            let stream = try await playbackResolver.resolvePlayableStream(for: track.urn)
            let meta = MetadataMapper.mapLastFM(track: track)
            let queueItem = QueueItem(
                trackURN: track.urn,
                title: track.title,
                artistDisplay: track.user.username,
                artworkURL: track.artworkURL,
                permalinkURL: track.permalinkURL,
                streamURL: stream.url,
                streamHeaders: stream.headers,
                durationSeconds: max(0, track.durationMs / 1000),
                lastFM: meta
            )
            playerController.loadQueue([queueItem], startAt: 0)
            statusMessage = "Playing \(track.title)"
        } catch {
            statusMessage = "Playback failed: \(error.localizedDescription)"
        }
    }

    func play(tracks: [SCTrack], startAt: Int = 0) async {
        guard let playbackResolver = activePlaybackResolver else {
            statusMessage = "Playback resolver unavailable"
            return
        }

        do {
            var queueItems: [QueueItem] = []
            queueItems.reserveCapacity(tracks.count)

            for track in tracks {
                let stream = try await playbackResolver.resolvePlayableStream(for: track.urn)
                queueItems.append(
                    QueueItem(
                        trackURN: track.urn,
                        title: track.title,
                        artistDisplay: track.user.username,
                        artworkURL: track.artworkURL,
                        permalinkURL: track.permalinkURL,
                        streamURL: stream.url,
                        streamHeaders: stream.headers,
                        durationSeconds: max(0, track.durationMs / 1000),
                        lastFM: MetadataMapper.mapLastFM(track: track)
                    )
                )
            }

            playerController.loadQueue(queueItems, startAt: startAt)
            statusMessage = "Loaded \(queueItems.count) tracks"
        } catch {
            statusMessage = "Queue loading failed: \(error.localizedDescription)"
        }
    }

    private func callbackScheme(from redirectURI: String) throws -> String {
        guard let components = URLComponents(string: redirectURI),
              let scheme = components.scheme,
              !scheme.isEmpty else {
            throw CloudScrobbleError.invalidConfiguration("SOUNDCLOUD_REDIRECT_URI must include a scheme")
        }
        return scheme
    }

    private func validateRedirectSchemeRegistration(_ scheme: String) throws {
        guard let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
            throw CloudScrobbleError.invalidConfiguration(
                "App URL schemes are not configured. Add \(scheme) to CFBundleURLTypes."
            )
        }

        let schemes = urlTypes
            .compactMap { $0["CFBundleURLSchemes"] as? [String] }
            .flatMap { $0 }
            .map { $0.lowercased() }

        guard schemes.contains(scheme.lowercased()) else {
            throw CloudScrobbleError.invalidConfiguration(
                "Missing URL scheme \(scheme). Register it in Info.plist CFBundleURLTypes."
            )
        }
    }

    private func normalizedAuthErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return "SoundCloud login canceled."
        }
        return "SoundCloud login failed: \(error.localizedDescription)"
    }

    private func restoreSavedPlaybackIfPossible() async {
        guard !didAttemptPlaybackRestore,
              soundCloudConnected,
              !soundCloudMockMode,
              !playerController.hasLoadedQueue,
              let playbackResolver = activePlaybackResolver,
              let snapshot = playerController.savedPlaybackSnapshot(),
              snapshot.queue.indices.contains(snapshot.currentIndex) else {
            return
        }

        didAttemptPlaybackRestore = true

        do {
            var queueItems: [QueueItem] = []
            queueItems.reserveCapacity(snapshot.queue.count)

            for savedTrack in snapshot.queue {
                let stream = try await playbackResolver.resolvePlayableStream(for: savedTrack.trackURN)
                queueItems.append(
                    QueueItem(
                        trackURN: savedTrack.trackURN,
                        title: savedTrack.title,
                        artistDisplay: savedTrack.artistDisplay,
                        artworkURL: savedTrack.artworkURL,
                        permalinkURL: savedTrack.permalinkURL,
                        streamURL: stream.url,
                        streamHeaders: stream.headers,
                        durationSeconds: savedTrack.durationSeconds,
                        lastFM: savedTrack.lastFM
                    )
                )
            }

            playerController.restoreSavedQueue(queueItems, from: snapshot)
            statusMessage = "Restored saved queue"
        } catch {
            playerController.clearSavedPlaybackSnapshot()
            statusMessage = "Saved queue could not be restored: \(error.localizedDescription)"
        }
    }

    private func scheduleStatusDismissal(for message: String?) {
        statusDismissalTask?.cancel()
        guard let message else {
            statusDismissalTask = nil
            return
        }

        let delay = statusDismissalDelay(for: message)
        statusDismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, self?.statusMessage == message else { return }
            self?.statusMessage = nil
        }
    }

    private func statusDismissalDelay(for message: String) -> UInt64 {
        message.isLikelyErrorStatus ? 5_500_000_000 : 2_800_000_000
    }

    private func activateRealMode(isPublicMode: Bool) {
        guard let realSoundCloudAPIClient, let realPlaybackResolver else {
            deactivateSoundCloudMode()
            return
        }

        activeSoundCloudAPIClient = realSoundCloudAPIClient
        activePlaybackResolver = realPlaybackResolver
        soundCloudConnected = true
        soundCloudPublicMode = isPublicMode
        soundCloudMockMode = false
    }

    private func activateMockMode() {
        activeSoundCloudAPIClient = mockSoundCloudAPIClient
        activePlaybackResolver = mockPlaybackResolver
        soundCloudConnected = true
        soundCloudPublicMode = false
        soundCloudMockMode = true
    }

    private func deactivateSoundCloudMode() {
        activeSoundCloudAPIClient = nil
        activePlaybackResolver = nil
        soundCloudConnected = false
        soundCloudPublicMode = false
        soundCloudMockMode = false
    }
}

private extension String {
    var isLikelyErrorStatus: Bool {
        let lowered = lowercased()
        return lowered.contains("error")
            || lowered.contains("failed")
            || lowered.contains("missing")
            || lowered.contains("invalid")
            || lowered.contains("canceled")
            || lowered.contains("unavailable")
    }
}
