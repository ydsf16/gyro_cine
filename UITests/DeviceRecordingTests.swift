import XCTest

final class DeviceRecordingTests: XCTestCase {
    func testCameraNavigation() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 10))
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["录制设置"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.buttons["libraryButton"].tap()
        XCTAssertTrue(app.navigationBars["素材"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testDeviceShortRecording() throws {
        try record(seconds: 5)
    }

    func testDevice60SecondRecording() throws { try record(seconds: 60) }
    func testDevice20SecondRecording() throws { try record(seconds: 20) }

    private func record(seconds: TimeInterval) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.launch()
        let toggle = app.buttons["recordToggle"]
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline && (!toggle.exists || !toggle.isEnabled) {
            if springboard.alerts.firstMatch.exists {
                let buttons = springboard.alerts.firstMatch.buttons
                if buttons.count > 0 { buttons.element(boundBy: buttons.count - 1).tap() }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(toggle.exists && toggle.isEnabled, "Camera did not reach ready: \(app.debugDescription)")
        toggle.tap()
        XCTAssertTrue(app.staticTexts["recordingState"].waitForExistence(timeout: 10))
        let recording = NSPredicate(format: "label BEGINSWITH %@", "Recording")
        expectation(for: recording, evaluatedWith: app.staticTexts["recordingState"])
        waitForExpectations(timeout: 10)
        Thread.sleep(forTimeInterval: seconds)
        toggle.tap()
        let completed = NSPredicate(format: "label BEGINSWITH %@", "Completed")
        expectation(for: completed, evaluatedWith: app.staticTexts["recordingState"])
        waitForExpectations(timeout: 40)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
