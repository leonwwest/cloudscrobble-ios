import Foundation

public struct SCPage<T: Decodable & Sendable>: Decodable, Sendable {
    public let collection: [T]
    public let nextHref: URL?

    enum CodingKeys: String, CodingKey {
        case collection
        case nextHref = "next_href"
    }

    public init(collection: [T], nextHref: URL? = nil) {
        self.collection = collection
        self.nextHref = nextHref
    }

    public init(from decoder: Decoder) throws {
        if var unkeyedContainer = try? decoder.unkeyedContainer() {
            var collection: [T] = []
            while !unkeyedContainer.isAtEnd {
                collection.append(try unkeyedContainer.decode(T.self))
            }
            self.collection = collection
            nextHref = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        collection = try container.decode([T].self, forKey: .collection)
        nextHref = try container.decodeIfPresent(URL.self, forKey: .nextHref)
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

public struct SCActivity: Decodable, Identifiable, Sendable {
    public enum Origin: Sendable {
        case track(SCTrack)
        case playlist(SCPlaylist)
        case unknown
    }

    public let type: String
    public let createdAt: String
    public let origin: Origin
    public let reposter: String?

    public var id: String {
        "\(type):\(originID):\(createdAt)"
    }

    public var track: SCTrack? {
        if case .track(let track) = origin {
            return track
        }
        return nil
    }

    public var playlist: SCPlaylist? {
        if case .playlist(let playlist) = origin {
            return playlist
        }
        return nil
    }

    private var originID: String {
        switch origin {
        case .track(let track):
            return track.urn
        case .playlist(let playlist):
            return playlist.urn
        case .unknown:
            return "unknown"
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case origin
        case reposter
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        reposter = try container.decodeIfPresent(String.self, forKey: .reposter)

        if let track = try? container.decode(SCTrack.self, forKey: .origin) {
            origin = .track(track)
        } else if let playlist = try? container.decode(SCPlaylist.self, forKey: .origin) {
            origin = .playlist(playlist)
        } else {
            origin = .unknown
        }
    }
}

public struct SCStreams: Codable, Sendable {
    public let hlsAac160URL: URL?
    public let hlsAac96URL: URL?
    public let hlsMP3128URL: URL?
    public let httpMP3128URL: URL?
    public let previewMP3128URL: URL?

    enum CodingKeys: String, CodingKey {
        case hlsAac160URL = "hls_aac_160_url"
        case hlsAac96URL = "hls_aac_96_url"
        case hlsMP3128URL = "hls_mp3_128_url"
        case httpMP3128URL = "http_mp3_128_url"
        case previewMP3128URL = "preview_mp3_128_url"
    }

    public init(
        hlsAac160URL: URL? = nil,
        hlsAac96URL: URL? = nil,
        hlsMP3128URL: URL? = nil,
        httpMP3128URL: URL? = nil,
        previewMP3128URL: URL? = nil
    ) {
        self.hlsAac160URL = hlsAac160URL
        self.hlsAac96URL = hlsAac96URL
        self.hlsMP3128URL = hlsMP3128URL
        self.httpMP3128URL = httpMP3128URL
        self.previewMP3128URL = previewMP3128URL
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
    public let streamHeaders: [String: String]
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
        streamHeaders: [String: String] = [:],
        durationSeconds: Int,
        lastFM: LastFMTrackMeta
    ) {
        self.trackURN = trackURN
        self.title = title
        self.artistDisplay = artistDisplay
        self.artworkURL = artworkURL
        self.permalinkURL = permalinkURL
        self.streamURL = streamURL
        self.streamHeaders = streamHeaders
        self.durationSeconds = durationSeconds
        self.lastFM = lastFM
    }
}

public struct SavedPlaybackTrack: Codable, Equatable, Identifiable, Sendable {
    public let trackURN: String
    public let title: String
    public let artistDisplay: String
    public let artworkURL: URL?
    public let permalinkURL: URL?
    public let durationSeconds: Int
    public let lastFM: LastFMTrackMeta

    public var id: String { trackURN }

    public init(
        trackURN: String,
        title: String,
        artistDisplay: String,
        artworkURL: URL?,
        permalinkURL: URL?,
        durationSeconds: Int,
        lastFM: LastFMTrackMeta
    ) {
        self.trackURN = trackURN
        self.title = title
        self.artistDisplay = artistDisplay
        self.artworkURL = artworkURL
        self.permalinkURL = permalinkURL
        self.durationSeconds = durationSeconds
        self.lastFM = lastFM
    }

    public init(queueItem: QueueItem) {
        self.init(
            trackURN: queueItem.trackURN,
            title: queueItem.title,
            artistDisplay: queueItem.artistDisplay,
            artworkURL: queueItem.artworkURL,
            permalinkURL: queueItem.permalinkURL,
            durationSeconds: queueItem.durationSeconds,
            lastFM: queueItem.lastFM
        )
    }
}

public struct SavedPlaybackSnapshot: Codable, Equatable, Sendable {
    public let queue: [SavedPlaybackTrack]
    public let currentIndex: Int
    public let elapsedSeconds: TimeInterval
    public let scrobbleState: ScrobbleState
    public let repeatModeRawValue: String
    public let isShuffleEnabled: Bool
    public let updatedAtUnix: Int

    public init(
        queue: [SavedPlaybackTrack],
        currentIndex: Int,
        elapsedSeconds: TimeInterval,
        scrobbleState: ScrobbleState,
        repeatModeRawValue: String,
        isShuffleEnabled: Bool,
        updatedAtUnix: Int = Int(Date().timeIntervalSince1970)
    ) {
        self.queue = queue
        self.currentIndex = currentIndex
        self.elapsedSeconds = elapsedSeconds
        self.scrobbleState = scrobbleState
        self.repeatModeRawValue = repeatModeRawValue
        self.isShuffleEnabled = isShuffleEnabled
        self.updatedAtUnix = updatedAtUnix
    }
}

public struct ResolvedPlaybackStream: Equatable, Sendable {
    public let url: URL
    public let headers: [String: String]

    public init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }
}

public struct ScrobbleState: Codable, Equatable, Sendable {
    public var didSendNowPlaying = false
    public var didScrobble = false
    public var trackStartedAtUnix: Int?
    public var scrobbleThresholdSeconds: TimeInterval = 0
    public var listenedSeconds: TimeInterval = 0

    public init() {}
}
