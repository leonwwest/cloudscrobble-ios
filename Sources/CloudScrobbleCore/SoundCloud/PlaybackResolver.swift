import Foundation

public actor PlaybackResolver: PlaybackResolving {
    private let api: SoundCloudAPIClienting
    private var streamCache: [String: ResolvedPlaybackStream] = [:]

    public init(api: SoundCloudAPIClienting) {
        self.api = api
    }

    public func resolvePlayableStream(for trackURN: String) async throws -> ResolvedPlaybackStream {
        if let cached = streamCache[trackURN] {
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
        if streamCache.count > 120 {
            streamCache.removeValue(forKey: streamCache.keys.first ?? trackURN)
        }
        return stream
    }
}
