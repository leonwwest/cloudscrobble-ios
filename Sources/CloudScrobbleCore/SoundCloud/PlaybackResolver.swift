import Foundation

public actor PlaybackResolver: PlaybackResolving {
    private let api: SoundCloudAPIClienting

    public init(api: SoundCloudAPIClienting) {
        self.api = api
    }

    public func resolvePlayableURL(for trackURN: String) async throws -> URL {
        let streams = try await api.streams(trackURN: trackURN)

        if let url = streams.hlsAac160URL {
            return url
        }

        if let url = streams.hlsAac96URL {
            return url
        }

        // Fallback for endpoint drift between /streams and legacy /stream.
        let fallbackURL = try await api.legacyStreamURL(trackURN: trackURN)
        guard fallbackURL.pathExtension == "m3u8" || fallbackURL.scheme?.hasPrefix("http") == true else {
            throw CloudScrobbleError.unsupportedStream
        }

        return fallbackURL
    }
}
