import Foundation

public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval

    public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 0.4, maxDelay: TimeInterval = 4.0) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
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
}

public struct HTTPResponse: Sendable {
    public let data: Data
    public let response: HTTPURLResponse
}

public final class HTTPClient: @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest, retryPolicy: RetryPolicy = .default) async throws -> HTTPResponse {
        var attempt = 1

        while true {
            let (data, urlResponse) = try await session.data(for: request)
            guard let response = urlResponse as? HTTPURLResponse else {
                throw CloudScrobbleError.invalidResponse
            }

            if (200..<300).contains(response.statusCode) {
                return HTTPResponse(data: data, response: response)
            }

            if attempt < retryPolicy.maxAttempts, retryPolicy.shouldRetry(statusCode: response.statusCode) {
                let delay = retryPolicy.backoffDelay(attempt: attempt)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
                continue
            }

            throw CloudScrobbleError.httpStatus(response.statusCode, data)
        }
    }
}
