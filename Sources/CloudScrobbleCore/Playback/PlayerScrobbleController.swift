import AVFoundation
import Combine
import Foundation
#if canImport(MediaPlayer)
import MediaPlayer
#endif
#if os(iOS) && canImport(UIKit)
import UIKit
#endif

public enum PlaybackPhase: Equatable {
    case idle
    case loading
    case playing(QueueItem)
    case paused(QueueItem)
    case failed(String)
}

public enum PlaybackRepeatMode: String, CaseIterable, Sendable {
    case off
    case all
    case one
}

public struct ScrobbleConfigurationUpdate: Equatable, Sendable {
    public let metadata: LastFMTrackMeta
    public let isEnabled: Bool

    public init(metadata: LastFMTrackMeta, isEnabled: Bool) {
        self.metadata = metadata
        self.isEnabled = isEnabled
    }
}

@MainActor
public final class PlayerScrobbleController: ObservableObject {
    @Published public private(set) var phase: PlaybackPhase = .idle
    @Published public private(set) var queue: [QueueItem] = []
    @Published public private(set) var currentIndex: Int?
    @Published public private(set) var elapsedSeconds: TimeInterval = 0
    @Published public private(set) var debugStatus: String = ""
    @Published public private(set) var isShuffleEnabled = false
    @Published public private(set) var repeatMode: PlaybackRepeatMode = .off
    @Published public private(set) var recentlyPlayed: [SavedPlaybackTrack] = []
    @Published public private(set) var pendingScrobbleCount = 0
    @Published public private(set) var lastScrobbleSucceededAt: Date?
    @Published public private(set) var lastScrobbleError: String?
    @Published public private(set) var scrobbleHistory: [ScrobbleHistoryEntry] = []
    @Published public private(set) var skippedUnplayableCount = 0
    @Published public private(set) var sleepTimerEndsAt: Date?

    private static let playerItemWindowSize = 12
    private let player = AVQueuePlayer()
    private let scrobbleEngine = ScrobbleEngine()
    nonisolated(unsafe) private var timeObserver: Any?
    nonisolated(unsafe) private var endObserver: NSObjectProtocol?
    nonisolated(unsafe) private var failedObserver: NSObjectProtocol?
    nonisolated(unsafe) private var stalledObserver: NSObjectProtocol?
    nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
    nonisolated(unsafe) private var routeChangeObserver: NSObjectProtocol?
    private var debugDismissalTask: Task<Void, Never>?
    private var orderedQueue: [QueueItem] = []
    private var shouldResumeAfterInterruption = false
    private var lastSnapshotPersistedAt: Date?
    private var stalledRecoveryTask: Task<Void, Never>?
    private var activePlayerItemIDs: Set<ObjectIdentifier> = []
    private var currentPlayerItemID: ObjectIdentifier?
    private var playbackDispatchGeneration = UUID()
    private var nowPlayingDispatchTask: Task<Void, Never>?
    private var sleepTimerTask: Task<Void, Never>?
    private var nextPlayerQueueIndex = 0
    private var progressiveRestoreRecoverySnapshot: SavedPlaybackSnapshot?
#if os(iOS) && canImport(MediaPlayer)
    nonisolated(unsafe) private var remoteCommandTargets: [(command: MPRemoteCommand, target: Any)] = []
#endif

    private let persistence = PlaybackPersistenceStore()
    private let nowPlayingInfo = NowPlayingInfoCoordinator()

    private var lastFMScrobbler: LastFMScrobbleSending?

    public var hasLoadedQueue: Bool {
        !queue.isEmpty
    }

    public var currentItem: QueueItem? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    public var isPlaying: Bool {
        if case .playing = phase {
            return true
        }
        return false
    }

    public init(lastFMScrobbler: LastFMScrobbleSending?) {
        self.lastFMScrobbler = lastFMScrobbler
        self.recentlyPlayed = persistence.loadRecentlyPlayed()
        self.scrobbleHistory = persistence.loadScrobbleHistory()
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = true
        configureAudioSession()
        installTimeObserver()
        observeTrackEnd()
        observePlaybackProblems()
        observeAudioSession()
        configureRemoteCommands()
        nowPlayingInfo.refreshHandler = { [weak self] in
            guard let self, let item = self.currentItem else { return }
            self.nowPlayingInfo.update(
                for: item,
                elapsedSeconds: self.elapsedSeconds,
                playbackRate: self.isPlaying ? 1 : 0
            )
        }
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }

        let notificationCenter = NotificationCenter.default
        for observer in [
            endObserver,
            failedObserver,
            stalledObserver,
            interruptionObserver,
            routeChangeObserver
        ].compactMap({ $0 }) {
            notificationCenter.removeObserver(observer)
        }

