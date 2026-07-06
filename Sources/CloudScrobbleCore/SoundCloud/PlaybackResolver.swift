import Foundation

public actor PlaybackResolver: PlaybackResolving {
    private let api: SoundCloudAPIClienting
    private var streamCache: [String: ResolvedPlaybackStream] = [:]
    // LRU access order: least-recently-used at the front, most-recently-used
    // at the tail. Replaces the previous `Dictionary.keys.first` eviction,
    // which removed an arbitrary (hash-ordered) entry.
    private var cacheOrder: [String] = []
    private let maxCacheSize: Int

    public init(api: SoundCloudAPIClienting, maxCacheSize: Int = 120) {
        self.api = api
        self.maxCacheSize = maxCacheSize
    }

    public func resolvePlayableStream(for trackURN: String) async throws -> ResolvedPlaybackStream {
        if let cached = streamCache[trackURN] {
            touchCacheOrder(trackURN)
            return cached
        }

        let streams = try await api.streams(trackURN: trackURN)
        let headers = try await api.streamRequestHeaders()

        if let url = streams.hlsAac160URL {
            return cache(ResolvedPlaybackStream(url: url, headers: headers), for: trackURN)
        }

        if let url = streams.hlsAac96URL {
            return cache(ResolvedPlaybackStream(url: url, headers: headers), for: trackURN)
        }

        if let url = streams.hlsMP3128URL {
            return cache(ResolvedPlaybackStream(url: url, headers: headers), for: trackURN)
        }

        if let url = streams.httpMP3128URL {
            return cache(ResolvedPlaybackStream(url: url, headers: headers), for: trackURN)
        }

        // Fallback for endpoint drift between /streams and legacy /stream.
        let fallbackURL = try await api.legacyStreamURL(trackURN: trackURN)
        guard fallbackURL.pathExtension == "m3u8" || fallbackURL.scheme?.hasPrefix("http") == true else {
            throw CloudScrobbleError.unsupportedStream
        }

        return cache(ResolvedPlaybackStream(url: fallbackURL, headers: headers), for: trackURN)
    }

    public func prefetchPlayableStreams(for trackURNs: [String]) async {
        let candidates = Array(trackURNs.filter { streamCache[$0] == nil }.prefix(4))
        for trackURN in candidates {
            _ = try? await resolvePlayableStream(for: trackURN)
        }
    }

    private func cache(_ stream: ResolvedPlaybackStream, for trackURN: String) -> ResolvedPlaybackStream {
        streamCache[trackURN] = stream
        touchCacheOrder(trackURN)

        if streamCache.count > maxCacheSize, let evict = cacheOrder.first {
            cacheOrder.removeFirst()
            streamCache.removeValue(forKey: evict)
        }

        return stream
    }

    private func touchCacheOrder(_ trackURN: String) {
        cacheOrder.removeAll { $0 == trackURN }
        cacheOrder.append(trackURN)
    }
}
