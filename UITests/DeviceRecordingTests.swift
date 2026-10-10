import XCTest

final class DeviceRecordingTests: XCTestCase {
    func testOutputModeSettingsPersist() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 10))
        app.buttons["settingsButton"].tap()
        let picker = app.buttons["outputModePicker"]
        for _ in 0..<8 { if picker.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(picker.isHittable, app.debugDescription)
        for label in ["Sony MOV（兼容实验）", "Gyroflow Protobuf MOV", "GCSV + 原始视频"] {
            picker.tap()
            let choice = app.buttons[label]
            XCTAssertTrue(choice.waitForExistence(timeout: 3), app.debugDescription)
            choice.tap()
            XCTAssertTrue(picker.label.contains(label), app.debugDescription)
        }
        picker.tap()
        app.buttons["Gyroflow Protobuf MOV"].tap()
        app.terminate(); app.launch()
        app.buttons["settingsButton"].tap()
        for _ in 0..<8 { if picker.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(picker.label.contains("Gyroflow Protobuf MOV"), app.debugDescription)
        picker.tap(); app.buttons["GCSV + 原始视频"].tap()
    }

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

    func testDeviceFolderShareSheet() {
        let app = XCUIApplication()
        app.launch()
        let library = app.buttons["libraryButton"]
        XCTAssertTrue(library.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: library)
        waitForExpectations(timeout: 20)
        library.tap()
        let share = app.buttons["分享 Gyroflow 录制文件夹"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        share.tap()
        let save = app.cells.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS %@", "Save to Files", "存储到“文件”")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), app.debugDescription)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(app.otherElements["ActivityListView"].exists)
    }

    func testDeviceShortRecording() throws {
        try record(seconds: 5)
    }

    func testDevice60SecondRecording() throws { try record(seconds: 60) }
    func testDevice20SecondRecording() throws { try record(seconds: 20) }

    func testDeviceMainLens20Seconds() throws { try record(seconds: 20, lensName: "主摄") }
    func testDeviceUltraWide20Seconds() throws { try record(seconds: 20, lensName: "超广角") }

    func testRAWRequiresExternalStorage() throws { try recordRAW(hq: false, expectMissingStorage: true) }
    func testRAWHQRequiresExternalStorage() throws { try recordRAW(hq: true, expectMissingStorage: true) }
    func testDeviceRAWRecording() throws { try recordRAW(hq: false) }
    func testDeviceRAWHQRecording() throws { try recordRAW(hq: true) }

    private func recordRAW(hq: Bool, expectMissingStorage: Bool = false) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let toggle = app.buttons["recordToggle"]
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline && (!toggle.exists || !toggle.isEnabled) {
            if springboard.alerts.firstMatch.exists {
                let buttons = springboard.alerts.firstMatch.buttons
                if buttons.count > 0 { buttons.element(boundBy: buttons.count - 1).tap() }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(toggle.isEnabled, app.debugDescription)
        app.buttons["settingsButton"].tap()
        let raw = app.buttons["ProRes RAW"].firstMatch
        XCTAssertTrue(raw.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(raw.isEnabled, "RAW capability unavailable: \(app.debugDescription)")
        raw.tap()
        let quality = app.switches["HQ 高质量"]
        XCTAssertTrue(quality.waitForExistence(timeout: 10), app.debugDescription)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: quality)
        waitForExpectations(timeout: 30)
        if hq {
            let control = quality.switches.firstMatch
            if control.exists { control.tap() } else { quality.tap() }
            XCTAssertEqual(quality.value as? String, "1", app.debugDescription)
        }
        app.buttons["完成"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: toggle)
        waitForExpectations(timeout: 30)
        XCTAssertTrue(app.staticTexts[hq ? "ProRes RAW HQ" : "ProRes RAW"].exists, app.debugDescription)
        toggle.tap()
        if expectMissingStorage {
            let warning = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "请连接后重试")).firstMatch
            XCTAssertTrue(warning.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.buttons["settingsButton"].isEnabled)
            if !hq {
                app.buttons["settingsButton"].tap()
                app.buttons["HEVC"].firstMatch.tap()
                app.buttons["完成"].tap()
                expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: toggle)
                waitForExpectations(timeout: 30)
                toggle.tap()
                expectation(for: NSPredicate(format: "label BEGINSWITH %@", "Recording"), evaluatedWith: app.staticTexts["recordingState"])
                waitForExpectations(timeout: 15)
                Thread.sleep(forTimeInterval: 5)
                toggle.tap()
                expectation(for: NSPredicate(format: "label BEGINSWITH %@", "Completed"), evaluatedWith: app.staticTexts["recordingState"])
                waitForExpectations(timeout: 45)
            }
            return
        }
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "Recording"), evaluatedWith: app.staticTexts["recordingState"])
        waitForExpectations(timeout: 20)
        Thread.sleep(forTimeInterval: 5)
        toggle.tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "Completed"), evaluatedWith: app.staticTexts["recordingState"])
        waitForExpectations(timeout: 60)
    }

    func testDeviceCappedExposureRecording() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "最长曝光时间")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        picker.tap()
        let shutter = app.buttons["1/120 秒"].firstMatch
        XCTAssertTrue(shutter.waitForExistence(timeout: 10), app.debugDescription)
        shutter.tap()
        app.buttons["完成"].tap()
        let toggle = app.buttons["recordToggle"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: toggle)
        waitForExpectations(timeout: 20)
        toggle.tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "Recording"),
                    evaluatedWith: app.staticTexts["recordingState"])
        waitForExpectations(timeout: 15)
        Thread.sleep(forTimeInterval: 5)
        toggle.tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "Completed"),
                    evaluatedWith: app.staticTexts["recordingState"])
        waitForExpectations(timeout: 40)
    }

    private func record(seconds: TimeInterval, lensName: String? = nil) throws {
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
        if let lensName {
            let lens = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "lens_", lensName)).firstMatch
            XCTAssertTrue(lens.exists && lens.isEnabled, "Lens unavailable: \(lensName); \(app.debugDescription)")
            lens.tap()
            let ready = NSPredicate(format: "enabled == true")
            expectation(for: ready, evaluatedWith: toggle)
            waitForExpectations(timeout: 15)
        }
        toggle.tap()
        XCTAssertTrue(app.staticTexts["recordingState"].waitForExistence(timeout: 10))
        let recording = NSPredicate(format: "label BEGINSWITH %@", "Recording")
        expectation(for: recording, evaluatedWith: app.staticTexts["recordingState"])
        waitForExpectations(timeout: 10)
        if lensName != nil {
            for lens in app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "lens_")).allElementsBoundByIndex {
                XCTAssertFalse(lens.isEnabled, "Lens must be locked while recording")
            }
        }
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
