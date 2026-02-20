import Foundation

public struct SCPage<T: Decodable & Sendable>: Decodable, Sendable {
    public let collection: [T]
    public let nextHref: URL?

    enum CodingKeys: String, CodingKey {
        case collection
        case nextHref = "next_href"
    }
}

public struct SCUser: Codable, Identifiable, Sendable {
    public let urn: String
    public let username: String
    public let permalink: String?
    public let permalinkURL: URL?
    public let avatarURL: URL?

    public var id: String { urn }

    enum CodingKeys: String, CodingKey {
        case urn
        case username
        case permalink
        case permalinkURL = "permalink_url"
        case avatarURL = "avatar_url"
    }
}

public struct SCPublisherMetadata: Codable, Sendable {
    public let artist: String?
    public let releaseTitle: String?

    enum CodingKeys: String, CodingKey {
        case artist
        case releaseTitle = "release_title"
    }
}

public struct SCTrack: Codable, Identifiable, Sendable {
    public let urn: String
    public let title: String
    public let durationMs: Int
    public let artworkURL: URL?
    public let permalinkURL: URL?
    public let user: SCUser
    public let publisherMetadata: SCPublisherMetadata?
    public let access: String?

    public var id: String { urn }

    enum CodingKeys: String, CodingKey {
        case urn
        case title
        case user
        case access
        case durationMs = "duration"
        case artworkURL = "artwork_url"
        case permalinkURL = "permalink_url"
        case publisherMetadata = "publisher_metadata"
    }
}

public struct SCPlaylistTrackItem: Codable, Identifiable, Sendable {
    public let urn: String
    public let title: String?
    public let user: SCUser?

    public var id: String { urn }
}

public struct SCPlaylist: Codable, Identifiable, Sendable {
    public let urn: String
    public let title: String
    public let artworkURL: URL?
    public let user: SCUser
    public let tracks: [SCPlaylistTrackItem]?

    public var id: String { urn }

    enum CodingKeys: String, CodingKey {
        case urn
        case title
        case user
        case tracks
        case artworkURL = "artwork_url"
    }
}

public struct SCStreams: Codable, Sendable {
    public let hlsAac160URL: URL?
    public let hlsAac96URL: URL?

    enum CodingKeys: String, CodingKey {
        case hlsAac160URL = "hls_aac_160_url"
        case hlsAac96URL = "hls_aac_96_url"
    }
}

public struct LastFMTrackMeta: Codable, Equatable, Sendable {
    public let artist: String
    public let track: String

    public init(artist: String, track: String) {
        self.artist = artist
        self.track = track
    }
}

public struct QueueItem: Equatable, Identifiable, Sendable {
    public let trackURN: String
    public let title: String
    public let artistDisplay: String
    public let artworkURL: URL?
    public let permalinkURL: URL?
    public let streamURL: URL
    public let durationSeconds: Int
    public let lastFM: LastFMTrackMeta

    public var id: String { trackURN }

    public init(
        trackURN: String,
        title: String,
        artistDisplay: String,
        artworkURL: URL?,
        permalinkURL: URL?,
        streamURL: URL,
        durationSeconds: Int,
        lastFM: LastFMTrackMeta
    ) {
        self.trackURN = trackURN
        self.title = title
        self.artistDisplay = artistDisplay
        self.artworkURL = artworkURL
        self.permalinkURL = permalinkURL
        self.streamURL = streamURL
        self.durationSeconds = durationSeconds
        self.lastFM = lastFM
    }
}

public struct ScrobbleState: Equatable, Sendable {
    public var didSendNowPlaying = false
    public var didScrobble = false
    public var trackStartedAtUnix: Int?
    public var scrobbleThresholdSeconds: TimeInterval = 0
    public var listenedSeconds: TimeInterval = 0

    public init() {}
}
