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
        attachScreenshot(named: "01-onboarding", from: app)

        app.buttons["connection-demo-preview"].tap()
        XCTAssertTrue(app.buttons["disconnect-soundcloud-button"].waitForExistence(timeout: 4))

        app.buttons["onboarding-get-started-button"].tap()

        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 4))
        attachScreenshot(named: "02-demo-home", from: app)
        settingsButton.tap()

        XCTAssertTrue(app.buttons["open-diagnostics-button"].waitForExistence(timeout: 4))
        app.buttons["open-diagnostics-button"].tap()

        XCTAssertTrue(app.staticTexts["diagnostics-lastfm-status-title"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["diagnostics-scrobble-history-title"].exists)
        attachScreenshot(named: "03-diagnostics", from: app)
    }

    private func attachScreenshot(named name: String, from app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