        debugDismissalTask?.cancel()
        stalledRecoveryTask?.cancel()
        nowPlayingDispatchTask?.cancel()
        sleepTimerTask?.cancel()
#if os(iOS) && canImport(MediaPlayer)
        for registration in remoteCommandTargets {
            registration.command.removeTarget(registration.target)
        }
#endif
    }

    public func setLastFMScrobbler(_ scrobbler: LastFMScrobbleSending?) {
        lastFMScrobbler = scrobbler
        if scrobbler == nil, debugStatus.hasPrefix("Scrobble") || debugStatus == "Now Playing sent" {
            debugStatus = "Last.fm not connected"
        }
        if scrobbler == nil {
            nowPlayingDispatchTask?.cancel()
            nowPlayingDispatchTask = nil
            pendingScrobbleCount = 0
            lastScrobbleError = nil
        } else {
            Task { [weak self] in
                await self?.refreshLastFMDiagnostics()
            }
        }
    }

    public func refreshLastFMDiagnostics() async {
        guard let lastFMScrobbler else {
            pendingScrobbleCount = 0
            return
        }

        pendingScrobbleCount = await lastFMScrobbler.pendingScrobbleCount()
    }

    public func flushPendingLastFMScrobbles() async {
        guard let lastFMScrobbler else {
            pendingScrobbleCount = 0
            return
        }

        let previousPendingCount = await lastFMScrobbler.pendingScrobbleCount()
        do {
            try await lastFMScrobbler.flushPendingScrobbles()
            pendingScrobbleCount = await lastFMScrobbler.pendingScrobbleCount()
            lastScrobbleError = nil
            if previousPendingCount > 0, pendingScrobbleCount == 0 {
                lastScrobbleSucceededAt = Date()
                setDebugStatus("Pending scrobbles sent", autoDismissAfter: 2_800_000_000)
            }
        } catch {
            pendingScrobbleCount = await lastFMScrobbler.pendingScrobbleCount()
            lastScrobbleError = error.localizedDescription
            setDebugStatus("Scrobble retry failed: \(error.localizedDescription)")
        }
    }

    public func loadQueue(_ items: [QueueItem], startAt index: Int = 0) {
        progressiveRestoreRecoverySnapshot = nil
        orderedQueue = items
        let prepared = preparedQueue(items, startAt: index)
        queue = prepared.items
        currentIndex = nil
        guard !queue.isEmpty else {
            player.pause()
            player.removeAllItems()
            activePlayerItemIDs.removeAll()
            currentPlayerItemID = nil
            nextPlayerQueueIndex = 0
            phase = .idle
            elapsedSeconds = 0
            scrobbleEngine.stop()
            invalidateCurrentPlaybackDispatch()
            clearNowPlayingInfo()
            clearSavedPlaybackSnapshot()
            return
        }

        rebuildPlayerQueue(startAt: prepared.startIndex)
    }

    public func toggleShuffle() {
        isShuffleEnabled.toggle()

        guard let currentIndex, queue.indices.contains(currentIndex) else {
            return
        }

        let current = queue[currentIndex]

        if isShuffleEnabled {
            var remaining = orderedQueue
            if let currentOrderedIndex = remaining.firstIndex(where: { $0.trackURN == current.trackURN }) {
                remaining.remove(at: currentOrderedIndex)
            }
            queue = [current] + remaining.shuffled()
            persistPlaybackSnapshot()
            rebuildPlayerQueue(startAt: 0)
        } else {
            queue = orderedQueue.isEmpty ? queue : orderedQueue
            let restoredIndex = queue.firstIndex(where: { $0.trackURN == current.trackURN }) ?? 0
            persistPlaybackSnapshot()
            rebuildPlayerQueue(startAt: restoredIndex)
        }
    }

    public func playQueueItem(at index: Int) {
        guard queue.indices.contains(index) else { return }
        rebuildPlayerQueue(startAt: index)
    }

    public func appendToQueue(_ item: QueueItem, showDebug: Bool = true) {
        appendToQueue([item], showDebug: showDebug)
    }

    /// Appends a resolved batch with one queue publication and one snapshot
    /// write. This keeps progressive playlist loading linear for long queues.
    public func appendToQueue(_ items: [QueueItem], showDebug: Bool = true) {
        guard !items.isEmpty else { return }

        orderedQueue.append(contentsOf: items)
        queue.append(contentsOf: items)

        if currentIndex == nil {
            rebuildPlayerQueue(startAt: 0)
            return
        }

        fillPlayerQueueWindow()
        persistPlaybackSnapshot()
        if showDebug {
            let message = items.count == 1 ? "Added to queue" : "Added \(items.count) tracks to queue"
            setDebugStatus(message, autoDismissAfter: 2_500_000_000)
        }
    }

    /// Inserts restored tracks that originally appeared before the active
    /// item without restarting that item or disturbing its scrobble progress.
    public func prependToQueuePreservingCurrent(_ items: [QueueItem]) {
        guard !items.isEmpty,
              let currentIndex,
              queue.indices.contains(currentIndex) else {
            return
        }

        queue.insert(contentsOf: items, at: 0)
        orderedQueue.insert(contentsOf: items, at: 0)
        self.currentIndex = currentIndex + items.count
        nextPlayerQueueIndex += items.count
        persistPlaybackSnapshot()
    }

    public func playNext(_ item: QueueItem) {
        guard let currentIndex else {
            loadQueue([item], startAt: 0)
            return
        }

        let wasPlaying = isPlaying
        let resumeTime = elapsedSeconds
        let insertIndex = min(currentIndex + 1, queue.count)
        queue.insert(item, at: insertIndex)
        orderedQueue.insert(item, at: min(insertIndex, orderedQueue.count))
        rebuildPlayerQueuePreservingCurrent(resumeAt: resumeTime, shouldPlay: wasPlaying)
        setDebugStatus("Added next", autoDismissAfter: 2_500_000_000)
    }

    public func removeQueueItem(at index: Int) {
        guard queue.indices.contains(index) else { return }

        if queue.count == 1 {
            clearQueue()
            return
        }

        let wasPlaying = isPlaying
        let resumeTime = elapsedSeconds
        let removingCurrent = index == currentIndex
        let removedURN = queue[index].trackURN
        queue.remove(at: index)
        if let orderedIndex = orderedQueue.firstIndex(where: { $0.trackURN == removedURN }) {
            orderedQueue.remove(at: orderedIndex)
        }

        if removingCurrent {
            rebuildPlayerQueue(startAt: min(index, queue.count - 1))
            return
        }

        if let currentIndex, index < currentIndex {
            self.currentIndex = currentIndex - 1
        }

        rebuildPlayerQueuePreservingCurrent(resumeAt: resumeTime, shouldPlay: wasPlaying)
    }

    public func moveQueueItem(from source: Int, to destination: Int) {
        guard queue.indices.contains(source), queue.indices.contains(destination), source != destination else {
            return
        }

        let previousCurrentIndex = currentIndex
        let resumeTime = elapsedSeconds
        let wasPlaying = isPlaying
        let item = queue.remove(at: source)
        queue.insert(item, at: destination)
        orderedQueue = queue

        if let previousCurrentIndex {
            if previousCurrentIndex == source {
                currentIndex = destination
            } else if source < previousCurrentIndex, destination >= previousCurrentIndex {
                currentIndex = previousCurrentIndex - 1
            } else if source > previousCurrentIndex, destination <= previousCurrentIndex {
                currentIndex = previousCurrentIndex + 1
            } else {
                currentIndex = previousCurrentIndex
            }
        }

        rebuildPlayerQueuePreservingCurrent(resumeAt: resumeTime, shouldPlay: wasPlaying)
    }

    public func clearQueue() {
        progressiveRestoreRecoverySnapshot = nil
        stalledRecoveryTask?.cancel()
        stalledRecoveryTask = nil
        player.pause()
        player.removeAllItems()
        activePlayerItemIDs.removeAll()
        currentPlayerItemID = nil
        nextPlayerQueueIndex = 0
        queue = []
        orderedQueue = []
        currentIndex = nil
        elapsedSeconds = 0
        phase = .idle
        scrobbleEngine.stop()
        invalidateCurrentPlaybackDispatch()
        clearNowPlayingInfo()
        clearSavedPlaybackSnapshot()
        cancelSleepTimer(showStatus: false)
        setDebugStatus("Queue cleared", autoDismissAfter: 2_500_000_000)
    }

    public func clearRecentlyPlayed() {
        recentlyPlayed = []
        persistence.clearRecentlyPlayed()
    }

    public func clearScrobbleHistory() {
        scrobbleHistory = []
        skippedUnplayableCount = 0
        persistence.clearScrobbleHistory()
    }

    /// Applies a persisted Last.fm correction or exclusion to the logical
    /// queue. Playback continues uninterrupted and listened-time progress is
    /// preserved for the current track.
    public func updateScrobbleConfiguration(
        trackURN: String,
        metadata: LastFMTrackMeta,
        isEnabled: Bool
    ) {
        updateScrobbleConfigurations([
            trackURN: ScrobbleConfigurationUpdate(metadata: metadata, isEnabled: isEnabled)
        ])
    }

    /// Applies several corrections or exclusions with one queue publication
    /// and one persistence pass. This keeps artist-wide changes linear even
    /// for large playlists.
    public func updateScrobbleConfigurations(
        _ configurations: [String: ScrobbleConfigurationUpdate]
    ) {
        guard !configurations.isEmpty else {
            return
        }
        let affectsQueue = queue.contains { configurations[$0.trackURN] != nil }
        let affectsRecentlyPlayed = recentlyPlayed.contains { configurations[$0.trackURN] != nil }
        guard affectsQueue || affectsRecentlyPlayed else { return }

        func updatedItem(from oldItem: QueueItem) -> QueueItem {
            guard let configuration = configurations[oldItem.trackURN] else { return oldItem }
            return QueueItem(
                trackURN: oldItem.trackURN,
                title: configuration.metadata.track,
                artistDisplay: configuration.metadata.artist,
                artworkURL: oldItem.artworkURL,
                permalinkURL: oldItem.permalinkURL,
                streamURL: oldItem.streamURL,
                streamHeaders: oldItem.streamHeaders,
                durationSeconds: oldItem.durationSeconds,
                lastFM: configuration.metadata,
                scrobbleEnabled: configuration.isEnabled
            )
        }

        queue = queue.map { updatedItem(from: $0) }
        orderedQueue = orderedQueue.map { updatedItem(from: $0) }

        var didUpdateRecent = false
        recentlyPlayed = recentlyPlayed.map { saved in
            guard let configuration = configurations[saved.trackURN] else {
                return saved
            }
            didUpdateRecent = true
            return SavedPlaybackTrack(
                trackURN: saved.trackURN,
                title: configuration.metadata.track,
                artistDisplay: configuration.metadata.artist,
                artworkURL: saved.artworkURL,
                permalinkURL: saved.permalinkURL,
                durationSeconds: saved.durationSeconds,
                lastFM: configuration.metadata
            )
        }
        if didUpdateRecent {
            persistRecentlyPlayed()
        }

        let wasPlaying = isPlaying
        var currentEvents: [ScrobbleEngineEvent] = []
        if let currentIndex,
           queue.indices.contains(currentIndex),
           configurations[queue[currentIndex].trackURN] != nil {
            let currentItem = queue[currentIndex]
            invalidateCurrentPlaybackDispatch()
            currentEvents = scrobbleEngine.updateTrack(currentItem)
            phase = wasPlaying ? .playing(currentItem) : .paused(currentItem)
            updateNowPlayingInfo(for: currentItem, playbackRate: wasPlaying ? 1 : 0)
        }

        persistPlaybackSnapshot()
        dispatchLater(currentEvents)

        if configurations.count == 1, let configuration = configurations.values.first {
            setDebugStatus(
                configuration.isEnabled ? "Scrobble metadata updated" : "Scrobbling disabled for this track",
                autoDismissAfter: 3_000_000_000
            )
        }
    }

    public func cycleRepeatMode() {
        switch repeatMode {
        case .off:
            repeatMode = .all
        case .all:
            repeatMode = .one
        case .one:
            repeatMode = .off
        }
        persistPlaybackSnapshot()
    }

    public func startSleepTimer(minutes: Int) {
        startSleepTimer(after: TimeInterval(max(1, minutes) * 60))
    }

    /// Duration-based entry point also keeps the timer deterministic in tests.
    public func startSleepTimer(after duration: TimeInterval) {
        let duration = max(0.01, min(duration, 86_400))
        sleepTimerTask?.cancel()
        sleepTimerEndsAt = Date().addingTimeInterval(duration)
        let nanoseconds = UInt64(duration * 1_000_000_000)

        sleepTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.sleepTimerTask = nil
            self.sleepTimerEndsAt = nil
            self.pauseForSleepTimer()
        }

        setDebugStatus("Sleep timer set", autoDismissAfter: 2_500_000_000)
    }

    public func cancelSleepTimer() {
        cancelSleepTimer(showStatus: true)
    }

    private func cancelSleepTimer(showStatus: Bool) {
        guard sleepTimerTask != nil || sleepTimerEndsAt != nil else { return }
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndsAt = nil
        if showStatus {
            setDebugStatus("Sleep timer cancelled", autoDismissAfter: 2_500_000_000)
        }
    }

    private func pauseForSleepTimer() {
        player.pause()
        scrobbleEngine.pause()
        if let item = currentItem {
            phase = .paused(item)
            updateNowPlayingInfo(for: item, playbackRate: 0)
            persistPlaybackSnapshot()
        }
        setDebugStatus("Sleep timer finished", autoDismissAfter: 3_500_000_000)
    }

    public func togglePlayback() {
        switch phase {
        case .playing(let item):
            player.pause()
            scrobbleEngine.pause()
            phase = .paused(item)
            updateNowPlayingInfo(for: item, playbackRate: 0)
            persistPlaybackSnapshot()
        case .paused(let item):
            configureAudioSession()
            player.play()
            scrobbleEngine.resume()
            phase = .playing(item)
            updateNowPlayingInfo(for: item, playbackRate: 1)
            persistPlaybackSnapshot()
        default:
            break
        }
    }

    public func seek(to seconds: TimeInterval) {
        let target = CMTime(seconds: seconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player.seek(to: target)
        elapsedSeconds = seconds
        if case .playing(let item) = phase {
            updateNowPlayingInfo(for: item, playbackRate: 1)
        } else if case .paused(let item) = phase {
            updateNowPlayingInfo(for: item, playbackRate: 0)
        }
        persistPlaybackSnapshot()
    }

    public func savedPlaybackSnapshot() -> SavedPlaybackSnapshot? {
        persistence.loadSnapshot()
    }

    public func clearSavedPlaybackSnapshot() {
        if let progressiveRestoreRecoverySnapshot {
            persistence.saveSnapshot(progressiveRestoreRecoverySnapshot)
            lastSnapshotPersistedAt = Date()
            return
        }
        progressiveRestoreRecoverySnapshot = nil
        lastSnapshotPersistedAt = nil
        persistence.clearSnapshot()
    }

    public func restoreSavedQueue(
        _ items: [QueueItem],
        from snapshot: SavedPlaybackSnapshot,
        recoverySnapshot: SavedPlaybackSnapshot? = nil
    ) {
        guard items.indices.contains(snapshot.currentIndex) else {
            clearSavedPlaybackSnapshot()
            return
        }

        orderedQueue = items
        queue = items
        isShuffleEnabled = snapshot.isShuffleEnabled
        repeatMode = PlaybackRepeatMode(rawValue: snapshot.repeatModeRawValue) ?? .off
        currentIndex = snapshot.currentIndex
        elapsedSeconds = max(0, snapshot.elapsedSeconds)
        resetPlayerItems(startAt: snapshot.currentIndex)
        let item = queue[snapshot.currentIndex]
        let target = CMTime(seconds: elapsedSeconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        scrobbleEngine.restore(
            track: item,
            state: snapshot.scrobbleState,
            playbackTime: elapsedSeconds,
            isPaused: true
        )
        phase = .paused(item)
        updateNowPlayingInfo(for: item, playbackRate: 0)
        if let recoverySnapshot {
            progressiveRestoreRecoverySnapshot = recoverySnapshot
            persistence.saveSnapshot(recoverySnapshot)
            lastSnapshotPersistedAt = Date()
        } else {
            persistPlaybackSnapshot()
        }
    }

    /// Ends the short persistence suspension used while a saved queue is
    /// being reconstructed around the active item, then stores the full queue.
    public func completeProgressiveQueueRestore() {
        guard progressiveRestoreRecoverySnapshot != nil else { return }
        progressiveRestoreRecoverySnapshot = nil
        persistPlaybackSnapshot()
    }

    public func next() {
        guard let currentIndex else { return }
        let nextIndex = currentIndex + 1
        guard queue.indices.contains(nextIndex) else {
            if repeatMode == .all {
                rebuildPlayerQueue(startAt: 0)
            }
            return
        }

        player.advanceToNextItem()
        fillPlayerQueueWindow()
        let events = startTrackState(at: nextIndex, playbackRate: 1)
        configureAudioSession()
        player.play()
        dispatchLater(events)
    }

    public func previous() {
        guard let currentIndex else { return }
        let previousIndex: Int
        if currentIndex == 0, repeatMode == .all {
            previousIndex = max(0, queue.count - 1)
        } else {
            previousIndex = max(0, currentIndex - 1)
        }
        rebuildPlayerQueue(startAt: previousIndex)
    }

    private func rebuildPlayerQueue(startAt index: Int) {
        guard queue.indices.contains(index) else { return }

        stalledRecoveryTask?.cancel()
        stalledRecoveryTask = nil
        phase = .loading

        configureAudioSession()
        player.volume = 1
        player.pause()
        resetPlayerItems(startAt: index)

        let events = startTrackState(at: index, playbackRate: 1)
        persistPlaybackSnapshot()
        player.play()
        dispatchLater(events)
    }

    @discardableResult
    private func startTrackState(at index: Int, playbackRate: Double) -> [ScrobbleEngineEvent] {
        stalledRecoveryTask?.cancel()
        stalledRecoveryTask = nil

        guard queue.indices.contains(index) else {
            scrobbleEngine.stop()
            phase = .idle
            currentIndex = nil
            elapsedSeconds = 0
            currentPlayerItemID = nil
            invalidateCurrentPlaybackDispatch()
            clearNowPlayingInfo()
            clearSavedPlaybackSnapshot()
            return []
        }

        let item = queue[index]
        currentIndex = index
        syncCurrentPlayerItemID()
        invalidateCurrentPlaybackDispatch()
        elapsedSeconds = 0
        recordRecentlyPlayed(item)

        scrobbleEngine.stop()
        let events = scrobbleEngine.start(track: item)

        phase = playbackRate == 0 ? .paused(item) : .playing(item)
        updateNowPlayingInfo(for: item, playbackRate: playbackRate)
        persistPlaybackSnapshot()

        return events
    }

    private func makePlayerItem(for item: QueueItem) -> AVPlayerItem {
        guard !item.streamHeaders.isEmpty else {
            let playerItem = AVPlayerItem(url: item.streamURL)
            configurePlayerItemBuffering(playerItem)
            return playerItem
        }

        let asset = AVURLAsset(
            url: item.streamURL,
            options: ["AVURLAssetHTTPHeaderFieldsKey": item.streamHeaders]
        )
        let playerItem = AVPlayerItem(asset: asset)
        configurePlayerItemBuffering(playerItem)
        return playerItem
    }

    private func makeTrackedPlayerItem(for item: QueueItem) -> AVPlayerItem {
        let playerItem = makePlayerItem(for: item)
        activePlayerItemIDs.insert(ObjectIdentifier(playerItem))
        return playerItem
    }

    /// Replaces AVQueuePlayer's concrete queue with a small window. The full
    /// logical queue remains published for editing and persistence.
    private func resetPlayerItems(startAt index: Int) {
        player.removeAllItems()
        activePlayerItemIDs.removeAll()
        currentPlayerItemID = nil
        nextPlayerQueueIndex = index
        fillPlayerQueueWindow()
        syncCurrentPlayerItemID()
    }

    private func fillPlayerQueueWindow() {
        while player.items().count < Self.playerItemWindowSize,
              queue.indices.contains(nextPlayerQueueIndex) {
            let playerItem = makeTrackedPlayerItem(for: queue[nextPlayerQueueIndex])
            guard player.canInsert(playerItem, after: nil) else {
                activePlayerItemIDs.remove(ObjectIdentifier(playerItem))
                break
            }
            player.insert(playerItem, after: nil)
            nextPlayerQueueIndex += 1
        }

        activePlayerItemIDs = Set(player.items().map(ObjectIdentifier.init))
        syncCurrentPlayerItemID()
    }

    private func isActivePlayerItemID(_ playerItemID: ObjectIdentifier?) -> Bool {
        guard let playerItemID else {
            return false
        }
        return activePlayerItemIDs.contains(playerItemID)
    }

    private func syncCurrentPlayerItemID() {
        let playerItemID = player.currentItem.map(ObjectIdentifier.init)
        currentPlayerItemID = isActivePlayerItemID(playerItemID) ? playerItemID : nil
    }

    private func isCurrentPlayerItemID(_ playerItemID: ObjectIdentifier?) -> Bool {
        guard let playerItemID,
              isActivePlayerItemID(playerItemID) else {
            return false
        }
        return currentPlayerItemID == playerItemID
    }

    private func invalidateCurrentPlaybackDispatch() {
        playbackDispatchGeneration = UUID()
        nowPlayingDispatchTask?.cancel()
        nowPlayingDispatchTask = nil
    }

    private func isCurrentPlayback(trackURN: String, generation: UUID) -> Bool {
        playbackDispatchGeneration == generation && currentItem?.trackURN == trackURN
    }

    private func advancePastPlayerItemIfNeeded(_ playerItemID: ObjectIdentifier?) {
        guard let playerItemID,
              player.currentItem.map(ObjectIdentifier.init) == playerItemID else {
            return
        }
        player.advanceToNextItem()
    }

    private func configurePlayerItemBuffering(_ item: AVPlayerItem) {
        item.preferredForwardBufferDuration = 8
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
    }

    private func configureAudioSession() {
#if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            debugStatus = "Audio session error: \(error.localizedDescription)"
        }
#endif
    }

    private func observeTrackEnd() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let playerItemID = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
            Task { @MainActor [weak self, playerItemID] in
                guard let self, self.isCurrentPlayerItemID(playerItemID) else { return }
                self.handleCurrentTrackEnded()
            }
        }
    }

    private func observePlaybackProblems() {
        failedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let playerItemID = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
            let errorMessage = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription
            Task { @MainActor [weak self, playerItemID, errorMessage] in
                guard let self, self.isCurrentPlayerItemID(playerItemID) else { return }
                self.handlePlaybackProblem(errorMessage: errorMessage)
            }
        }

        stalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let playerItemID = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
            Task { @MainActor [weak self, playerItemID] in
                guard let self, self.isCurrentPlayerItemID(playerItemID) else { return }
                self.handlePlaybackStalled()
            }
        }
    }

    private func observeAudioSession() {
#if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleAudioInterruption(typeRaw: typeRaw, optionRaw: optionRaw)
            }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleRouteChange(reasonRaw: reasonRaw)
            }
        }
