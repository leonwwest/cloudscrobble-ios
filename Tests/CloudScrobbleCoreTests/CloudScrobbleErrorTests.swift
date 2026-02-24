import XCTest
@testable import CloudScrobbleCore

final class CloudScrobbleErrorTests: XCTestCase {
    func testHTTPStatusDescriptionIncludesUpstreamErrorField() {
        let data = #"{"error":"invalid_client"}"#.data(using: .utf8)
        let error = CloudScrobbleError.httpStatus(401, data)

        XCTAssertEqual(error.errorDescription, "Request failed with HTTP 401: invalid_client")
    }

    func testHTTPStatusDescriptionIncludesUpstreamMessageField() {
        let data = #"{"message":"token expired"}"#.data(using: .utf8)
        let error = CloudScrobbleError.httpStatus(401, data)

        XCTAssertEqual(error.errorDescription, "Request failed with HTTP 401: token expired")
    }

    func testHTTPStatusDescriptionFallsBackWithoutPayload() {
        let error = CloudScrobbleError.httpStatus(500, nil)

        XCTAssertEqual(error.errorDescription, "Request failed with HTTP 500.")
    }
}
