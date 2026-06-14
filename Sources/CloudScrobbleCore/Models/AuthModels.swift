import Foundation

public struct SoundCloudToken: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let tokenType: String?
    public let scope: String?
    public let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case scope
        case expiresIn = "expires_in"
        case expiresAtUnix = "expires_at_unix"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)

        if let expiresAtUnix = try container.decodeIfPresent(Double.self, forKey: .expiresAtUnix) {
            expiresAt = Date(timeIntervalSince1970: expiresAtUnix)
        } else if let expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn) {
            expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        } else {
            expiresAt = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try container.encodeIfPresent(tokenType, forKey: .tokenType)
        try container.encodeIfPresent(scope, forKey: .scope)

        try container.encodeIfPresent(expiresAt?.timeIntervalSince1970, forKey: .expiresAtUnix)
    }

    public init(
        accessToken: String,
        refreshToken: String?,
        tokenType: String?,
        scope: String?,
        expiresAt: Date?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.scope = scope
        self.expiresAt = expiresAt
    }

    public func isExpired(leeway: TimeInterval = 45) -> Bool {
        guard let expiresAt else { return false }
        return Date().addingTimeInterval(leeway) >= expiresAt
    }
}

public struct LastFMSession: Codable, Sendable {
    public let name: String
    public let key: String
    public let subscriber: Int
}

public struct LastFMTasteProfile: Codable, Equatable, Sendable {
    public let username: String
    public let recentTracks: [LastFMTasteTrack]
    public let topArtists: [LastFMTasteArtist]

    public init(username: String, recentTracks: [LastFMTasteTrack], topArtists: [LastFMTasteArtist]) {
        self.username = username
        self.recentTracks = recentTracks
        self.topArtists = topArtists
    }
}

public struct LastFMTasteTrack: Codable, Equatable, Sendable {
    public let artist: String
    public let name: String

    public init(artist: String, name: String) {
        self.artist = artist
        self.name = name
    }
}

public struct LastFMTasteArtist: Codable, Equatable, Sendable {
    public let name: String
    public let playcount: Int

    public init(name: String, playcount: Int) {
        self.name = name
        self.playcount = playcount
    }
}
