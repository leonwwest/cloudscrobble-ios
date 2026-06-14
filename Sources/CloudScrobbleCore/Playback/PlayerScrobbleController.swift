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

@MainActor
public final class PlayerScrobbleController: ObservableObject {
    private enum Storage {
        static let savedPlaybackSnapshotKey = "cloudscrobble.savedPlaybackSnapshot.v1"
        static let recentlyPlayedKey = "cloudscrobble.recentlyPlayed.v1"
        static let scrobbleHistoryKey = "cloudscrobble.scrobbleHistory.v1"
    }

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

    private let player = AVQueuePlayer()
    private let scrobbleEngine = ScrobbleEngine()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var debugDismissalTask: Task<Void, Never>?
    private var orderedQueue: [QueueItem] = []
    private var shouldResumeAfterInterruption = false
    private var lastSnapshotPersistedAt: Date?
    private var stalledRecoveryTask: Task<Void, Never>?
#if os(iOS) && canImport(MediaPlayer) && canImport(UIKit)
    private var nowPlayingArtworkTask: Task<Void, Never>?
    private var nowPlayingArtworkTrackURN: String?
    private var nowPlayingArtworkURL: URL?
    private var nowPlayingArtwork: MPMediaItemArtwork?
#endif

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
        self.recentlyPlayed = Self.loadRecentlyPlayed()
        self.scrobbleHistory = Self.loadScrobbleHistory()
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = true
        configureAudioSession()
        installTimeObserver()
        observeTrackEnd()
        observePlaybackProblems()
        observeAudioSession()
        configureRemoteCommands()
    }

    public func setLastFMScrobbler(_ scrobbler: LastFMScrobbleSending?) {
        lastFMScrobbler = scrobbler
        if scrobbler == nil, debugStatus.hasPrefix("Scrobble") || debugStatus == "Now Playing sent" {
            debugStatus = "Last.fm not connected"
        }
        if scrobbler == nil {
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
        orderedQueue = items
        let prepared = preparedQueue(items, startAt: index)
        queue = prepared.items
        currentIndex = nil
        guard !queue.isEmpty else {
            phase = .idle
            elapsedSeconds = 0
            scrobbleEngine.stop()
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
            let remaining = orderedQueue.filter { $0.trackURN != current.trackURN }
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
        orderedQueue.append(item)
        queue.append(item)

        let playerItem = makePlayerItem(for: item)
        if player.canInsert(playerItem, after: nil) {
            player.insert(playerItem, after: nil)
        }

        if currentIndex == nil {
            rebuildPlayerQueue(startAt: 0)
        } else if showDebug {
            persistPlaybackSnapshot()
            setDebugStatus("Added to queue", autoDismissAfter: 2_500_000_000)
        } else {
            persistPlaybackSnapshot()
        }
    }

    public func playNext(_ item: QueueItem) {
        guard let currentIndex else {
            loadQueue([item], startAt: 0)
            return
        }

        let insertIndex = min(currentIndex + 1, queue.count)
        queue.insert(item, at: insertIndex)
        orderedQueue.insert(item, at: min(insertIndex, orderedQueue.count))

        let playerItem = makePlayerItem(for: item)
        if player.canInsert(playerItem, after: player.currentItem) {
            player.insert(playerItem, after: player.currentItem)
        }

        persistPlaybackSnapshot()
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
        orderedQueue.removeAll { $0.trackURN == removedURN }

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

        let currentURN = currentItem?.trackURN
        let resumeTime = elapsedSeconds
        let wasPlaying = isPlaying
        let item = queue.remove(at: source)
        queue.insert(item, at: destination)
        orderedQueue = queue

        if let currentURN {
            currentIndex = queue.firstIndex { $0.trackURN == currentURN }
        }

        rebuildPlayerQueuePreservingCurrent(resumeAt: resumeTime, shouldPlay: wasPlaying)
    }

    public func clearQueue() {
        stalledRecoveryTask?.cancel()
        stalledRecoveryTask = nil
        player.pause()
        player.removeAllItems()
        queue = []
        orderedQueue = []
        currentIndex = nil
        elapsedSeconds = 0
        phase = .idle
        scrobbleEngine.stop()
        clearNowPlayingInfo()
        clearSavedPlaybackSnapshot()
        setDebugStatus("Queue cleared", autoDismissAfter: 2_500_000_000)
    }

    public func clearRecentlyPlayed() {
        recentlyPlayed = []
        UserDefaults.standard.removeObject(forKey: Storage.recentlyPlayedKey)
    }

    public func clearScrobbleHistory() {
        scrobbleHistory = []
        skippedUnplayableCount = 0
        UserDefaults.standard.removeObject(forKey: Storage.scrobbleHistoryKey)
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
        guard let data = UserDefaults.standard.data(forKey: Storage.savedPlaybackSnapshotKey) else {
            return nil
        }
        return try? JSONDecoder().decode(SavedPlaybackSnapshot.self, from: data)
    }

    public func clearSavedPlaybackSnapshot() {
        lastSnapshotPersistedAt = nil
        UserDefaults.standard.removeObject(forKey: Storage.savedPlaybackSnapshotKey)
    }

    public func restoreSavedQueue(_ items: [QueueItem], from snapshot: SavedPlaybackSnapshot) {
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
        player.removeAllItems()

        for item in queue[snapshot.currentIndex...] {
            let playerItem = makePlayerItem(for: item)
            if player.canInsert(playerItem, after: nil) {
                player.insert(playerItem, after: nil)
            }
        }

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
        player.removeAllItems()

        for item in queue[index...] {
            let playerItem = makePlayerItem(for: item)
            if player.canInsert(playerItem, after: nil) {
                player.insert(playerItem, after: nil)
            }
        }

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
            clearNowPlayingInfo()
            clearSavedPlaybackSnapshot()
            return []
        }

        let item = queue[index]
        currentIndex = index
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
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleCurrentTrackEnded()
            }
        }
    }

    private func observePlaybackProblems() {
        failedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let errorMessage = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription
            Task { @MainActor [weak self] in
                self?.handlePlaybackProblem(errorMessage: errorMessage)
            }
        }

        stalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackStalled()
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
            elapsedSeconds = 0
            clearNowPlayingInfo()
            clearSavedPlaybackSnapshot()
            return
        }

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
            orderedQueue.removeAll { $0.trackURN == failedURN }
        }

        player.pause()
        player.removeAllItems()

        guard !queue.isEmpty else {
            scrobbleEngine.stop()
            phase = .idle
            self.currentIndex = nil
            elapsedSeconds = 0
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
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                if case .paused = self?.phase {
                    self?.togglePlayback()
                }
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                if case .playing = self?.phase {
                    self?.togglePlayback()
                }
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.togglePlayback()
            }
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.next()
            }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.previous()
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }

            Task { @MainActor [weak self] in
                self?.seek(to: event.positionTime)
            }
            return .success
        }
