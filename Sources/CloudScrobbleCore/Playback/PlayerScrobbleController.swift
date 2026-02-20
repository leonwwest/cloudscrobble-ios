import AVFoundation
import Combine
import Foundation

public enum PlaybackPhase: Equatable {
    case idle
    case loading
    case playing(QueueItem)
    case paused(QueueItem)
    case failed(String)
}

@MainActor
public final class PlayerScrobbleController: ObservableObject {
    @Published public private(set) var phase: PlaybackPhase = .idle
    @Published public private(set) var queue: [QueueItem] = []
    @Published public private(set) var currentIndex: Int?
    @Published public private(set) var elapsedSeconds: TimeInterval = 0
    @Published public private(set) var debugStatus: String = ""

    private let player = AVPlayer()
    private let scrobbleEngine = ScrobbleEngine()
    private var timeObserver: Any?

    private let lastFMScrobbler: LastFMScrobbleSending?

    public init(lastFMScrobbler: LastFMScrobbleSending?) {
        self.lastFMScrobbler = lastFMScrobbler
        installTimeObserver()
        observeTrackEnd()
    }

    public func loadQueue(_ items: [QueueItem], startAt index: Int = 0) {
        queue = items
        currentIndex = nil
        guard items.indices.contains(index) else {
            phase = .idle
            return
        }

        Task {
            await playIndex(index)
        }
    }

    public func togglePlayback() {
        switch phase {
        case .playing(let item):
            player.pause()
            scrobbleEngine.pause()
            phase = .paused(item)
        case .paused(let item):
            player.play()
            scrobbleEngine.resume()
            phase = .playing(item)
        default:
            break
        }
    }

    public func seek(to seconds: TimeInterval) {
        let target = CMTime(seconds: seconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player.seek(to: target)
        elapsedSeconds = seconds
    }

    public func next() {
        guard let currentIndex else { return }
        let nextIndex = currentIndex + 1
        guard queue.indices.contains(nextIndex) else { return }
        Task {
            await playIndex(nextIndex)
        }
    }

    public func previous() {
        guard let currentIndex else { return }
        let previousIndex = max(0, currentIndex - 1)
        Task {
            await playIndex(previousIndex)
        }
    }

    private func playIndex(_ index: Int) async {
        guard queue.indices.contains(index) else { return }
        let item = queue[index]

        phase = .loading
        currentIndex = index
        elapsedSeconds = 0

        scrobbleEngine.stop()
        _ = scrobbleEngine.start(track: item)

        player.replaceCurrentItem(with: AVPlayerItem(url: item.streamURL))
        player.play()
        phase = .playing(item)

        await dispatch(events: [.sendNowPlaying(meta: item.lastFM, duration: item.durationSeconds)])
    }

    private func observeTrackEnd() {
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.next()
            }
        }
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                await self.handleTick(time: time.seconds)
            }
        }
    }

    private func handleTick(time: TimeInterval) async {
        elapsedSeconds = max(0, time)
        let events = scrobbleEngine.tick(playbackTime: elapsedSeconds)
        await dispatch(events: events)
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
                    debugStatus = "Now Playing sent"
                case .sendScrobble(let meta, let timestamp):
                    try await lastFMScrobbler.scrobble(meta: meta, timestamp: timestamp)
                    let pending = await lastFMScrobbler.pendingScrobbleCount()
                    debugStatus = pending == 0 ? "Track scrobbled" : "Scrobble queued (\(pending) pending)"
                }
            } catch {
                debugStatus = "Scrobble error: \(error.localizedDescription)"
            }
        }
    }
}
