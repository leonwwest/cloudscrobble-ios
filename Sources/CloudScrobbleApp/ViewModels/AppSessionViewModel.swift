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
    private var queueFillTask: Task<Void, Never>?
    private var queueFillGeneration = UUID()
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
        statusMessage = "Demo Mode enabled: mock catalog only. Connect SoundCloud to play real audio."
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
        cancelQueueFill()
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
        cancelQueueFill()

        guard !soundCloudMockMode else {
            statusMessage = "Demo Mode has no audio playback. Connect SoundCloud or use Public Mode."
            return
        }

        guard let playbackResolver = activePlaybackResolver else {
            statusMessage = "Playback resolver unavailable"
            return
        }

        do {
            let queueItem = try await makeQueueItem(for: track, resolver: playbackResolver)
            playerController.loadQueue([queueItem], startAt: 0)
            statusMessage = "Playing \(track.title)"
        } catch {
            statusMessage = "Playback failed: \(error.localizedDescription)"
        }
    }

    func play(tracks: [SCTrack], startAt: Int = 0, maxQueueLength: Int = 25) async {
        cancelQueueFill()

        guard !soundCloudMockMode else {
            statusMessage = "Demo Mode has no audio playback. Connect SoundCloud or use Public Mode."
            return
        }

        guard let playbackResolver = activePlaybackResolver else {
            statusMessage = "Playback resolver unavailable"
            return
        }

        guard !tracks.isEmpty else {
            statusMessage = "No playable tracks"
            return
        }

        let boundedQueue = boundedPlaybackQueue(
            tracks: tracks,
            startAt: startAt,
            maxQueueLength: maxQueueLength
        )

        do {
            var queueItems: [QueueItem] = []
            queueItems.reserveCapacity(boundedQueue.tracks.count)

            for track in boundedQueue.tracks {
                queueItems.append(try await makeQueueItem(for: track, resolver: playbackResolver))
            }

            playerController.loadQueue(queueItems, startAt: boundedQueue.startAt)
            statusMessage = "Loaded \(queueItems.count) tracks"
        } catch {
            statusMessage = "Queue loading failed: \(error.localizedDescription)"
        }
    }

    func playPlaylist(tracks: [SCTrack], startAt: Int = 0) async {
        await playProgressivePlaylist(tracks: tracks, startAt: startAt)
    }

    func playPlaylist(_ playlist: SCPlaylist) async {
        cancelQueueFill()

        guard !soundCloudMockMode else {
            statusMessage = "Demo Mode has no audio playback. Connect SoundCloud or use Public Mode."
            return
        }

        guard let api = apiClient else {
            statusMessage = "Connect SoundCloud first"
            return
        }

        guard let playbackResolver = activePlaybackResolver else {
            statusMessage = "Playback resolver unavailable"
            return
        }

        do {
            let page = try await api.playlistTracks(urn: playlist.urn, limit: 100, nextHref: nil)
            if !page.collection.isEmpty {
                let generation = UUID()
                queueFillGeneration = generation
                let remaining = try await startProgressivePlaylistPlayback(
                    tracks: page.collection,
                    startAt: 0,
                    resolver: playbackResolver,
                    generation: generation
                )
                startPlaylistPageQueueFill(
                    initialTracks: remaining,
                    playlistURN: playlist.urn,
                    nextHref: page.nextHref,
                    resolver: playbackResolver,
                    generation: generation
                )
                return
            }
        } catch {
            // Fall back to the playlist detail payload below. Some SoundCloud playlists only expose compact entries there.
        }

        do {
            let tracks = try await loadPlaylistTracks(for: playlist)
            await playProgressivePlaylist(tracks: tracks, startAt: 0)
        } catch {
            statusMessage = "Playlist playback failed: \(error.localizedDescription)"
        }
    }

    func addToQueue(track: SCTrack) async {
        guard !soundCloudMockMode else {
            statusMessage = "Demo Mode has no audio playback. Connect SoundCloud or use Public Mode."
            return
        }

        guard let playbackResolver = activePlaybackResolver else {
            statusMessage = "Playback resolver unavailable"
            return
        }

        do {
            let item = try await makeQueueItem(for: track, resolver: playbackResolver)
            playerController.appendToQueue(item)
            statusMessage = "Added to queue: \(track.title)"
        } catch {
            statusMessage = "Add to queue failed: \(error.localizedDescription)"
        }
    }

    func playNext(track: SCTrack) async {
        guard !soundCloudMockMode else {
            statusMessage = "Demo Mode has no audio playback. Connect SoundCloud or use Public Mode."
            return
        }

        guard let playbackResolver = activePlaybackResolver else {
            statusMessage = "Playback resolver unavailable"
            return
        }

        do {
            let item = try await makeQueueItem(for: track, resolver: playbackResolver)
            playerController.playNext(item)
            statusMessage = "Playing next: \(track.title)"
        } catch {
            statusMessage = "Play next failed: \(error.localizedDescription)"
        }
    }

    func loadPlaylistTracks(for playlist: SCPlaylist, maximumTracks: Int = .max) async throws -> [SCTrack] {
        guard let api = apiClient else {
            throw CloudScrobbleError.invalidConfiguration("Connect SoundCloud first")
        }

        let cappedMaximum = max(1, maximumTracks)
        var endpointTracks: [SCTrack] = []
        var endpointError: Error?

        do {
            var nextHref: URL?

            repeat {
                let remaining = max(1, min(100, cappedMaximum - endpointTracks.count))
                let page = try await api.playlistTracks(
                    urn: playlist.urn,
                    limit: remaining,
                    nextHref: nextHref
                )
                endpointTracks.append(contentsOf: page.collection)
                nextHref = page.nextHref
            } while nextHref != nil && endpointTracks.count < cappedMaximum
        } catch {
            endpointError = error
        }

        let compactEntries = await playlistTrackEntries(
            for: playlist,
            api: api,
            maximumTracks: cappedMaximum
        )

        if compactEntries.count > endpointTracks.count || endpointTracks.isEmpty {
            let detailedTracks = await detailedTracks(from: compactEntries, api: api)
            if !detailedTracks.isEmpty {
                return detailedTracks
            }
        }

        if !endpointTracks.isEmpty {
            return endpointTracks
        }

        if let endpointError {
            throw endpointError
        }
        throw CloudScrobbleError.invalidResponse
    }

    func play(savedTrack: SavedPlaybackTrack) async {
        guard let api = activeSoundCloudAPIClient else {
            statusMessage = "Connect SoundCloud first"
            return
        }

        do {
            let track = try await api.track(urn: savedTrack.trackURN)
            await play(track: track)
        } catch {
            statusMessage = "Recently played track unavailable: \(error.localizedDescription)"
        }
    }

    func reconnectSoundCloud() async {
        await disconnectSoundCloud()
        await connectSoundCloud()
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

    private func boundedPlaybackQueue(
        tracks: [SCTrack],
        startAt: Int,
        maxQueueLength: Int
    ) -> (tracks: [SCTrack], startAt: Int) {
        let clampedStart = min(max(startAt, 0), max(0, tracks.count - 1))
        let queueLimit = max(1, maxQueueLength)

        guard tracks.count > queueLimit else {
            return (tracks, clampedStart)
        }

        let lowerBound = clampedStart < queueLimit ? 0 : clampedStart
        let upperBound = min(tracks.count, lowerBound + queueLimit)
        return (Array(tracks[lowerBound..<upperBound]), clampedStart - lowerBound)
    }

    private func cancelQueueFill() {
        queueFillTask?.cancel()
        queueFillTask = nil
        queueFillGeneration = UUID()
    }

    private func playProgressivePlaylist(tracks: [SCTrack], startAt: Int) async {
        cancelQueueFill()

        guard !soundCloudMockMode else {
            statusMessage = "Demo Mode has no audio playback. Connect SoundCloud or use Public Mode."
            return
        }

        guard let playbackResolver = activePlaybackResolver else {
            statusMessage = "Playback resolver unavailable"
            return
        }

        let generation = UUID()
        queueFillGeneration = generation

        do {
            let remaining = try await startProgressivePlaylistPlayback(
                tracks: tracks,
                startAt: startAt,
                resolver: playbackResolver,
                generation: generation
            )
            startQueueFillTask(
                tracks: remaining,
                resolver: playbackResolver,
                generation: generation
            )
        } catch {
            statusMessage = "Queue loading failed: \(error.localizedDescription)"
        }
    }

    private func startProgressivePlaylistPlayback(
        tracks: [SCTrack],
        startAt: Int,
        resolver: PlaybackResolving,
        generation: UUID
    ) async throws -> [SCTrack] {
        guard !tracks.isEmpty else {
            statusMessage = "No playable tracks"
            return []
        }

        let playbackOrder = playlistPlaybackOrder(tracks: tracks, startAt: startAt)
        guard let firstTrack = playbackOrder.first else {
            statusMessage = "No playable tracks"
            return []
        }

        let firstItem = try await makeQueueItem(for: firstTrack, resolver: resolver)
        guard queueFillGeneration == generation else { return [] }

        playerController.loadQueue([firstItem], startAt: 0)
        statusMessage = playbackOrder.count == 1
            ? "Playing \(firstTrack.title)"
            : "Playing \(firstTrack.title). Loading queue..."
        return Array(playbackOrder.dropFirst())
    }

    private func playlistPlaybackOrder(tracks: [SCTrack], startAt: Int) -> [SCTrack] {
        guard !tracks.isEmpty else { return [] }
        let clampedStart = min(max(startAt, 0), tracks.count - 1)
        guard clampedStart > 0 else { return tracks }
        return Array(tracks[clampedStart...]) + Array(tracks[..<clampedStart])
    }

    private func startQueueFillTask(
        tracks: [SCTrack],
        resolver: PlaybackResolving,
        generation: UUID
    ) {
        guard !tracks.isEmpty else { return }

        queueFillTask = Task { [weak self, tracks, resolver, generation] in
            var loadedCount = 1
            var skippedCount = 0

            for track in tracks {
                guard !Task.isCancelled else { return }

                do {
                    let item = try await self?.makeQueueItem(for: track, resolver: resolver)
                    guard let item, !Task.isCancelled else { return }
                    let shouldContinue = await MainActor.run { [weak self] in
                        guard let self, self.queueFillGeneration == generation else { return false }
                        self.playerController.appendToQueue(item, showDebug: false)
                        return true
                    }
                    guard shouldContinue else { return }
                    loadedCount += 1
                } catch {
                    skippedCount += 1
                }
            }

            await MainActor.run { [weak self] in
                guard let self, self.queueFillGeneration == generation else { return }
                if skippedCount == 0 {
                    self.statusMessage = "Loaded \(loadedCount) tracks"
                } else {
                    self.statusMessage = "Loaded \(loadedCount) tracks (\(skippedCount) skipped)"
                }
                self.queueFillTask = nil
            }
        }
    }

    private func startPlaylistPageQueueFill(
        initialTracks: [SCTrack],
        playlistURN: String,
        nextHref: URL?,
        resolver: PlaybackResolving,
        generation: UUID
    ) {
        guard !initialTracks.isEmpty || nextHref != nil else { return }
        guard let api = apiClient else { return }

        queueFillTask = Task { [weak self, api, initialTracks, playlistURN, nextHref, resolver, generation] in
            var loadedCount = 1
            var skippedCount = 0
            var tracksToAppend = initialTracks
            var nextPageHref = nextHref

            while true {
                for track in tracksToAppend {
                    guard !Task.isCancelled else { return }

                    do {
                        let item = try await self?.makeQueueItem(for: track, resolver: resolver)
                        guard let item, !Task.isCancelled else { return }
                        let shouldContinue = await MainActor.run { [weak self] in
                            guard let self, self.queueFillGeneration == generation else { return false }
                            self.playerController.appendToQueue(item, showDebug: false)
                            return true
                        }
                        guard shouldContinue else { return }
                        loadedCount += 1
                    } catch {
                        skippedCount += 1
                    }
                }

                guard let href = nextPageHref else { break }
                guard !Task.isCancelled else { return }

                do {
                    let page = try await api.playlistTracks(
                        urn: playlistURN,
                        limit: 100,
                        nextHref: href
                    )
                    tracksToAppend = page.collection
                    nextPageHref = page.nextHref
                } catch {
                    skippedCount += 1
                    break
                }
            }

            await MainActor.run { [weak self] in
                guard let self, self.queueFillGeneration == generation else { return }
                if skippedCount == 0 {
                    self.statusMessage = "Loaded \(loadedCount) tracks"
                } else {
                    self.statusMessage = "Loaded \(loadedCount) tracks (\(skippedCount) skipped)"
                }
                self.queueFillTask = nil
            }
        }
    }

    private func playlistTrackEntries(
        for playlist: SCPlaylist,
        api: SoundCloudAPIClienting,
        maximumTracks: Int
    ) async -> [SCPlaylistTrackItem] {
        let detailedPlaylist = try? await api.playlist(urn: playlist.urn, showTracks: true)
        let entries = detailedPlaylist?.tracks ?? playlist.tracks ?? []
        return Array(entries.prefix(maximumTracks))
    }

    private func detailedTracks(
        from entries: [SCPlaylistTrackItem],
        api: SoundCloudAPIClienting
    ) async -> [SCTrack] {
        var tracks: [SCTrack] = []
        tracks.reserveCapacity(entries.count)

        for entry in entries {
            guard let track = try? await api.track(urn: entry.urn) else {
                continue
            }
            tracks.append(track)
        }

        return tracks
    }

    private nonisolated func makeQueueItem(
        for track: SCTrack,
        resolver: PlaybackResolving
    ) async throws -> QueueItem {
        let stream = try await resolver.resolvePlayableStream(for: track.urn)
        let lastFM = MetadataMapper.mapLastFM(track: track)
        return QueueItem(
            trackURN: track.urn,
            title: lastFM.track,
            artistDisplay: lastFM.artist,
            artworkURL: track.artworkURL,
            permalinkURL: track.permalinkURL,
            streamURL: stream.url,
            streamHeaders: stream.headers,
            durationSeconds: max(0, track.durationMs / 1000),
            lastFM: lastFM
        )
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
