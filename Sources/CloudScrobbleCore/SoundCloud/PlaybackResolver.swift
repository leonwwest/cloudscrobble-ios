import Foundation

public actor PlaybackResolver: PlaybackResolving {
    private let api: SoundCloudAPIClienting

    public init(api: SoundCloudAPIClienting) {
        self.api = api
    }

    public func resolvePlayableStream(for trackURN: String) async throws -> ResolvedPlaybackStream {
        let streams = try await api.streams(trackURN: trackURN)
        let headers = try await api.streamRequestHeaders()

        if let url = streams.hlsAac160URL {
            return ResolvedPlaybackStream(url: url, headers: headers)
        }

        if let url = streams.hlsAac96URL {
            return ResolvedPlaybackStream(url: url, headers: headers)
        }

        if let url = streams.hlsMP3128URL {
            return ResolvedPlaybackStream(url: url, headers: headers)
        }

        if let url = streams.httpMP3128URL {
            return ResolvedPlaybackStream(url: url, headers: headers)
        }

        // Fallback for endpoint drift between /streams and legacy /stream.
        let fallbackURL = try await api.legacyStreamURL(trackURN: trackURN)
        guard fallbackURL.pathExtension == "m3u8" || fallbackURL.scheme?.hasPrefix("http") == true else {
            throw CloudScrobbleError.unsupportedStream
        }

        return ResolvedPlaybackStream(url: fallbackURL, headers: headers)
    }
}