#endif
    }

    private func handleAudioInterruption(typeRaw: UInt?, optionRaw: UInt?) {
#if os(iOS)
        guard let typeRaw,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else {
            return
        }

        switch type {
        case .began:
            shouldResumeAfterInterruption = isCurrentlyPlaying
            player.pause()
            scrobbleEngine.pause()
            if case .playing(let item) = phase {
                phase = .paused(item)
                updateNowPlayingInfo(for: item, playbackRate: 0)
                persistPlaybackSnapshot()
            }
            setDebugStatus("Audio interrupted", autoDismissAfter: 3_000_000_000)
        case .ended:
            configureAudioSession()
            let options = AVAudioSession.InterruptionOptions(rawValue: optionRaw ?? 0)
            guard shouldResumeAfterInterruption, options.contains(.shouldResume) else {
                shouldResumeAfterInterruption = false
                return
            }

            shouldResumeAfterInterruption = false
            if case .paused(let item) = phase {
                player.play()
                scrobbleEngine.resume()
                phase = .playing(item)
                updateNowPlayingInfo(for: item, playbackRate: 1)
                persistPlaybackSnapshot()
                setDebugStatus("Audio resumed", autoDismissAfter: 2_500_000_000)
            }
        @unknown default:
            break
        }
#endif
    }

    private func handleRouteChange(reasonRaw: UInt?) {
#if os(iOS)
        guard let reasonRaw,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else {
            return
        }

        switch reason {
        case .oldDeviceUnavailable:
            player.pause()
            scrobbleEngine.pause()
            if case .playing(let item) = phase {
                phase = .paused(item)
                updateNowPlayingInfo(for: item, playbackRate: 0)
                persistPlaybackSnapshot()
            }
            setDebugStatus("Audio output changed", autoDismissAfter: 3_500_000_000)
        case .newDeviceAvailable, .categoryChange, .override:
            configureAudioSession()
        default:
            break
        }
#endif
    }

    private func handleCurrentTrackEnded() {
        stalledRecoveryTask?.cancel()
        stalledRecoveryTask = nil

        guard let finishedIndex = currentIndex, queue.indices.contains(finishedIndex) else { return }
        let finishedItem = queue[finishedIndex]
        let finishedPlayerItemID = currentPlayerItemID
        let finishEvents = scrobbleEngine.finish(
            playbackTime: max(elapsedSeconds, Double(finishedItem.durationSeconds))
        )
        dispatchLater(finishEvents)

        if repeatMode == .one {
            rebuildPlayerQueue(startAt: finishedIndex)
            return
        }

        let nextIndex = finishedIndex + 1

        guard queue.indices.contains(nextIndex) else {
            if repeatMode == .all, !queue.isEmpty {
                rebuildPlayerQueue(startAt: 0)
                return
            }

            scrobbleEngine.stop()
            phase = .idle
            currentIndex = nil
            currentPlayerItemID = nil
            elapsedSeconds = 0
            invalidateCurrentPlaybackDispatch()
            clearNowPlayingInfo()
            clearSavedPlaybackSnapshot()
            return
        }

        advancePastPlayerItemIfNeeded(finishedPlayerItemID)
        fillPlayerQueueWindow()
        let events = startTrackState(at: nextIndex, playbackRate: 1)
        configureAudioSession()
        player.play()
        dispatchLater(events)
    }

    private func handlePlaybackProblem(errorMessage: String?) {
        stalledRecoveryTask?.cancel()
        stalledRecoveryTask = nil

        let failedTitle: String?
        let failedItem: QueueItem?
        let failedIndex = currentIndex
        if let failedIndex, queue.indices.contains(failedIndex) {
            failedItem = queue[failedIndex]
            failedTitle = failedItem?.title
        } else {
            failedItem = nil
            failedTitle = nil
        }

        if let failedTitle {
            setDebugStatus("Track not playable, skipping: \(failedTitle)")
        } else {
            setDebugStatus("Track not playable")
        }

        skippedUnplayableCount += 1
        if let failedItem {
            recordScrobbleHistory(
                event: .skipped,
                item: failedItem,
                message: errorMessage ?? "Track not playable"
            )
        }

        guard let failedIndex else {
            phase = .failed(errorMessage ?? "Track not playable.")
            return
        }

        if queue.indices.contains(failedIndex) {
            let failedURN = queue[failedIndex].trackURN
            queue.remove(at: failedIndex)
            if let orderedIndex = orderedQueue.firstIndex(where: { $0.trackURN == failedURN }) {
                orderedQueue.remove(at: orderedIndex)
            }
        }

        player.pause()
        player.removeAllItems()
        activePlayerItemIDs.removeAll()
        currentPlayerItemID = nil
        nextPlayerQueueIndex = 0

        guard !queue.isEmpty else {
            scrobbleEngine.stop()
            phase = .idle
            self.currentIndex = nil
            elapsedSeconds = 0
            invalidateCurrentPlaybackDispatch()
            clearNowPlayingInfo()
            clearSavedPlaybackSnapshot()
            setDebugStatus("Queue ended after skipping \(skippedUnplayableCount) unplayable track\(skippedUnplayableCount == 1 ? "" : "s")")
            return
        }

        rebuildPlayerQueue(startAt: min(failedIndex, queue.count - 1))
    }

    private func handlePlaybackStalled() {
        guard let item = currentItem else {
            return
        }

        setDebugStatus("Buffering stream...", autoDismissAfter: 2_500_000_000)
        let stalledTrackURN = item.trackURN
        let stalledAt = elapsedSeconds

        stalledRecoveryTask?.cancel()
        stalledRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.currentItem?.trackURN == stalledTrackURN,
                  self.isPlaying,
                  self.elapsedSeconds <= stalledAt + 1.0 else {
                return
            }

            self.setDebugStatus("Stream stalled, skipping: \(item.title)")
            self.handlePlaybackProblem(errorMessage: "Stream stalled")
        }
    }

    private func preparedQueue(_ items: [QueueItem], startAt index: Int) -> (items: [QueueItem], startIndex: Int) {
        guard items.indices.contains(index) else { return ([], 0) }
        let selected = items[index]
        let remaining = items.enumerated()
            .filter { $0.offset != index }
            .map(\.element)

        if isShuffleEnabled {
            return ([selected] + remaining.shuffled(), 0)
        }

        return (items, index)
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.handleTick(time: time.seconds)
            }
        }
    }

    private func handleTick(time: TimeInterval) {
        elapsedSeconds = max(0, time)
        if case .playing(let item) = phase {
            updateNowPlayingInfo(for: item, playbackRate: 1)
        }
        let events = scrobbleEngine.tick(playbackTime: elapsedSeconds)
        persistPlaybackSnapshot(force: !events.isEmpty)
        dispatchLater(events)
    }

    private func configureRemoteCommands() {
#if os(iOS) && canImport(MediaPlayer)
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        let playTarget = commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                if case .paused = self?.phase {
                    self?.togglePlayback()
                }
            }
            return .success
        }
        remoteCommandTargets.append((commandCenter.playCommand, playTarget))

        commandCenter.pauseCommand.isEnabled = true
        let pauseTarget = commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                if case .playing = self?.phase {
                    self?.togglePlayback()
                }
            }
            return .success
        }
        remoteCommandTargets.append((commandCenter.pauseCommand, pauseTarget))

        commandCenter.togglePlayPauseCommand.isEnabled = true
        let toggleTarget = commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.togglePlayback()
            }
            return .success
        }
        remoteCommandTargets.append((commandCenter.togglePlayPauseCommand, toggleTarget))

        commandCenter.nextTrackCommand.isEnabled = true
        let nextTarget = commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.next()
            }
            return .success
        }
        remoteCommandTargets.append((commandCenter.nextTrackCommand, nextTarget))

        commandCenter.previousTrackCommand.isEnabled = true
        let previousTarget = commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.previous()
            }
            return .success
        }
        remoteCommandTargets.append((commandCenter.previousTrackCommand, previousTarget))

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        let positionTarget = commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }

            Task { @MainActor [weak self] in
                self?.seek(to: event.positionTime)
            }
            return .success
        }
        remoteCommandTargets.append((commandCenter.changePlaybackPositionCommand, positionTarget))
