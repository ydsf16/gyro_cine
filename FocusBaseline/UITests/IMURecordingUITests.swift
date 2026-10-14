import XCTest

final class IMURecordingUITests: XCTestCase {
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
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        XCTAssertTrue(record.isEnabled)
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
