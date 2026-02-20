import Foundation

public struct PendingScrobble: Codable, Equatable, Sendable {
    public let meta: LastFMTrackMeta
    public let timestamp: Int
    public let createdAtUnix: Int

    public init(meta: LastFMTrackMeta, timestamp: Int, createdAtUnix: Int = Int(Date().timeIntervalSince1970)) {
        self.meta = meta
        self.timestamp = timestamp
        self.createdAtUnix = createdAtUnix
    }
}
