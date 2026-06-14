import Foundation

public enum ScrobbleHistoryEvent: String, Codable, Sendable {
    case nowPlaying
    case scrobbled
    case queued
    case failed
    case skipped
}

public struct ScrobbleHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let event: ScrobbleHistoryEvent
    public let title: String
    public let artist: String
    public let trackURN: String?
    public let message: String?
    public let occurredAt: Date

    public init(
        id: UUID = UUID(),
        event: ScrobbleHistoryEvent,
        title: String,
        artist: String,
        trackURN: String?,
        message: String? = nil,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.event = event
        self.title = title
        self.artist = artist
        self.trackURN = trackURN
        self.message = message
        self.occurredAt = occurredAt
    }
}
