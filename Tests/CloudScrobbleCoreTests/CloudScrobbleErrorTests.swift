import XCTest
@testable import CloudScrobbleCore

final class CloudScrobbleErrorTests: XCTestCase {
    func testHTTPStatusDescriptionIncludesUpstreamErrorField() {
        let data = #"{"error":"invalid_client"}"#.data(using: .utf8)
        let error = CloudScrobbleError.httpStatus(401, data)

        XCTAssertEqual(error.errorDescription, "SoundCloud session expired. Reconnect SoundCloud if this keeps happening.")
    }

    func testHTTPStatusDescriptionIncludesUpstreamMessageField() {
        let data = #"{"message":"token expired"}"#.data(using: .utf8)
        let error = CloudScrobbleError.httpStatus(401, data)

        XCTAssertEqual(error.errorDescription, "SoundCloud session expired. Reconnect SoundCloud if this keeps happening.")
    }

    func testHTTPStatusDescriptionFallsBackWithoutPayload() {
        let error = CloudScrobbleError.httpStatus(500, nil)

        XCTAssertEqual(error.errorDescription, "Request failed with HTTP 500.")
    }

    func testLastFMAuthErrorIsActionable() {
        let error = CloudScrobbleError.lastFMError(code: 4, message: "Authentication Failed")

        XCTAssertEqual(error.errorDescription, "Last.fm login failed: username or password is wrong.")
    }

    func testLastFMRateLimitErrorIsActionable() {
        let error = CloudScrobbleError.lastFMError(code: 29, message: "Rate Limit Exceeded")

        XCTAssertEqual(error.errorDescription, "Last.fm rate limit reached. Scrobbles stay queued.")
    }
}
