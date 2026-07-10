import Foundation

public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let maxRetryAfterDelay: TimeInterval

    public init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 0.4,
        maxDelay: TimeInterval = 4.0,
        maxRetryAfterDelay: TimeInterval = 30.0
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(0, maxDelay)
        self.maxRetryAfterDelay = max(0, maxRetryAfterDelay)
    }

    public static let `default` = RetryPolicy()

    public func backoffDelay(attempt: Int) -> TimeInterval {
        let exp = min(maxDelay, baseDelay * pow(2, Double(max(0, attempt - 1))))
        let jitter = Double.random(in: 0...(exp * 0.25))
        return exp + jitter
    }

    public func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 429 || (500...599).contains(statusCode)
    }

    /// Automatic retries are safe for idempotent methods. A caller can opt an
    /// otherwise non-idempotent request in by supplying an idempotency key that
    /// the server uses to deduplicate repeated submissions.
    public func shouldRetry(request: URLRequest) -> Bool {
        let method = (request.httpMethod ?? "GET").uppercased()
        if ["GET", "HEAD", "PUT", "DELETE", "OPTIONS", "TRACE"].contains(method) {
            return true
        }

        guard let idempotencyKey = request.value(forHTTPHeaderField: "Idempotency-Key") else {
            return false
        }
        return !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func shouldRetry(transportError: Error) -> Bool {
        guard let error = transportError as? URLError else {
            return false
        }

        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .networkConnectionLost,
            .notConnectedToInternet,
            .resourceUnavailable
        ].contains(error.code)
    }

    public func retryDelay(for response: HTTPURLResponse, attempt: Int, now: Date = Date()) -> TimeInterval {
        guard let rawRetryAfter = response.value(forHTTPHeaderField: "Retry-After"),
              let serverDelay = Self.retryAfterDelay(rawRetryAfter, now: now) else {
            return backoffDelay(attempt: attempt)
        }

        return min(maxRetryAfterDelay, max(0, serverDelay))
    }

    public static func retryAfterDelay(_ rawValue: String, now: Date = Date()) -> TimeInterval? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        guard let date = formatter.date(from: value) else {
            return nil
        }
        return max(0, date.timeIntervalSince(now))
    }
}

public struct HTTPResponse: Sendable {
    public let data: Data
    public let response: HTTPURLResponse
}

public final class HTTPClient: @unchecked Sendable {
    private let session: URLSession
    private let requestTimeout: TimeInterval

    public init(session: URLSession = .shared, requestTimeout: TimeInterval = 20) {
        self.session = session
        self.requestTimeout = max(1, requestTimeout)
    }

    public func send(_ request: URLRequest, retryPolicy: RetryPolicy = .default) async throws -> HTTPResponse {
        var request = request
        if request.timeoutInterval <= 0 || request.timeoutInterval > requestTimeout {
            request.timeoutInterval = requestTimeout
        }

        var attempt = 1

        while true {
            let data: Data
            let urlResponse: URLResponse
            do {
                (data, urlResponse) = try await session.data(for: request)
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }

                if attempt < retryPolicy.maxAttempts,
                   retryPolicy.shouldRetry(request: request),
                   retryPolicy.shouldRetry(transportError: error) {
                    try await sleep(for: retryPolicy.backoffDelay(attempt: attempt))
                    attempt += 1
                    continue
                }
                throw error
            }

            guard let response = urlResponse as? HTTPURLResponse else {
                throw CloudScrobbleError.invalidResponse
            }

            if (200..<300).contains(response.statusCode) {
                return HTTPResponse(data: data, response: response)
            }

            if attempt < retryPolicy.maxAttempts,
               retryPolicy.shouldRetry(request: request),
               retryPolicy.shouldRetry(statusCode: response.statusCode) {
                let delay = retryPolicy.retryDelay(for: response, attempt: attempt)
                try await sleep(for: delay)
                attempt += 1
                continue
            }

            throw CloudScrobbleError.httpStatus(response.statusCode, data)
        }
    }

    private func sleep(for delay: TimeInterval) async throws {
        guard delay > 0 else { return }
        let nanoseconds = UInt64(min(delay, 86_400) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
