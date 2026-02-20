import XCTest
@testable import CloudScrobbleCore

final class LastFMSignatureTests: XCTestCase {
    func testSignatureIsStableForSameParameters() {
        let params = [
            "method": "track.scrobble",
            "artist": "Artist",
            "track": "Track",
            "api_key": "abc",
            "sk": "session"
        ]

        let a = LastFMSignature.sign(parameters: params, apiSecret: "secret")
        let b = LastFMSignature.sign(parameters: params, apiSecret: "secret")

        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 32)
    }
}
