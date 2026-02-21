import XCTest
@testable import CloudScrobbleCore

final class SoundCloudAuthServiceTests: XCTestCase {
    func testAuthorizationURLUsesPKCEAndStateWithoutPopupDisplay() async throws {
        let service = SoundCloudAuthService(
            config: SoundCloudAuthConfiguration(
                clientID: "client123",
                tokenBrokerBaseURL: URL(string: "http://localhost:8787")!
            ),
            keychain: KeychainStore(service: "CloudScrobbleCoreTests.SoundCloudAuthServiceTests")
        )

        let url = try await service.makeAuthorizationURL(
            codeChallenge: "challenge",
            state: "state123",
            redirectURI: "cloudscrobble://oauth"
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "secure.soundcloud.com")
        XCTAssertEqual(components.path, "/authorize")
        XCTAssertEqual(items["client_id"], "client123")
        XCTAssertEqual(items["redirect_uri"], "cloudscrobble://oauth")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["code_challenge"], "challenge")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "state123")
        XCTAssertFalse(items.keys.contains("display"))
    }
}
