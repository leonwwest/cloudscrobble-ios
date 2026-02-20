import AuthenticationServices
import CloudScrobbleCore
import Foundation

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
    @Published var soundCloudConnected = false
    @Published var lastFMConnected = false
    @Published var isBusy = false
    @Published var statusMessage: String?

    let playerController: PlayerScrobbleController

    private(set) var config: AppConfig?
    private let webAuthClient = WebAuthenticationSessionClient()

    private let soundCloudAuthService: SoundCloudAuthService?
    private let soundCloudAPIClient: SoundCloudAPIClient?
    private let playbackResolver: PlaybackResolver?

    private let lastFMAuthService: LastFMAuthService?
    private let lastFMScrobbleService: LastFMScrobbleService?
    private let mutableScrobbler: MutableLastFMScrobbler

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

            let callbackScheme = try callbackScheme(from: config.soundCloudRedirectURI)
            let callbackURL = try await webAuthClient.authenticate(url: authURL, callbackScheme: callbackScheme)
            let query = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []

            guard query.first(where: { $0.name == "state" })?.value == state else {
                throw CloudScrobbleError.oauthStateMismatch
            }
            guard let code = query.first(where: { $0.name == "code" })?.value else {
                throw CloudScrobbleError.oauthCallbackMissingCode
            }

            _ = try await soundCloudAuthService.exchangeAuthorizationCode(
                code,
                codeVerifier: pkce.codeVerifier,
                redirectURI: config.soundCloudRedirectURI
            )

            soundCloudConnected = true
            statusMessage = "SoundCloud connected"
        } catch {
            statusMessage = "SoundCloud login failed: \(friendlySoundCloudAuthError(error))"
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

    private func friendlySoundCloudAuthError(_ error: Error) -> String {
        if let authError = error as? ASWebAuthenticationSessionError {
            switch authError.code {
            case .canceledLogin:
                return "Login was canceled."
            case .presentationContextInvalid:
                return "Invalid auth presentation context. Restart the app and try again."
            case .presentationContextNotProvided:
                return "Auth presentation context not provided."
            @unknown default:
                return authError.localizedDescription
            }
        }

        return error.localizedDescription
    }
}
