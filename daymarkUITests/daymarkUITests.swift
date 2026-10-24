import XCTest

final class daymarkUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testExample() throws {
        let app = XCUIApplication()
        app.launch()
    }

    @MainActor
    func testExistingNavigationAndBackupControls() throws {
        for darkMode in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["-hasCompletedWelcome", "YES", "-prefersDarkMode", darkMode ? "YES" : "NO"]
            app.launch()
            for title in ["Calendar", "Maps", "Daily", "Settings"] {
                XCTAssertTrue(app.tabBars.buttons[title].waitForExistence(timeout: 10), title)
            }
            for title in ["Calendar", "Daily"] {
                app.tabBars.buttons[title].tap()
                let heading = title == "Calendar" ? "Daymark" : title
                XCTAssertTrue(app.navigationBars[heading].waitForExistence(timeout: 5))
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "\(title) \(darkMode ? "dark" : "light")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            app.tabBars.buttons["Settings"].tap()
            XCTAssertTrue(app.buttons["Import"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Export"].exists)
            XCTAssertTrue(app.staticTexts["Backup"].exists)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = darkMode ? "Settings dark" : "Settings light"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
