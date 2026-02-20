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
}
