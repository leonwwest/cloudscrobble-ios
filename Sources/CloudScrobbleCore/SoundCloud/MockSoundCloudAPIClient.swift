import Foundation

public actor MockSoundCloudAPIClient: SoundCloudAPIClienting {
    public static let demoStreamURL = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")!

    private let meUser: SCUser
    private let users: [SCUser]
    private let tracks: [SCTrack]
    private let playlists: [SCPlaylist]
    private let tracksByURN: [String: SCTrack]
    private let playlistsByURN: [String: SCPlaylist]
    private let userTracksIndex: [String: [SCTrack]]
    private let userPlaylistsIndex: [String: [SCPlaylist]]

    public init() {
        let userMe = SCUser(
            urn: "soundcloud:users:demo:me",
            username: "CloudScrobble Demo",
            permalink: "cloudscrobble-demo",
            permalinkURL: URL(string: "https://soundcloud.com/cloudscrobble-demo"),
            avatarURL: URL(string: "https://picsum.photos/seed/cloud-demo/300")
        )
        let userLo = SCUser(
            urn: "soundcloud:users:demo:lo",
            username: "Lo Skyline",
            permalink: "lo-skyline",
            permalinkURL: URL(string: "https://soundcloud.com/lo-skyline"),
            avatarURL: URL(string: "https://picsum.photos/seed/lo-skyline/300")
        )
        let userAri = SCUser(
            urn: "soundcloud:users:demo:ari",
            username: "Ari Pulse",
            permalink: "ari-pulse",
            permalinkURL: URL(string: "https://soundcloud.com/ari-pulse"),
            avatarURL: URL(string: "https://picsum.photos/seed/ari-pulse/300")
        )
        let userNova = SCUser(
            urn: "soundcloud:users:demo:nova",
            username: "Nova Tide",
            permalink: "nova-tide",
            permalinkURL: URL(string: "https://soundcloud.com/nova-tide"),
            avatarURL: URL(string: "https://picsum.photos/seed/nova-tide/300")
        )

        meUser = userMe
        users = [userMe, userLo, userAri, userNova]

        let t1 = Self.makeTrack(
            id: "aurora-rise",
            title: "Aurora Rise",
            artist: "Lo Skyline",
            user: userLo
        )
        let t2 = Self.makeTrack(
            id: "night-drive",
            title: "Night Drive 03:12",
            artist: "Ari Pulse",
            user: userAri
        )
        let t3 = Self.makeTrack(
            id: "glass-ocean",
            title: "Glass Ocean (Demo Session)",
            artist: "Nova Tide",
            user: userNova
        )
        let t4 = Self.makeTrack(
            id: "coastline",
            title: "Coastline (CloudScrobble Edit)",
            artist: "CloudScrobble Demo",
            user: userMe
        )
        let t5 = Self.makeTrack(
            id: "afterglow",
            title: "Afterglow",
            artist: "Lo Skyline",
            user: userLo
        )

        tracks = [t1, t2, t3, t4, t5]
        tracksByURN = Dictionary(uniqueKeysWithValues: tracks.map { ($0.urn, $0) })

        let p1 = Self.makePlaylist(
            id: "demo-favs",
            title: "Demo Favorites",
            user: userMe,
            tracks: [t1, t3, t4]
        )
        let p2 = Self.makePlaylist(
            id: "night-pack",
            title: "Night Pack",
            user: userAri,
            tracks: [t2, t5]
        )

        playlists = [p1, p2]
        playlistsByURN = Dictionary(uniqueKeysWithValues: playlists.map { ($0.urn, $0) })

        userTracksIndex = [
            userMe.urn: [t4],
            userLo.urn: [t1, t5],
            userAri.urn: [t2],
            userNova.urn: [t3]
        ]
        userPlaylistsIndex = [
            userMe.urn: [p1],
            userAri.urn: [p2]
        ]
    }

    public func me() async throws -> SCUser {
        meUser
    }

    public func searchTracks(query: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack> {
        makePage(collection: filterTracks(query: query), limit: limit)
    }

    public func searchPlaylists(query: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCPlaylist> {
        let normalized = query.lowercased()
        let filtered = playlists.filter {
            $0.title.lowercased().contains(normalized) || $0.user.username.lowercased().contains(normalized)
        }
        return makePage(collection: filtered, limit: limit)
    }

    public func searchUsers(query: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCUser> {
        let normalized = query.lowercased()
        let filtered = users.filter {
            $0.username.lowercased().contains(normalized)
        }
        return makePage(collection: filtered, limit: limit)
    }

    public func user(urn: String) async throws -> SCUser {
        guard let user = users.first(where: { $0.urn == urn }) else {
            throw CloudScrobbleError.invalidConfiguration("Mock user not found for urn: \(urn)")
        }
        return user
    }

    public func userTracks(urn: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack> {
        makePage(collection: userTracksIndex[urn] ?? [], limit: limit)
    }

    public func userPlaylists(urn: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCPlaylist> {
        makePage(collection: userPlaylistsIndex[urn] ?? [], limit: limit)
    }

    public func userLikesTracks(urn: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack> {
        makePage(collection: tracks.shuffled(), limit: limit)
    }

    public func userLikesPlaylists(urn: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCPlaylist> {
        makePage(collection: playlists, limit: limit)
    }

    public func myPlaylists(limit: Int, nextHref: URL?) async throws -> SCPage<SCPlaylist> {
        makePage(collection: userPlaylistsIndex[meUser.urn] ?? [], limit: limit)
    }

    public func myLikedTracks(limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack> {
        makePage(collection: tracks, limit: limit)
    }

    public func myLikedPlaylists(limit: Int, nextHref: URL?) async throws -> SCPage<SCPlaylist> {
        makePage(collection: playlists, limit: limit)
    }

    public func playlist(urn: String, showTracks: Bool) async throws -> SCPlaylist {
        guard let playlist = playlistsByURN[urn] else {
            throw CloudScrobbleError.invalidConfiguration("Mock playlist not found for urn: \(urn)")
        }
        return playlist
    }

    public func playlistTracks(urn: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack> {
        guard let playlist = playlistsByURN[urn] else {
            throw CloudScrobbleError.invalidConfiguration("Mock playlist not found for urn: \(urn)")
        }

        let collection = (playlist.tracks ?? []).compactMap { tracksByURN[$0.urn] }
        return makePage(collection: collection, limit: limit)
    }

    public func track(urn: String) async throws -> SCTrack {
        guard let track = tracksByURN[urn] else {
            throw CloudScrobbleError.invalidConfiguration("Mock track not found for urn: \(urn)")
        }
        return track
    }

    public func streams(trackURN: String) async throws -> SCStreams {
        guard tracksByURN[trackURN] != nil else {
            throw CloudScrobbleError.invalidConfiguration("Mock track not found for urn: \(trackURN)")
        }
        return SCStreams(hlsAac160URL: Self.demoStreamURL, hlsAac96URL: nil)
    }

    public func legacyStreamURL(trackURN: String) async throws -> URL {
        guard tracksByURN[trackURN] != nil else {
            throw CloudScrobbleError.invalidConfiguration("Mock track not found for urn: \(trackURN)")
        }
        return Self.demoStreamURL
    }

    private func filterTracks(query: String) -> [SCTrack] {
        let normalized = query.lowercased()
        return tracks.filter {
            $0.title.lowercased().contains(normalized)
                || $0.user.username.lowercased().contains(normalized)
                || ($0.publisherMetadata?.artist?.lowercased().contains(normalized) ?? false)
        }
    }

    private func makePage<T: Decodable & Sendable>(collection: [T], limit: Int) -> SCPage<T> {
        let sliced = limit > 0 ? Array(collection.prefix(limit)) : collection
        return SCPage(collection: sliced, nextHref: nil)
    }

    private static func makeTrack(id: String, title: String, artist: String, user: SCUser) -> SCTrack {
        SCTrack(
            urn: "soundcloud:tracks:demo:\(id)",
            title: title,
            durationMs: 242_000,
            artworkURL: URL(string: "https://picsum.photos/seed/\(id)/640"),
            permalinkURL: URL(string: "https://soundcloud.com/\(user.permalink ?? "demo")/\(id)"),
            user: user,
            publisherMetadata: SCPublisherMetadata(artist: artist, releaseTitle: title),
            access: "playable"
        )
    }

    private static func makePlaylist(id: String, title: String, user: SCUser, tracks: [SCTrack]) -> SCPlaylist {
        SCPlaylist(
            urn: "soundcloud:playlists:demo:\(id)",
            title: title,
            artworkURL: URL(string: "https://picsum.photos/seed/\(id)-playlist/640"),
            user: user,
            tracks: tracks.map {
                SCPlaylistTrackItem(urn: $0.urn, title: $0.title, user: $0.user)
            }
        )
    }
}
