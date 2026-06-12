import Foundation

public actor LastFMProxyAuthService: LastFMAuthenticating {
    private enum Storage {
        static let sessionAccount = "lastfm.session"
    }

    private let baseURL: URL
    private let keychain: KeychainStore
    private let httpClient: HTTPClient
    private var inMemorySession: LastFMSession?

    public init(baseURL: URL, keychain: KeychainStore, httpClient: HTTPClient = HTTPClient()) {
        self.baseURL = baseURL
        self.keychain = keychain
        self.httpClient = httpClient
    }

    public func authenticate(username: String, password: String) async throws -> LastFMSession {
        let endpoint = baseURL.appending(path: "oauth/lastfm/mobile-session")
        let response: LastFMSessionResponse = try await postJSON(
            to: endpoint,
            body: LastFMProxyAuthRequest(username: username, password: password)
        )
        try await setCachedSession(response.session)
        return response.session
    }

    public func cachedSession() async -> LastFMSession? {
        if let inMemorySession {
            return inMemorySession
        }

        guard let data = try? keychain.load(account: Storage.sessionAccount),
              let session = try? JSONDecoder().decode(LastFMSession.self, from: data) else {
            return nil
        }

        inMemorySession = session
        return session
    }

    public func setCachedSession(_ session: LastFMSession) async throws {
        inMemorySession = session
        let data = try JSONEncoder().encode(session)
        try keychain.save(data: data, account: Storage.sessionAccount)
    }

    public func clearSession() async throws {
        inMemorySession = nil
        keychain.delete(account: Storage.sessionAccount)
    }

    private func postJSON<RequestBody: Encodable, ResponseBody: Decodable>(
        to url: URL,
        body: RequestBody
    ) async throws -> ResponseBody {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        do {
            data = try await httpClient.send(request).data
        } catch CloudScrobbleError.httpStatus(_, let payload) {
            guard let payload else { throw CloudScrobbleError.invalidResponse }
            data = payload
        }

        if let apiError = try? JSONDecoder().decode(LastFMErrorResponse.self, from: data) {
            throw CloudScrobbleError.lastFMError(code: apiError.error, message: apiError.message)
        }

        return try JSONDecoder().decode(ResponseBody.self, from: data)
    }
}

public actor LastFMProxyScrobbleService: LastFMScrobbleSending {
    private enum Storage {
        static let pendingQueueAccount = "lastfm.pending.scrobbles"
    }

    private let baseURL: URL
    private let authService: LastFMAuthenticating
    private let keychain: KeychainStore
    private let httpClient: HTTPClient
    private let maxQueueSize: Int

    private var inMemoryQueue: [PendingScrobble]?

    public init(
        baseURL: URL,
        authService: LastFMAuthenticating,
        keychain: KeychainStore,
        httpClient: HTTPClient = HTTPClient(),
        maxQueueSize: Int = 1_000
    ) {
        self.baseURL = baseURL
        self.authService = authService
        self.keychain = keychain
        self.httpClient = httpClient
        self.maxQueueSize = maxQueueSize
    }

    public func updateNowPlaying(meta: LastFMTrackMeta, durationSeconds: Int?) async throws {
        let session = try await activeSession()
        let endpoint = baseURL.appending(path: "lastfm/now-playing")
        try await postJSONNoContent(
            to: endpoint,
            body: LastFMNowPlayingProxyRequest(
                sessionKey: session.key,
                artist: meta.artist,
                track: meta.track,
                durationSeconds: durationSeconds
            )
        )

        try? await flushPendingScrobbles()
    }

    public func scrobble(meta: LastFMTrackMeta, timestamp: Int) async throws {
        var queue = try loadPendingQueue()
        queue = LastFMScrobbleService.mergedPendingQueue(
            existing: queue,
            adding: PendingScrobble(meta: meta, timestamp: timestamp),
            maxCount: maxQueueSize
        )
        try persistPendingQueue(queue)

        do {
            try await flushPendingScrobbles()
        } catch CloudScrobbleError.lastFMError(let code, let message) where code == 9 {
            throw CloudScrobbleError.lastFMError(code: code, message: message)
        } catch {
            // Keep queued scrobbles for retry when network or API recovers.
        }
    }

    public func flushPendingScrobbles() async throws {
        var queue = try loadPendingQueue()
        guard !queue.isEmpty else { return }

        let session = try await activeSession()
        let endpoint = baseURL.appending(path: "lastfm/scrobble")

        while !queue.isEmpty {
            let batch = Array(queue.prefix(50))
            try await postJSONNoContent(
                to: endpoint,
                body: LastFMScrobbleProxyRequest(
                    sessionKey: session.key,
                    scrobbles: batch.map {
                        LastFMScrobbleProxyItem(
                            artist: $0.meta.artist,
                            track: $0.meta.track,
                            timestamp: $0.timestamp
                        )
                    }
                )
            )
            queue.removeFirst(batch.count)
            try persistPendingQueue(queue)
        }
    }

    public func pendingScrobbleCount() async -> Int {
        (try? loadPendingQueue().count) ?? 0
    }

    private func activeSession() async throws -> LastFMSession {
        guard let session = await authService.cachedSession() else {
            throw CloudScrobbleError.lastFMError(code: 9, message: "Missing or invalid Last.fm session")
        }
        return session
    }

    private func postJSONNoContent<RequestBody: Encodable>(
        to url: URL,
        body: RequestBody
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        do {
            data = try await httpClient.send(request).data
        } catch CloudScrobbleError.httpStatus(_, let payload) {
            guard let payload else { throw CloudScrobbleError.invalidResponse }
            data = payload
        }

        if let apiError = try? JSONDecoder().decode(LastFMErrorResponse.self, from: data) {
            throw CloudScrobbleError.lastFMError(code: apiError.error, message: apiError.message)
        }
    }

    private func loadPendingQueue() throws -> [PendingScrobble] {
        if let inMemoryQueue {
            return inMemoryQueue
        }

        guard let data = try keychain.load(account: Storage.pendingQueueAccount) else {
            inMemoryQueue = []
            return []
        }

        let decoded = (try? JSONDecoder().decode([PendingScrobble].self, from: data)) ?? []
        inMemoryQueue = decoded
        return decoded
    }

    private func persistPendingQueue(_ queue: [PendingScrobble]) throws {
        inMemoryQueue = queue

        if queue.isEmpty {
            keychain.delete(account: Storage.pendingQueueAccount)
            return
        }

        let data = try JSONEncoder().encode(queue)
        try keychain.save(data: data, account: Storage.pendingQueueAccount)
    }
}

private struct LastFMSessionResponse: Decodable {
    let session: LastFMSession
}

private struct LastFMErrorResponse: Decodable {
    let error: Int
    let message: String
}

private struct LastFMProxyAuthRequest: Encodable {
    let username: String
    let password: String
}

private struct LastFMNowPlayingProxyRequest: Encodable {
    let sessionKey: String
    let artist: String
    let track: String
    let durationSeconds: Int?
}

private struct LastFMScrobbleProxyRequest: Encodable {
    let sessionKey: String
    let scrobbles: [LastFMScrobbleProxyItem]
}

private struct LastFMScrobbleProxyItem: Encodable {
    let artist: String
    let track: String
    let timestamp: Int
}
