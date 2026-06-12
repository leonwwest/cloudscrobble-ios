import Foundation

public protocol AccessTokenProviding: Sendable {
    func validAccessToken() async throws -> String
}

public protocol SoundCloudAuthProviding: Sendable {
    func makeAuthorizationURL(codeChallenge: String, state: String, redirectURI: String) async throws -> URL
    func exchangeAuthorizationCode(_ code: String, codeVerifier: String, redirectURI: String) async throws -> SoundCloudToken
    func refreshToken(_ refreshToken: String) async throws -> SoundCloudToken
    func fetchClientCredentialsToken() async throws -> SoundCloudToken
    func cachedToken() async -> SoundCloudToken?
    func setCachedToken(_ token: SoundCloudToken) async throws
    func clearCachedToken() async throws
}

public protocol SoundCloudAPIClienting: Sendable {
    func me() async throws -> SCUser
    func searchTracks(query: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack>
    func searchPlaylists(query: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCPlaylist>
    func searchUsers(query: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCUser>
    func user(urn: String) async throws -> SCUser
    func userTracks(urn: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack>
    func userPlaylists(urn: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCPlaylist>
    func userLikesTracks(urn: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack>
    func userLikesPlaylists(urn: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCPlaylist>
    func myPlaylists(limit: Int, nextHref: URL?) async throws -> SCPage<SCPlaylist>
    func myLikedTracks(limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack>
    func myLikedPlaylists(limit: Int, nextHref: URL?) async throws -> SCPage<SCPlaylist>
    func playlist(urn: String, showTracks: Bool) async throws -> SCPlaylist
    func playlistTracks(urn: String, limit: Int, nextHref: URL?) async throws -> SCPage<SCTrack>
    func track(urn: String) async throws -> SCTrack
    func streams(trackURN: String) async throws -> SCStreams
    func streamRequestHeaders() async throws -> [String: String]
    func legacyStreamURL(trackURN: String) async throws -> URL
}

public protocol PlaybackResolving: Sendable {
    func resolvePlayableStream(for trackURN: String) async throws -> ResolvedPlaybackStream
}

public protocol LastFMAuthenticating: Sendable {
    func authenticate(username: String, password: String) async throws -> LastFMSession
    func cachedSession() async -> LastFMSession?
    func setCachedSession(_ session: LastFMSession) async throws
    func clearSession() async throws
}

public protocol LastFMScrobbleSending: Sendable {
    func updateNowPlaying(meta: LastFMTrackMeta, durationSeconds: Int?) async throws
    func scrobble(meta: LastFMTrackMeta, timestamp: Int) async throws
    func flushPendingScrobbles() async throws
    func pendingScrobbleCount() async -> Int
}