#endif
    }

    private func updateNowPlayingInfo(for item: QueueItem, playbackRate: Double) {
#if os(iOS) && canImport(MediaPlayer)
        prepareNowPlayingArtwork(for: item)

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.artistDisplay,
            MPMediaItemPropertyPlaybackDuration: Double(max(item.durationSeconds, 1)),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate
        ]

#if canImport(UIKit)
        if nowPlayingArtworkTrackURN == item.trackURN, let nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }
#endif

        if let permalinkURL = item.permalinkURL {
            info[MPNowPlayingInfoPropertyAssetURL] = permalinkURL
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
#endif
    }

    private func clearNowPlayingInfo() {
#if os(iOS) && canImport(MediaPlayer)
        clearNowPlayingArtwork()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
#endif
    }

    private var isCurrentlyPlaying: Bool {
        isPlaying
    }

    private func prepareNowPlayingArtwork(for item: QueueItem) {
#if os(iOS) && canImport(MediaPlayer) && canImport(UIKit)
        guard nowPlayingArtworkTrackURN != item.trackURN || nowPlayingArtworkURL != item.artworkURL else {
            return
        }

        nowPlayingArtworkTask?.cancel()
        nowPlayingArtworkTrackURN = item.trackURN
        nowPlayingArtworkURL = item.artworkURL
        nowPlayingArtwork = nil

        guard let artworkURL = item.artworkURL else { return }

        nowPlayingArtworkTask = Task { [weak self, trackURN = item.trackURN, artworkURL] in
            do {
                let (data, response) = try await URLSession.shared.data(from: artworkURL)
                guard !Task.isCancelled,
                      (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                      let image = UIImage(data: data) else {
                    return
                }

                let artwork = Self.makeNowPlayingArtwork(from: image)
                await MainActor.run { [weak self] in
                    guard self?.nowPlayingArtworkTrackURN == trackURN,
                          self?.nowPlayingArtworkURL == artworkURL else {
                        return
                    }

                    self?.nowPlayingArtwork = artwork
                    if case .playing(let current) = self?.phase, current.trackURN == trackURN {
                        self?.updateNowPlayingInfo(for: current, playbackRate: 1)
                    } else if case .paused(let current) = self?.phase, current.trackURN == trackURN {
                        self?.updateNowPlayingInfo(for: current, playbackRate: 0)
                    }
                }
            } catch {
                // Artwork is cosmetic; playback should continue if loading fails.
            }
        }
#endif
    }

#if os(iOS) && canImport(MediaPlayer) && canImport(UIKit)
    private nonisolated static func makeNowPlayingArtwork(from image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
#endif

    private func clearNowPlayingArtwork() {
#if os(iOS) && canImport(MediaPlayer) && canImport(UIKit)
        nowPlayingArtworkTask?.cancel()
        nowPlayingArtworkTask = nil
        nowPlayingArtworkTrackURN = nil
        nowPlayingArtworkURL = nil
        nowPlayingArtwork = nil
#endif
    }

    private func dispatch(events: [ScrobbleEngineEvent]) async {
        guard let lastFMScrobbler else {
            if !events.isEmpty {
                debugStatus = "Last.fm not connected"
            }
            return
        }

        for event in events {
            do {
                switch event {
                case .sendNowPlaying(let meta, let duration):
                    try await lastFMScrobbler.updateNowPlaying(meta: meta, durationSeconds: duration)
                    pendingScrobbleCount = await lastFMScrobbler.pendingScrobbleCount()
                    lastScrobbleError = nil
                    recordScrobbleHistory(event: .nowPlaying, meta: meta, message: duration.map { "\($0)s" })
                    setDebugStatus("Now Playing sent", autoDismissAfter: 2_800_000_000)
                case .sendScrobble(let meta, let timestamp):
                    try await lastFMScrobbler.scrobble(meta: meta, timestamp: timestamp)
                    let pending = await lastFMScrobbler.pendingScrobbleCount()
                    pendingScrobbleCount = pending
                    lastScrobbleSucceededAt = Date()
                    lastScrobbleError = nil
                    recordScrobbleHistory(
                        event: pending == 0 ? .scrobbled : .queued,
                        meta: meta,
                        message: pending == 0 ? nil : "\(pending) pending"
                    )
                    setDebugStatus(
                        pending == 0 ? "Track scrobbled" : "Scrobble queued (\(pending) pending)",
                        autoDismissAfter: pending == 0 ? 3_200_000_000 : nil
                    )
                }
            } catch {
                pendingScrobbleCount = await lastFMScrobbler.pendingScrobbleCount()
                lastScrobbleError = error.localizedDescription
                if case .sendNowPlaying(let meta, _) = event {
                    recordScrobbleHistory(event: .failed, meta: meta, message: error.localizedDescription)
                } else if case .sendScrobble(let meta, _) = event {
                    recordScrobbleHistory(event: .failed, meta: meta, message: error.localizedDescription)
                }
                setDebugStatus("Scrobble error: \(error.localizedDescription)")
            }
        }
    }

    private func dispatchLater(_ events: [ScrobbleEngineEvent]) {
        guard !events.isEmpty else { return }
        Task { [weak self] in
            await self?.dispatch(events: events)
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

        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Storage.savedPlaybackSnapshotKey)
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
        player.removeAllItems()

        for item in queue[currentIndex...] {
            let playerItem = makePlayerItem(for: item)
            if player.canInsert(playerItem, after: nil) {
                player.insert(playerItem, after: nil)
            }
        }

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
        guard let data = try? JSONEncoder().encode(recentlyPlayed) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Storage.recentlyPlayedKey)
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
        message: String? = nil
    ) {
        let trackURN = currentItem?.lastFM == meta ? currentItem?.trackURN : nil
        recordScrobbleHistory(
            event: event,
            title: meta.track,
            artist: meta.artist,
            trackURN: trackURN,
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
        guard let data = try? JSONEncoder().encode(scrobbleHistory) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Storage.scrobbleHistoryKey)
    }

    private static func loadRecentlyPlayed() -> [SavedPlaybackTrack] {
        guard let data = UserDefaults.standard.data(forKey: Storage.recentlyPlayedKey),
              let decoded = try? JSONDecoder().decode([SavedPlaybackTrack].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func loadScrobbleHistory() -> [ScrobbleHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: Storage.scrobbleHistoryKey),
              let decoded = try? JSONDecoder().decode([ScrobbleHistoryEntry].self, from: data) else {
            return []
        }
        return decoded
    }
}
