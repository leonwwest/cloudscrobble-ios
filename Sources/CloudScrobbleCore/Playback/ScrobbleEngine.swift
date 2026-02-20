import Foundation

public enum ScrobbleEngineEvent: Equatable, Sendable {
    case sendNowPlaying(meta: LastFMTrackMeta, duration: Int?)
    case sendScrobble(meta: LastFMTrackMeta, timestamp: Int)
}

public final class ScrobbleEngine {
    public private(set) var state = ScrobbleState()

    private var currentTrack: QueueItem?
    private var thresholdSeconds: TimeInterval?
    private var isPaused = false
    private var previousPlaybackTime: TimeInterval?

    public init() {}

    public func start(track: QueueItem, startedAt: Date = Date()) -> [ScrobbleEngineEvent] {
        state = ScrobbleState()
        state.trackStartedAtUnix = Int(startedAt.timeIntervalSince1970)

        currentTrack = track
        isPaused = false
        previousPlaybackTime = nil

        if track.durationSeconds >= 30 {
            let dynamicThreshold = min(TimeInterval(track.durationSeconds) * 0.5, 240)
            thresholdSeconds = max(30, dynamicThreshold)
            state.scrobbleThresholdSeconds = thresholdSeconds ?? 0
        } else {
            thresholdSeconds = nil
        }

        state.didSendNowPlaying = true
        return [.sendNowPlaying(meta: track.lastFM, duration: track.durationSeconds)]
    }

    public func pause() {
        isPaused = true
    }

    public func resume() {
        isPaused = false
        previousPlaybackTime = nil
    }

    public func stop() {
        currentTrack = nil
        thresholdSeconds = nil
        previousPlaybackTime = nil
        isPaused = false
        state = ScrobbleState()
    }

    public func tick(playbackTime: TimeInterval) -> [ScrobbleEngineEvent] {
        guard let currentTrack,
              let thresholdSeconds,
              !state.didScrobble,
              !isPaused else {
            previousPlaybackTime = playbackTime
            return []
        }

        defer {
            previousPlaybackTime = playbackTime
        }

        if let previousPlaybackTime {
            let rawDelta = playbackTime - previousPlaybackTime
            if rawDelta > 0 {
                // Ignore large jumps caused by seeking.
                let clampedDelta = min(rawDelta, 2.5)
                state.listenedSeconds += clampedDelta
            }
        }

        guard state.listenedSeconds >= thresholdSeconds,
              let startedAt = state.trackStartedAtUnix else {
            return []
        }

        state.didScrobble = true
        return [.sendScrobble(meta: currentTrack.lastFM, timestamp: startedAt)]
    }
}
