import Foundation

public struct SoundCloudAPIConfiguration: Sendable {
    public let baseURL: URL
    public let authScheme: String

    public init(baseURL: URL = URL(string: "https://api.soundcloud.com")!, authScheme: String = "OAuth") {
        self.baseURL = baseURL
        self.authScheme = authScheme
    }
}

public actor SoundCloudAPIClient: SoundCloudAPIClienting {
    private let config: SoundCloudAPIConfiguration
    private let tokenProvider: AccessTokenProviding
    private let httpClient: HTTPClient

    public init(
        config: SoundCloudAPIConfiguration = SoundCloudAPIConfiguration(),
        tokenProvider: AccessTokenProviding,
        httpClient: HTTPClient = HTTPClient()
    ) {
        self.config = config
        self.tokenProvider = tokenProvider
        self.httpClient = httpClient
    }

    public func me() async throws -> SCUser {
        try await get(path: "/me")
    }

    public func searchTracks(query: String, limit: Int = 50, nextHref: URL? = nil) async throws -> SCPage<SCTrack> {
        try await paged(path: "/tracks", queryItems: [
            .init(name: "q", value: query),
            .init(name: "limit", value: String(limit)),
            .init(name: "linked_partitioning", value: "true")
        ], nextHref: nextHref)
    }

    public func searchPlaylists(query: String, limit: Int = 50, nextHref: URL? = nil) async throws -> SCPage<SCPlaylist> {
        try await paged(path: "/playlists", queryItems: [
            .init(name: "q", value: query),
            .init(name: "limit", value: String(limit)),
            .init(name: "linked_partitioning", value: "true")
        ], nextHref: nextHref)
    }

    public func searchUsers(query: String, limit: Int = 50, nextHref: URL? = nil) async throws -> SCPage<SCUser> {
        try await paged(path: "/users", queryItems: [
            .init(name: "q", value: query),
            .init(name: "limit", value: String(limit)),
            .init(name: "linked_partitioning", value: "true")
        ], nextHref: nextHref)
    }

    public func user(urn: String) async throws -> SCUser {
        try await get(path: "/users/\(urn)")
    }

    public func userTracks(urn: String, limit: Int = 50, nextHref: URL? = nil) async throws -> SCPage<SCTrack> {
        try await paged(path: "/users/\(urn)/tracks", queryItems: basePageQuery(limit: limit), nextHref: nextHref)
    }

    public func userPlaylists(urn: String, limit: Int = 50, nextHref: URL? = nil) async throws -> SCPage<SCPlaylist> {
        try await paged(path: "/users/\(urn)/playlists", queryItems: basePageQuery(limit: limit), nextHref: nextHref)
    }

    public func userLikesTracks(urn: String, limit: Int = 50, nextHref: URL? = nil) async throws -> SCPage<SCTrack> {
        try await paged(path: "/users/\(urn)/likes/tracks", queryItems: basePageQuery(limit: limit), nextHref: nextHref)
    }

    public func userLikesPlaylists(urn: String, limit: Int = 50, nextHref: URL? = nil) async throws -> SCPage<SCPlaylist> {
        try await paged(path: "/users/\(urn)/likes/playlists", queryItems: basePageQuery(limit: limit), nextHref: nextHref)
    }

    public func myPlaylists(limit: Int = 50, nextHref: URL? = nil) async throws -> SCPage<SCPlaylist> {
        try await paged(path: "/me/playlists", queryItems: basePageQuery(limit: limit), nextHref: nextHref)
    }

    public func myLikedTracks(limit: Int = 50, nextHref: URL? = nil) async throws -> SCPage<SCTrack> {
        try await paged(path: "/me/likes/tracks", queryItems: basePageQuery(limit: limit), nextHref: nextHref)
    }

    public func myLikedPlaylists(limit: Int = 50, nextHref: URL? = nil) async throws -> SCPage<SCPlaylist> {
        try await paged(path: "/me/likes/playlists", queryItems: basePageQuery(limit: limit), nextHref: nextHref)
    }

    public func playlist(urn: String, showTracks: Bool = true) async throws -> SCPlaylist {
        var queryItems: [URLQueryItem] = []
        if showTracks {
            queryItems.append(.init(name: "show_tracks", value: "true"))
        }
        return try await get(path: "/playlists/\(urn)", queryItems: queryItems)
    }

    public func playlistTracks(urn: String, limit: Int = 50, nextHref: URL? = nil) async throws -> SCPage<SCTrack> {
        try await paged(path: "/playlists/\(urn)/tracks", queryItems: basePageQuery(limit: limit), nextHref: nextHref)
    }

    public func track(urn: String) async throws -> SCTrack {
        try await get(path: "/tracks/\(urn)")
    }

    public func streams(trackURN: String) async throws -> SCStreams {
        try await get(path: "/tracks/\(trackURN)/streams")
    }

    public func legacyStreamURL(trackURN: String) async throws -> URL {
        var request = try await makeRequest(path: "/tracks/\(trackURN)/stream")
        request.httpMethod = "GET"
        let response = try await httpClient.send(request)
        if let finalURL = response.response.url {
            return finalURL
        }
        throw CloudScrobbleError.unsupportedStream
    }

    private func paged<T: Decodable & Sendable>(
        path: String,
        queryItems: [URLQueryItem],
        nextHref: URL?
    ) async throws -> SCPage<T> {
        if let nextHref {
            return try await getAbsolute(url: nextHref)
        }
        return try await get(path: path, queryItems: queryItems)
    }

    private func get<T: Decodable & Sendable>(path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        let request = try await makeRequest(path: path, queryItems: queryItems)
        let response = try await httpClient.send(request)
        return try decode(response.data)
    }

    private func getAbsolute<T: Decodable & Sendable>(url: URL) async throws -> T {
        let request = try await makeRequest(url: url)
        let response = try await httpClient.send(request)
        return try decode(response.data)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CloudScrobbleError.invalidResponse
        }
    }

    private func makeRequest(path: String, queryItems: [URLQueryItem] = []) async throws -> URLRequest {
        guard var components = URLComponents(url: config.baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw CloudScrobbleError.invalidConfiguration("Invalid base URL")
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw CloudScrobbleError.invalidConfiguration("Invalid request URL")
        }
        return try await makeRequest(url: url)
    }

    private func makeRequest(url: URL) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let token = try await tokenProvider.validAccessToken()
        request.setValue("\(config.authScheme) \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func basePageQuery(limit: Int) -> [URLQueryItem] {
        [
            .init(name: "limit", value: String(limit)),
            .init(name: "linked_partitioning", value: "true")
        ]
    }
}
