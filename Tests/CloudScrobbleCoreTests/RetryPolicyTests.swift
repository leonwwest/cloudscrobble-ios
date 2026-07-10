import XCTest
@testable import CloudScrobbleCore

final class RetryPolicyTests: XCTestCase {
    func testRetriesFor429And5xx() {
        let policy = RetryPolicy(maxAttempts: 3)
        XCTAssertTrue(policy.shouldRetry(statusCode: 429))
        XCTAssertTrue(policy.shouldRetry(statusCode: 500))
        XCTAssertFalse(policy.shouldRetry(statusCode: 404))
    }

    func testBackoffIsPositive() {
        let policy = RetryPolicy(maxAttempts: 3)
        XCTAssertGreaterThan(policy.backoffDelay(attempt: 1), 0)
        XCTAssertGreaterThan(policy.backoffDelay(attempt: 2), 0)
    }

    func testOnlyRetriesIdempotentRequestsByDefault() {
        let policy = RetryPolicy()
        var get = URLRequest(url: URL(string: "https://example.com")!)
        get.httpMethod = "GET"
        var post = get
        post.httpMethod = "POST"

        XCTAssertTrue(policy.shouldRetry(request: get))
        XCTAssertFalse(policy.shouldRetry(request: post))

        post.setValue("scrobble-123", forHTTPHeaderField: "Idempotency-Key")
        XCTAssertTrue(policy.shouldRetry(request: post))
    }

    func testParsesRetryAfterSecondsAndHTTPDate() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(RetryPolicy.retryAfterDelay("12", now: now), 12)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        let header = formatter.string(from: now.addingTimeInterval(20))
        XCTAssertEqual(try XCTUnwrap(RetryPolicy.retryAfterDelay(header, now: now)), 20, accuracy: 0.001)
    }

    func testRecognizesTransientTransportErrors() {
        let policy = RetryPolicy()
        XCTAssertTrue(policy.shouldRetry(transportError: URLError(.timedOut)))
        XCTAssertTrue(policy.shouldRetry(transportError: URLError(.networkConnectionLost)))
        XCTAssertFalse(policy.shouldRetry(transportError: URLError(.badURL)))
        XCTAssertFalse(policy.shouldRetry(transportError: CocoaError(.fileNoSuchFile)))
    }
}
