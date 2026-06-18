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

        XCTAssertTrue(app.staticTexts["CloudScrobble einrichten"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Full SoundCloud Login"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Public Test Mode"].exists)
        XCTAssertTrue(app.buttons["Demo Preview"].exists)
        XCTAssertTrue(app.buttons["Last.fm Scrobbling"].exists)

        app.buttons["Loslegen"].tap()

        let settingsButton = app.buttons["Open settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 4))
        settingsButton.tap()

        XCTAssertTrue(app.buttons["Open diagnostics"].waitForExistence(timeout: 4))
        app.buttons["Open diagnostics"].tap()

        XCTAssertTrue(app.staticTexts["Last.fm Status"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Scrobble History"].exists)
    }
}
