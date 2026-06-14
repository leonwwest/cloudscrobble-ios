import CloudScrobbleCore
import Foundation
import Network

@MainActor
final class AppSessionViewModel: ObservableObject {
    private struct PendingSoundCloudAuthorization {
        let state: String
        let codeVerifier: String
        let redirectURI: String
    }

    private struct PlaybackStartResult {
        let remainingTracks: [SCTrack]
        let loadedCount: Int
        let skippedCount: Int
    }

    private struct QueueResolveBatch {
        let items: [QueueItem]
        let skippedCount: Int
    }

    private static let initialPlaybackBufferSize = 4
    private static let initialPlaybackScanLimit = 16
    private static let queueFillBatchSize = 6
    private static let prefetchWindowSize = 10

    @Published var soundCloudConnected = false
    @Published var soundCloudPublicMode = false
    @Published var soundCloudMockMode = false
    @Published var lastFMConnected = false
    @Published var isBusy = false
    @Published var isNetworkReachable = true
    @Published var networkStatusLabel = "Online"
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
    private let lastFMTasteService: LastFMTasteFetching?
    private var pendingSoundCloudAuthorization: PendingSoundCloudAuthorization?
    private var statusDismissalTask: Task<Void, Never>?
    private var queueFillTask: Task<Void, Never>?
    private var queueFillGeneration = UUID()
    private var cachedLastFMTasteTracks: [SCTrack]?
    private var didAttemptPlaybackRestore = false
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "CloudScrobble.NetworkMonitor")

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
            let lastFMTasteService = LastFMProxyTasteService(
                baseURL: config.tokenBrokerBaseURL,
                authService: lastFMAuthService
            )

            self.soundCloudAuthService = soundCloudAuthService
            self.realSoundCloudAPIClient = soundCloudAPIClient
            self.realPlaybackResolver = playbackResolver
            self.lastFMAuthService = lastFMAuthService
            self.lastFMScrobbleService = lastFMScrobbleService
            self.lastFMTasteService = lastFMTasteService
        } else {
            self.soundCloudAuthService = nil
            self.realSoundCloudAPIClient = nil
            self.realPlaybackResolver = nil
            self.lastFMAuthService = nil
            self.lastFMScrobbleService = nil
            self.lastFMTasteService = nil
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

        startNetworkMonitoring()
    }

    deinit {
        statusDismissalTask?.cancel()
        queueFillTask?.cancel()
        networkMonitor.cancel()
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

    func lastFMTasteProfile(limit: Int = 50) async -> LastFMTasteProfile? {
        guard lastFMConnected, let lastFMTasteService else { return nil }
        return try? await lastFMTasteService.tasteProfile(limit: limit)
    }

    func lastFMTasteTracks(api: SoundCloudAPIClienting, maxTracks: Int = 72) async -> [SCTrack] {
        if let cachedLastFMTasteTracks {
            return Array(cachedLastFMTasteTracks.prefix(maxTracks))
        }

        guard let profile = await lastFMTasteProfile(limit: 80) else {
            return []
        }
        let tracks = await LastFMTasteTrackResolver.resolveTracks(
            from: profile,
            api: api,
            maxTracks: max(maxTracks, 72)
        )
        cachedLastFMTasteTracks = tracks
        return Array(tracks.prefix(maxTracks))
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
        await playerController.refreshLastFMDiagnostics()

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
            await playerController.refreshLastFMDiagnostics()
            lastFMConnected = true
            cachedLastFMTasteTracks = nil
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
        cachedLastFMTasteTracks = nil
        playerController.clearSavedPlaybackSnapshot()
        deactivateSoundCloudMode()
    }

    func disconnectLastFM() async {
        guard let lastFMAuthService else { return }
        try? await lastFMAuthService.clearSession()
        lastFMConnected = false
        cachedLastFMTasteTracks = nil
        playerController.setLastFMScrobbler(nil)
    }

    func retryPendingLastFMScrobbles() async {
        guard lastFMConnected else { return }
        await playerController.flushPendingLastFMScrobbles()
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

        let generation = UUID()
        queueFillGeneration = generation

        do {
            let startResult = try await startProgressivePlaylistPlayback(
                tracks: boundedQueue.tracks,
                startAt: boundedQueue.startAt,
                resolver: playbackResolver,
                generation: generation
            )
            startQueueFillTask(
                tracks: startResult.remainingTracks,
                resolver: playbackResolver,
                generation: generation,
                loadedCount: startResult.loadedCount,
                skippedCount: startResult.skippedCount
            )
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
                let startResult = try await startProgressivePlaylistPlayback(
                    tracks: page.collection,
                    startAt: 0,
                    resolver: playbackResolver,
                    generation: generation
                )
                startPlaylistPageQueueFill(
                    initialTracks: startResult.remainingTracks,
                    playlistURN: playlist.urn,
                    nextHref: page.nextHref,
                    resolver: playbackResolver,
                    generation: generation,
                    loadedCount: startResult.loadedCount,
                    skippedCount: startResult.skippedCount
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
            let startResult = try await startProgressivePlaylistPlayback(
                tracks: tracks,
                startAt: startAt,
                resolver: playbackResolver,
                generation: generation
            )
            startQueueFillTask(
                tracks: startResult.remainingTracks,
                resolver: playbackResolver,
                generation: generation,
                loadedCount: startResult.loadedCount,
                skippedCount: startResult.skippedCount
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
    ) async throws -> PlaybackStartResult {
        guard !tracks.isEmpty else {
            statusMessage = "No playable tracks"
            return PlaybackStartResult(remainingTracks: [], loadedCount: 0, skippedCount: 0)
        }

        let playbackOrder = playlistPlaybackOrder(tracks: tracks, startAt: startAt)
        guard !playbackOrder.isEmpty else {
            statusMessage = "No playable tracks"
            return PlaybackStartResult(remainingTracks: [], loadedCount: 0, skippedCount: 0)
        }

        let prepared = await prepareInitialPlaybackQueue(
            from: playbackOrder,
            resolver: resolver
        )
        guard !prepared.items.isEmpty else {
            throw CloudScrobbleError.unsupportedStream
        }
        guard queueFillGeneration == generation else {
            return PlaybackStartResult(remainingTracks: [], loadedCount: 0, skippedCount: prepared.skippedCount)
        }

        playerController.loadQueue(prepared.items, startAt: 0)
        let upcomingTrackURNs = prepared.remainingTracks.prefix(Self.prefetchWindowSize).map(\.urn)
        Task {
            await resolver.prefetchPlayableStreams(for: Array(upcomingTrackURNs))
        }
        let firstTitle = prepared.items.first?.title ?? "track"
        let skippedText = prepared.skippedCount == 0 ? "" : " (\(prepared.skippedCount) skipped)"
        statusMessage = prepared.remainingTracks.isEmpty
            ? "Playing \(firstTitle). Buffered \(prepared.items.count) track\(prepared.items.count == 1 ? "" : "s")\(skippedText)"
            : "Playing \(firstTitle). Buffered \(prepared.items.count), loading more\(skippedText)"
        return PlaybackStartResult(
            remainingTracks: prepared.remainingTracks,
            loadedCount: prepared.items.count,
            skippedCount: prepared.skippedCount
        )
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
        generation: UUID,
        loadedCount initialLoadedCount: Int,
        skippedCount initialSkippedCount: Int
    ) {
        guard !tracks.isEmpty else { return }

        queueFillTask = Task { [weak self, tracks, resolver, generation] in
            var loadedCount = initialLoadedCount
            var skippedCount = initialSkippedCount
            var offset = 0

            while offset < tracks.count {
                guard !Task.isCancelled else { return }
                let upperBound = min(tracks.count, offset + Self.queueFillBatchSize)
                let batchTracks = Array(tracks[offset..<upperBound])
                let batch = await Self.resolveQueueItems(
                    for: batchTracks,
                    resolver: resolver
                )
                offset = upperBound
                skippedCount += batch.skippedCount

                for item in batch.items {
                    guard !Task.isCancelled else { return }
                    let shouldContinue = await MainActor.run { [weak self] in
                        guard let self, self.queueFillGeneration == generation else { return false }
                        self.playerController.appendToQueue(item, showDebug: false)
                        return true
                    }
                    guard shouldContinue else { return }
                    loadedCount += 1
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
        generation: UUID,
        loadedCount initialLoadedCount: Int,
        skippedCount initialSkippedCount: Int
    ) {
        guard !initialTracks.isEmpty || nextHref != nil else { return }
        guard let api = apiClient else { return }

        queueFillTask = Task { [weak self, api, initialTracks, playlistURN, nextHref, resolver, generation] in
            var loadedCount = initialLoadedCount
            var skippedCount = initialSkippedCount
            var tracksToAppend = initialTracks
            var nextPageHref = nextHref

            while true {
                var offset = 0
                while offset < tracksToAppend.count {
                    guard !Task.isCancelled else { return }
                    let upperBound = min(tracksToAppend.count, offset + Self.queueFillBatchSize)
                    let batchTracks = Array(tracksToAppend[offset..<upperBound])
                    let batch = await Self.resolveQueueItems(
                        for: batchTracks,
                        resolver: resolver
                    )
                    offset = upperBound
                    skippedCount += batch.skippedCount

                    for item in batch.items {
                        guard !Task.isCancelled else { return }
                        let shouldContinue = await MainActor.run { [weak self] in
                            guard let self, self.queueFillGeneration == generation else { return false }
                            self.playerController.appendToQueue(item, showDebug: false)
                            return true
                        }
                        guard shouldContinue else { return }
                        loadedCount += 1
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
        try await Self.makeQueueItem(for: track, resolver: resolver)
    }

    private func prepareInitialPlaybackQueue(
        from playbackOrder: [SCTrack],
        resolver: PlaybackResolving
    ) async -> (items: [QueueItem], remainingTracks: [SCTrack], skippedCount: Int) {
        var items: [QueueItem] = []
        var skippedCount = 0
        var offset = 0
        let scanLimit = min(playbackOrder.count, Self.initialPlaybackScanLimit)

        while items.count < Self.initialPlaybackBufferSize, offset < playbackOrder.count {
            let remainingScanBudget = max(0, scanLimit - offset)
            guard remainingScanBudget > 0 || items.isEmpty else { break }

            let batchSize = items.isEmpty
                ? min(Self.queueFillBatchSize, max(1, remainingScanBudget))
                : min(Self.queueFillBatchSize, playbackOrder.count - offset)
            let upperBound = min(playbackOrder.count, offset + batchSize)
            let batchTracks = Array(playbackOrder[offset..<upperBound])
            let batch = await Self.resolveQueueItems(for: batchTracks, resolver: resolver)
            items.append(contentsOf: batch.items)
            skippedCount += batch.skippedCount
            offset = upperBound

            if offset >= scanLimit, items.isEmpty {
                break
            }
        }

        return (
            items,
            offset < playbackOrder.count ? Array(playbackOrder[offset...]) : [],
            skippedCount
        )
    }

    private nonisolated static func resolveQueueItems(
        for tracks: [SCTrack],
        resolver: PlaybackResolving
    ) async -> QueueResolveBatch {
        guard !tracks.isEmpty else {
            return QueueResolveBatch(items: [], skippedCount: 0)
        }

        var resolved = Array<QueueItem?>(repeating: nil, count: tracks.count)

        await withTaskGroup(of: (Int, QueueItem?).self) { group in
            for (index, track) in tracks.enumerated() {
                group.addTask {
                    let item = try? await makeQueueItem(for: track, resolver: resolver)
                    return (index, item)
                }
            }

            for await (index, item) in group {
                resolved[index] = item
            }
        }

        return QueueResolveBatch(
            items: resolved.compactMap { $0 },
            skippedCount: resolved.filter { $0 == nil }.count
        )
    }

    private nonisolated static func makeQueueItem(
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

    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let isReachable = path.status == .satisfied
            let label: String
            if !isReachable {
                label = "Offline"
            } else if path.usesInterfaceType(.wifi) {
                label = "Wi-Fi"
            } else if path.usesInterfaceType(.cellular) {
                label = "Cellular"
            } else {
                label = "Online"
            }

            Task { @MainActor [weak self, isReachable, label] in
                guard let self else { return }
                let wasReachable = self.isNetworkReachable
                self.isNetworkReachable = isReachable
                self.networkStatusLabel = label

                if wasReachable, !isReachable {
                    self.statusMessage = "Offline: cached data remains available."
                } else if !wasReachable, isReachable {
                    self.statusMessage = "Back online"
                    await self.retryPendingLastFMScrobbles()
                }
            }
        }
        networkMonitor.start(queue: networkQueue)
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
