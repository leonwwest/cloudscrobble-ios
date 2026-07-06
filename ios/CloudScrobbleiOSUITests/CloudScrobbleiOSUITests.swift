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

        // Resolve expected strings through the bundle so the test is
        // language-agnostic (English source key, German translation in catalog).
        let onboardingTitle = Bundle.main.localizedString(forKey: "Set up CloudScrobble", value: nil, table: nil)
        let getStartedLabel = Bundle.main.localizedString(forKey: "Get started", value: nil, table: nil)

        XCTAssertTrue(app.staticTexts[onboardingTitle].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Full SoundCloud Login"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Public Test Mode"].exists)
        XCTAssertTrue(app.buttons["Demo Preview"].exists)
        XCTAssertTrue(app.buttons["Last.fm Scrobbling"].exists)

        app.buttons[getStartedLabel].tap()

        let settingsButton = app.buttons["Open settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 4))
        settingsButton.tap()

        XCTAssertTrue(app.buttons["Open diagnostics"].waitForExistence(timeout: 4))
        app.buttons["Open diagnostics"].tap()

        XCTAssertTrue(app.staticTexts["Last.fm Status"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Scrobble History"].exists)
    }
}