#endif
    }

    private func updateNowPlayingInfo(for item: QueueItem, playbackRate: Double) {
        nowPlayingInfo.update(for: item, elapsedSeconds: elapsedSeconds, playbackRate: playbackRate)
    }

    private func clearNowPlayingInfo() {
        nowPlayingInfo.clear()
    }

    private var isCurrentlyPlaying: Bool {
        isPlaying
    }

    private func dispatchNowPlaying(
        trackURN: String,
        meta: LastFMTrackMeta,
        duration: Int?,
        generation: UUID
    ) async {
        guard isCurrentPlayback(trackURN: trackURN, generation: generation) else {
            return
        }

        guard let lastFMScrobbler else {
            debugStatus = "Last.fm not connected"
            return
        }

        do {
            try Task.checkCancellation()
            try await lastFMScrobbler.updateNowPlaying(meta: meta, durationSeconds: duration)
            try Task.checkCancellation()
            guard isCurrentPlayback(trackURN: trackURN, generation: generation) else {
                return
            }
            let pending = await lastFMScrobbler.pendingScrobbleCount()
            guard isCurrentPlayback(trackURN: trackURN, generation: generation) else {
                return
            }
            pendingScrobbleCount = pending
            lastScrobbleError = nil
            recordScrobbleHistory(
                event: .nowPlaying,
                meta: meta,
                trackURN: trackURN,
                message: duration.map { "\($0)s" }
            )
            setDebugStatus("Now Playing sent", autoDismissAfter: 2_800_000_000)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  isCurrentPlayback(trackURN: trackURN, generation: generation) else {
                return
            }
            pendingScrobbleCount = await lastFMScrobbler.pendingScrobbleCount()
            lastScrobbleError = error.localizedDescription
            recordScrobbleHistory(
                event: .failed,
                meta: meta,
                trackURN: trackURN,
                message: error.localizedDescription
            )
            setDebugStatus("Scrobble error: \(error.localizedDescription)")
        }
    }

    private func dispatchScrobble(trackURN: String, meta: LastFMTrackMeta, timestamp: Int) async {
        guard let lastFMScrobbler else {
            debugStatus = "Last.fm not connected"
            return
        }

        do {
            try await lastFMScrobbler.scrobble(meta: meta, timestamp: timestamp)
            let pending = await lastFMScrobbler.pendingScrobbleCount()
            pendingScrobbleCount = pending
            lastScrobbleSucceededAt = Date()
            lastScrobbleError = nil
            recordScrobbleHistory(
                event: pending == 0 ? .scrobbled : .queued,
                meta: meta,
                trackURN: trackURN,
                message: pending == 0 ? nil : "\(pending) pending"
            )
            setDebugStatus(
                pending == 0 ? "Track scrobbled" : "Scrobble queued (\(pending) pending)",
                autoDismissAfter: pending == 0 ? 3_200_000_000 : nil
            )
        } catch {
            pendingScrobbleCount = await lastFMScrobbler.pendingScrobbleCount()
            lastScrobbleError = error.localizedDescription
            recordScrobbleHistory(
                event: .failed,
                meta: meta,
                trackURN: trackURN,
                message: error.localizedDescription
            )
            setDebugStatus("Scrobble error: \(error.localizedDescription)")
        }
    }

    private func dispatchLater(_ events: [ScrobbleEngineEvent]) {
        guard !events.isEmpty else { return }
        for event in events {
            switch event {
            case .sendNowPlaying(let trackURN, let meta, let duration):
                let generation = playbackDispatchGeneration
                nowPlayingDispatchTask?.cancel()
                nowPlayingDispatchTask = Task { [weak self] in
                    await self?.dispatchNowPlaying(
                        trackURN: trackURN,
                        meta: meta,
                        duration: duration,
                        generation: generation
                    )
                }
            case .sendScrobble(let trackURN, let meta, let timestamp):
                Task { [weak self] in
                    await self?.dispatchScrobble(trackURN: trackURN, meta: meta, timestamp: timestamp)
                }
            }
        }
    }

    private func setDebugStatus(_ message: String, autoDismissAfter delay: UInt64? = nil) {
        debugDismissalTask?.cancel()
        debugStatus = message

        guard let delay else {
            debugDismissalTask = nil
            return
        }

        debugDismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, self?.debugStatus == message else { return }
            self?.debugStatus = ""
        }
    }

    private func persistPlaybackSnapshot(force: Bool = true) {
        guard progressiveRestoreRecoverySnapshot == nil else { return }
        guard let currentIndex, queue.indices.contains(currentIndex), !queue.isEmpty else {
            return
        }

        let now = Date()
        if !force,
           let lastSnapshotPersistedAt,
           now.timeIntervalSince(lastSnapshotPersistedAt) < 15 {
            return
        }

        let snapshot = SavedPlaybackSnapshot(
            queue: queue.map(SavedPlaybackTrack.init(queueItem:)),
            currentIndex: currentIndex,
            elapsedSeconds: elapsedSeconds,
            scrobbleState: scrobbleEngine.state,
            repeatModeRawValue: repeatMode.rawValue,
            isShuffleEnabled: isShuffleEnabled
        )

        persistence.saveSnapshot(snapshot)
        lastSnapshotPersistedAt = now
    }

    private func rebuildPlayerQueuePreservingCurrent(resumeAt seconds: TimeInterval, shouldPlay: Bool) {
        guard let currentIndex, queue.indices.contains(currentIndex) else {
            clearQueue()
            return
        }

        let item = queue[currentIndex]
        let savedScrobbleState = scrobbleEngine.state
        player.pause()
        resetPlayerItems(startAt: currentIndex)
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        elapsedSeconds = max(0, seconds)
        scrobbleEngine.restore(
            track: item,
            state: savedScrobbleState,
            playbackTime: elapsedSeconds,
            isPaused: !shouldPlay
        )
        phase = shouldPlay ? .playing(item) : .paused(item)
        updateNowPlayingInfo(for: item, playbackRate: shouldPlay ? 1 : 0)
        if shouldPlay {
            configureAudioSession()
            player.play()
        }
        persistPlaybackSnapshot()
    }

    private func recordRecentlyPlayed(_ item: QueueItem) {
        let saved = SavedPlaybackTrack(queueItem: item)
        recentlyPlayed.removeAll { $0.trackURN == saved.trackURN }
        recentlyPlayed.insert(saved, at: 0)
        if recentlyPlayed.count > 40 {
            recentlyPlayed = Array(recentlyPlayed.prefix(40))
        }
        persistRecentlyPlayed()
    }

    private func persistRecentlyPlayed() {
        persistence.saveRecentlyPlayed(recentlyPlayed)
    }

    private func recordScrobbleHistory(
        event: ScrobbleHistoryEvent,
        item: QueueItem,
        message: String? = nil
    ) {
        recordScrobbleHistory(
            event: event,
            title: item.title,
            artist: item.artistDisplay,
            trackURN: item.trackURN,
            message: message
        )
    }

    private func recordScrobbleHistory(
        event: ScrobbleHistoryEvent,
        meta: LastFMTrackMeta,
        trackURN: String? = nil,
        message: String? = nil
    ) {
        let resolvedTrackURN = trackURN ?? (currentItem?.lastFM == meta ? currentItem?.trackURN : nil)
        recordScrobbleHistory(
            event: event,
            title: meta.track,
            artist: meta.artist,
            trackURN: resolvedTrackURN,
            message: message
        )
    }

    private func recordScrobbleHistory(
        event: ScrobbleHistoryEvent,
        title: String,
        artist: String,
        trackURN: String?,
        message: String?
    ) {
        scrobbleHistory.removeAll {
            $0.event == event
                && $0.trackURN == trackURN
                && abs($0.occurredAt.timeIntervalSinceNow) < 1
        }
        scrobbleHistory.insert(
            ScrobbleHistoryEntry(
                event: event,
                title: title,
                artist: artist,
                trackURN: trackURN,
                message: message
            ),
            at: 0
        )
        if scrobbleHistory.count > 120 {
            scrobbleHistory = Array(scrobbleHistory.prefix(120))
        }
        persistScrobbleHistory()
    }

    private func persistScrobbleHistory() {
        persistence.saveScrobbleHistory(scrobbleHistory)
    }
}
