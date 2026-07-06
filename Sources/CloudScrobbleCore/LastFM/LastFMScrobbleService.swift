import Foundation

public actor LastFMScrobbleService: LastFMScrobbleSending {
    private let config: LastFMConfiguration
    private let authService: LastFMAuthenticating
    private let httpClient: HTTPClient
    private let queueStore: ScrobbleQueueStoreing
    private let maxQueueSize: Int

    private var inMemoryQueue: [PendingScrobble]?

    public init(
        config: LastFMConfiguration,
        authService: LastFMAuthenticating,
        queueStore: ScrobbleQueueStoreing,
        httpClient: HTTPClient = HTTPClient(),
        maxQueueSize: Int = 1_000
    ) {
        self.config = config
        self.authService = authService
        self.queueStore = queueStore
        self.httpClient = httpClient
        self.maxQueueSize = maxQueueSize
    }

    public func updateNowPlaying(meta: LastFMTrackMeta, durationSeconds: Int?) async throws {
        let session = try await activeSession()

        var params = [
            "method": "track.updateNowPlaying",
            "artist": meta.artist,
            "track": meta.track,
            "api_key": config.apiKey,
            "sk": session.key
        ]

        if let durationSeconds {
            params["duration"] = String(durationSeconds)
        }

        params["api_sig"] = LastFMSignature.sign(parameters: params, apiSecret: config.apiSecret)
        try await performScrobbleCall(params: params)

        // Opportunistically flush queued scrobbles once network is available.
        try? await flushPendingScrobbles()
    }

    public func scrobble(meta: LastFMTrackMeta, timestamp: Int) async throws {
        var queue = try loadPendingQueue()
        queue = Self.mergedPendingQueue(
            existing: queue,
            adding: PendingScrobble(meta: meta, timestamp: timestamp),
            maxCount: maxQueueSize
        )
        try persistPendingQueue(queue)

        do {
            try await flushPendingScrobbles()
        } catch CloudScrobbleError.lastFMError(let code, let message) where code == 9 {
            // Invalid session must be surfaced to force re-auth.
            throw CloudScrobbleError.lastFMError(code: code, message: message)
        } catch {
            // Keep queue persisted; offline/network errors are retried later.
        }
    }

    public func flushPendingScrobbles() async throws {
        var queue = try loadPendingQueue()
        guard !queue.isEmpty else { return }

        let session = try await activeSession()

        while !queue.isEmpty {
            let batch = Array(queue.prefix(50))
            let params = Self.makeBatchScrobbleParameters(
                batch: batch,
                sessionKey: session.key,
                apiKey: config.apiKey,
                apiSecret: config.apiSecret
            )

            try await performScrobbleCall(params: params)
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

    private func performScrobbleCall(params: [String: String]) async throws {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var payload = params
        payload["format"] = "json"

        request.httpBody = Data(
            payload.sorted { $0.key < $1.key }
                .map { key, value in "\(key)=\(Self.formURLEncode(value))" }
                .joined(separator: "&")
                .utf8
        )

        do {
            let response = try await httpClient.send(request)
            if let apiError = try? JSONDecoder().decode(LastFMErrorResponse.self, from: response.data) {
                throw CloudScrobbleError.lastFMError(code: apiError.error, message: apiError.message)
            }
        } catch CloudScrobbleError.httpStatus(_, let data) {
            guard let data else { throw CloudScrobbleError.invalidResponse }
            if let apiError = try? JSONDecoder().decode(LastFMErrorResponse.self, from: data) {
                throw CloudScrobbleError.lastFMError(code: apiError.error, message: apiError.message)
            }
            throw CloudScrobbleError.invalidResponse
        }
    }

    private func loadPendingQueue() throws -> [PendingScrobble] {
        if let inMemoryQueue {
            return inMemoryQueue
        }

        let decoded = try queueStore.load()
        inMemoryQueue = decoded
        return decoded
    }

    private func persistPendingQueue(_ queue: [PendingScrobble]) throws {
        inMemoryQueue = queue

        if queue.isEmpty {
            try queueStore.clear()
            return
        }

        try queueStore.save(queue)
    }

    static func makeBatchScrobbleParameters(
        batch: [PendingScrobble],
        sessionKey: String,
        apiKey: String,
        apiSecret: String
    ) -> [String: String] {
        var params: [String: String] = [
            "method": "track.scrobble",
            "api_key": apiKey,
            "sk": sessionKey
        ]

        for (index, item) in batch.enumerated() {
            params["artist[\(index)]"] = item.meta.artist
            params["track[\(index)]"] = item.meta.track
            params["timestamp[\(index)]"] = String(item.timestamp)
        }

        params["api_sig"] = LastFMSignature.sign(parameters: params, apiSecret: apiSecret)
        return params
    }

    static func mergedPendingQueue(existing: [PendingScrobble], adding: PendingScrobble, maxCount: Int) -> [PendingScrobble] {
        var merged = existing

        let isDuplicate = merged.contains {
            $0.timestamp == adding.timestamp && $0.meta == adding.meta
        }

        if !isDuplicate {
            merged.append(adding)
        }

        if merged.count > maxCount {
            merged.removeFirst(merged.count - maxCount)
        }

        return merged
    }

    private static func formURLEncode(_ input: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return input.addingPercentEncoding(withAllowedCharacters: allowed) ?? input
    }
}

private struct LastFMErrorResponse: Decodable {
    let error: Int
    let message: String
}
