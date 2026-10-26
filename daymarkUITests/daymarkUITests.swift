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
    func testMapOpensAndTogglesSatellite() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedWelcome", "YES", "-mapShowsSatellite", "NO"]
        addUIInterruptionMonitor(withDescription: "Location permission") { alert in
            for label in ["Don’t Allow", "Don't Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()

        app.tabBars.buttons["Maps"].tap()
        let toggle = app.buttons["mapStyleToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        if app.alerts["Location Access Needed"].exists {
            app.alerts["Location Access Needed"].buttons["OK"].tap()
        }

        for (expected, name) in [("Show Standard Map", "satellite"), ("Show Satellite Map", "standard")] {
            toggle.tap()
            let predicate = NSPredicate(format: "label == %@", expected)
            expectation(for: predicate, evaluatedWith: toggle)
            waitForExpectations(timeout: 5)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Map \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        // The tab bar must still respond after the map has loaded.
        app.tabBars.buttons["Calendar"].tap()
        XCTAssertTrue(app.navigationBars["Daymark"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
