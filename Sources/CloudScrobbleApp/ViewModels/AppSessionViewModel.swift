import CloudScrobbleCore
import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

actor MutableLastFMScrobbler: LastFMScrobbleSending {
    var wrapped: LastFMScrobbleSending?

    init(wrapped: LastFMScrobbleSending?) {
        self.wrapped = wrapped
    }

    func setWrapped(_ wrapped: LastFMScrobbleSending?) {
        self.wrapped = wrapped
    }

    func updateNowPlaying(meta: LastFMTrackMeta, durationSeconds: Int?) async throws {
        guard let wrapped else { return }
        try await wrapped.updateNowPlaying(meta: meta, durationSeconds: durationSeconds)
    }

    func scrobble(meta: LastFMTrackMeta, timestamp: Int) async throws {
        guard let wrapped else { return }
        try await wrapped.scrobble(meta: meta, timestamp: timestamp)
    }

    func flushPendingScrobbles() async throws {
        guard let wrapped else { return }
        try await wrapped.flushPendingScrobbles()
    }

    func pendingScrobbleCount() async -> Int {
        guard let wrapped else { return 0 }
        return await wrapped.pendingScrobbleCount()
    }
}

@MainActor
final class AppSessionViewModel: ObservableObject {
    private struct PendingSoundCloudAuthorization {
        let state: String
        let codeVerifier: String
        let redirectURI: String
    }

    @Published var soundCloudConnected = false
    @Published var soundCloudPublicMode = false
    @Published var lastFMConnected = false
    @Published var isBusy = false
    @Published var statusMessage: String?

    let playerController: PlayerScrobbleController

    private(set) var config: AppConfig?
    private let browserClient = SystemBrowserClient()

    private let soundCloudAuthService: SoundCloudAuthService?
    private let soundCloudAPIClient: SoundCloudAPIClient?
    private let playbackResolver: PlaybackResolver?

    private let lastFMAuthService: LastFMAuthService?
    private let lastFMScrobbleService: LastFMScrobbleService?
    private let mutableScrobbler: MutableLastFMScrobbler
    private var pendingSoundCloudAuthorization: PendingSoundCloudAuthorization?

    init(config: AppConfig? = AppConfig.loadFromEnvironment()) {
        self.config = config

        let keychain = KeychainStore(service: "com.cloudscrobble.private")

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

            let lastFMConfig = LastFMConfiguration(
                apiKey: config.lastFMAPIKey,
                apiSecret: config.lastFMAPISecret
            )
            let lastFMAuthService = LastFMAuthService(config: lastFMConfig, keychain: keychain)
            let lastFMScrobbleService = LastFMScrobbleService(
                config: lastFMConfig,
                authService: lastFMAuthService,
                keychain: keychain
            )

            self.soundCloudAuthService = soundCloudAuthService
            self.soundCloudAPIClient = soundCloudAPIClient
            self.playbackResolver = playbackResolver
            self.lastFMAuthService = lastFMAuthService
            self.lastFMScrobbleService = lastFMScrobbleService

            self.mutableScrobbler = MutableLastFMScrobbler(wrapped: lastFMScrobbleService)
        } else {
            self.soundCloudAuthService = nil
            self.soundCloudAPIClient = nil
            self.playbackResolver = nil
            self.lastFMAuthService = nil
            self.lastFMScrobbleService = nil
            self.mutableScrobbler = MutableLastFMScrobbler(wrapped: nil)
            let missing = AppConfig.missingEnvironmentKeys()
            if missing.isEmpty {
                statusMessage = "Missing app configuration. Ensure env vars are set in the Xcode scheme."
            } else {
                statusMessage = "Missing scheme env vars: \(missing.joined(separator: ", "))"
            }
        }

        playerController = PlayerScrobbleController(lastFMScrobbler: mutableScrobbler)

