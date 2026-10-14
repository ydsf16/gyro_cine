import XCTest

final class IMURecordingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "Camera and microphone permissions") { alert in
            for title in ["允许", "Allow", "好", "OK"] where alert.buttons[title].exists {
                alert.buttons[title].tap(); return true
            }
            return false
        }
    }
    func testFrameRateRestoresAutoMax() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["parameter.Shutter"].waitForExistence(timeout: 20))
        app.tap()
        app.buttons["parameter.Shutter"].tap()
        app.buttons["M"].tap()
        for (rate, denominator) in [("60.0 fps", "1/240"), ("30.0 fps", "1/120")] {
            app.buttons["settingsOpen"].tap()
            app.buttons["fpsMenu"].tap()
            app.buttons[rate].tap()
            app.buttons["完成"].tap()
            app.buttons["parameter.Shutter"].tap()
            let label = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "最长", denominator)).firstMatch
            XCTAssertTrue(label.waitForExistence(timeout: 5), app.debugDescription)
            app.buttons["parameter.Shutter"].tap()
        }
    }

    func testGyroflowProtoRecording() {
        record(format: "Gyroflow Proto MOV")
    }

    func testSonyRecording() {
        record(format: "Sony MOV")
    }

    func testIntrinsicsAfterLensSwitch() {
        record(format: "Gyroflow Proto MOV", switchLenses: true)
    }

    private func record(format: String, switchLenses: Bool = false) {
        let app = XCUIApplication()
        app.launchArguments = ["-outputFormat", format == "Sony MOV" ? "SonyMov" : "GyroflowProto",
            "-debugEnabled", "YES"]
        app.launch()
        let record = app.buttons["recordToggle"]
        XCTAssertTrue(record.waitForExistence(timeout: 20))
        app.tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: record)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        if switchLenses {
            for lens in ["0.5×", "1×"] {
                let choice = app.buttons["lens.\(lens)"]
                if !choice.exists { app.buttons["parameter.Lens"].tap() }
                XCTAssertTrue(choice.waitForExistence(timeout: 5))
                choice.tap()
                Thread.sleep(forTimeInterval: 3)
                XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
            }
        }
        record.tap()
        let stop = app.buttons["recordToggle"]
        let began = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "停止录制"), object: stop)
        guard XCTWaiter.wait(for: [began], timeout: 15) == .completed else {
            XCTFail("Recording did not start: \(app.debugDescription)"); return
        }
        Thread.sleep(forTimeInterval: 4)
        stop.tap()
        XCTAssertTrue(app.staticTexts["saveStatus"].waitForExistence(timeout: 30), app.debugDescription)
    }
}
