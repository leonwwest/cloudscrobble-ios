import XCTest

final class CloudScrobbleiOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSetupChoicesAndDiagnosticsEntryAreReachable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-cloudscrobble-show-onboarding"]
        app.launch()

        XCTAssertTrue(app.staticTexts["onboarding-title"].waitForExistence(timeout: 8))
        let fullLoginButton = app.buttons["connection-full-soundcloud-login"]
        if !fullLoginButton.waitForExistence(timeout: 3) {
            let disconnectButton = app.buttons["disconnect-soundcloud-button"]
            XCTAssertTrue(disconnectButton.waitForExistence(timeout: 3))
            disconnectButton.tap()
        }

        XCTAssertTrue(fullLoginButton.waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["connection-public-test-mode"].exists)
        XCTAssertTrue(app.buttons["connection-demo-preview"].exists)
        XCTAssertTrue(app.buttons["connection-lastfm-scrobbling"].exists)

        app.buttons["onboarding-get-started-button"].tap()

        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 4))
        settingsButton.tap()

        XCTAssertTrue(app.buttons["open-diagnostics-button"].waitForExistence(timeout: 4))
        app.buttons["open-diagnostics-button"].tap()

        XCTAssertTrue(app.staticTexts["diagnostics-lastfm-status-title"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["diagnostics-scrobble-history-title"].exists)
    }
}