        Task {
            await refreshConnectionState()
        }
    }

    var isConfigured: Bool {
        config != nil
    }

    var apiClient: SoundCloudAPIClienting? {
        soundCloudAPIClient
    }

    func refreshConnectionState() async {
        guard let soundCloudAuthService, let lastFMAuthService else {
            soundCloudConnected = false
            lastFMConnected = false
            return
        }

        soundCloudConnected = await soundCloudAuthService.cachedToken() != nil
        if let token = await soundCloudAuthService.cachedToken() {
            soundCloudPublicMode = token.refreshToken == nil
        } else {
            soundCloudPublicMode = false
        }
        lastFMConnected = await lastFMAuthService.cachedSession() != nil
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

            let callbackScheme = try callbackScheme(from: config.soundCloudRedirectURI)

#if canImport(AuthenticationServices) && canImport(UIKit)
            let callbackURL = try await browserClient.authenticate(
                url: authURL,
                callbackScheme: callbackScheme
            )
            await handleIncomingOAuthCallback(callbackURL)
#else
            try browserClient.open(url: authURL)
            statusMessage = "Continue SoundCloud login in browser and return to the app."
#endif
        } catch {
            pendingSoundCloudAuthorization = nil
            statusMessage = normalizedAuthErrorMessage(error)
        }
    }

    func connectSoundCloudPublicMode() async {
        guard let soundCloudAuthService else {
            statusMessage = "Missing app configuration. Fill .env values first."
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            _ = try await soundCloudAuthService.fetchClientCredentialsToken()
            pendingSoundCloudAuthorization = nil
            soundCloudConnected = true
            soundCloudPublicMode = true
            statusMessage = "SoundCloud connected in Public Mode (no /me library)."
        } catch {
            statusMessage = "Public Mode connection failed: \(error.localizedDescription)"
        }
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
            soundCloudConnected = true
            soundCloudPublicMode = false
            statusMessage = "SoundCloud connected"
        } catch {
            pendingSoundCloudAuthorization = nil
            statusMessage = "SoundCloud callback failed: \(error.localizedDescription)"
        }
    }

    func connectLastFM(username: String, password: String) async {
        guard let lastFMAuthService else {
            statusMessage = "Missing Last.fm configuration."
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            _ = try await lastFMAuthService.authenticate(username: username, password: password)
            try await mutableScrobbler.flushPendingScrobbles()
            let pending = await mutableScrobbler.pendingScrobbleCount()
            lastFMConnected = true
            statusMessage = pending == 0 ? "Last.fm connected" : "Last.fm connected (\(pending) pending scrobbles)"
        } catch {
            statusMessage = "Last.fm login failed: \(error.localizedDescription)"
        }
    }

    func disconnectSoundCloud() async {
        guard let soundCloudAuthService else { return }
        try? await soundCloudAuthService.clearCachedToken()
        soundCloudConnected = false
        soundCloudPublicMode = false
    }

    func disconnectLastFM() async {
        guard let lastFMAuthService else { return }
        try? await lastFMAuthService.clearSession()
        lastFMConnected = false
    }

    func play(track: SCTrack) async {
        guard let playbackResolver else {
            statusMessage = "Playback resolver unavailable"
            return
        }

        do {
            let streamURL = try await playbackResolver.resolvePlayableURL(for: track.urn)
            let meta = MetadataMapper.mapLastFM(track: track)
            let queueItem = QueueItem(
                trackURN: track.urn,
                title: track.title,
                artistDisplay: track.user.username,
                artworkURL: track.artworkURL,
                permalinkURL: track.permalinkURL,
                streamURL: streamURL,
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
        guard let playbackResolver else {
            statusMessage = "Playback resolver unavailable"
            return
        }

        do {
            var queueItems: [QueueItem] = []
            queueItems.reserveCapacity(tracks.count)

            for track in tracks {
                let streamURL = try await playbackResolver.resolvePlayableURL(for: track.urn)
                queueItems.append(
                    QueueItem(
                        trackURN: track.urn,
                        title: track.title,
                        artistDisplay: track.user.username,
                        artworkURL: track.artworkURL,
                        permalinkURL: track.permalinkURL,
                        streamURL: streamURL,
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
#if canImport(AuthenticationServices)
        let nsError = error as NSError
        if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
           nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
            return "SoundCloud login canceled."
        }
#endif
        return "SoundCloud login failed: \(error.localizedDescription)"
    }
}
