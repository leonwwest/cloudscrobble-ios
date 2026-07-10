import Foundation

public enum ScrobbleEngineEvent: Equatable, Sendable {
    case sendNowPlaying(trackURN: String, meta: LastFMTrackMeta, duration: Int?)
    case sendScrobble(trackURN: String, meta: LastFMTrackMeta, timestamp: Int)
}

@MainActor
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

        if track.scrobbleEnabled, track.durationSeconds >= 30 {
            let dynamicThreshold = min(TimeInterval(track.durationSeconds) * 0.5, 240)
            thresholdSeconds = max(30, dynamicThreshold)
            state.scrobbleThresholdSeconds = thresholdSeconds ?? 0
        } else {
            thresholdSeconds = nil
        }

        guard track.scrobbleEnabled else {
            state.didSendNowPlaying = false
            return []
        }

        state.didSendNowPlaying = true
        return [.sendNowPlaying(trackURN: track.trackURN, meta: track.lastFM, duration: track.durationSeconds)]
    }

    public func pause() {
        isPaused = true
    }

    public func resume() {
        isPaused = false
        previousPlaybackTime = nil
    }

    public func restore(track: QueueItem, state restoredState: ScrobbleState, playbackTime: TimeInterval, isPaused: Bool) {
        currentTrack = track
        state = restoredState
        thresholdSeconds = track.scrobbleEnabled && restoredState.scrobbleThresholdSeconds > 0
            ? restoredState.scrobbleThresholdSeconds
            : nil
        self.isPaused = isPaused
        previousPlaybackTime = playbackTime
    }

    /// Replaces the Last.fm metadata for the active track without losing
    /// listened-time progress. Used after an in-player metadata correction.
    public func updateTrack(_ track: QueueItem) -> [ScrobbleEngineEvent] {
        guard currentTrack?.trackURN == track.trackURN else { return [] }
        currentTrack = track

        guard track.scrobbleEnabled else {
            thresholdSeconds = nil
            state.scrobbleThresholdSeconds = 0
            state.didSendNowPlaying = false
            return []
        }

        if track.durationSeconds >= 30 {
            let dynamicThreshold = min(TimeInterval(track.durationSeconds) * 0.5, 240)
            thresholdSeconds = max(30, dynamicThreshold)
            state.scrobbleThresholdSeconds = thresholdSeconds ?? 0
        } else {
            thresholdSeconds = nil
            state.scrobbleThresholdSeconds = 0
        }

        state.didSendNowPlaying = true
        return [.sendNowPlaying(trackURN: track.trackURN, meta: track.lastFM, duration: track.durationSeconds)]
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
              currentTrack.scrobbleEnabled,
              let thresholdSeconds,
              !state.didScrobble,
              !isPaused else {
            previousPlaybackTime = playbackTime
            return []
        }

        recordListenedTime(playbackTime: playbackTime)

        guard state.listenedSeconds >= thresholdSeconds,
              let startedAt = state.trackStartedAtUnix else {
            return []
        }

        state.didScrobble = true
        return [.sendScrobble(trackURN: currentTrack.trackURN, meta: currentTrack.lastFM, timestamp: startedAt)]
    }

    public func finish(playbackTime: TimeInterval) -> [ScrobbleEngineEvent] {
        guard let currentTrack,
              currentTrack.scrobbleEnabled,
              let thresholdSeconds,
              !state.didScrobble,
              !isPaused else {
            previousPlaybackTime = playbackTime
            return []
        }

        recordListenedTime(playbackTime: playbackTime)

        guard state.listenedSeconds >= thresholdSeconds,
              let startedAt = state.trackStartedAtUnix else {
            return []
        }

        state.didScrobble = true
        return [.sendScrobble(trackURN: currentTrack.trackURN, meta: currentTrack.lastFM, timestamp: startedAt)]
    }

    private func recordListenedTime(playbackTime: TimeInterval) {
        defer {
            previousPlaybackTime = playbackTime
        }

        guard let previousPlaybackTime else { return }

        let rawDelta = playbackTime - previousPlaybackTime
        if rawDelta > 0 {
            // Ignore large jumps caused by seeking.
            let clampedDelta = min(rawDelta, 2.5)
            state.listenedSeconds += clampedDelta
        }
    }
}
