import XCTest

final class DeviceRecordingTests: XCTestCase {
    func testSSDWarningAppearsWithoutLeavingSettings() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 10))
        app.buttons["settingsButton"].tap()
        app.buttons["storageLocationPicker"].tap()
        app.buttons["SSD"].tap()
        XCTAssertTrue(app.alerts["未检测到 SSD"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.navigationBars["录制设置"].exists)
    }
    func testOutputModeSettingsPersist() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 10))
        app.buttons["settingsButton"].tap()
        let picker = app.buttons["outputModePicker"]
        for _ in 0..<8 { if picker.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(picker.isHittable, app.debugDescription)
        for label in ["Gyroflow Sony Mov", "Gyroflow protobuf Mov（1.6.3 Nightly）", "原视频+GCSV"] {
            picker.tap()
            let choice = app.buttons[label]
            XCTAssertTrue(choice.waitForExistence(timeout: 3), app.debugDescription)
            choice.tap()
            XCTAssertTrue(picker.label.contains(label), app.debugDescription)
        }
        picker.tap()
        app.buttons["Gyroflow protobuf Mov（1.6.3 Nightly）"].tap()
        app.terminate(); app.launch()
        app.buttons["settingsButton"].tap()
        for _ in 0..<8 { if picker.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(picker.label.contains("Gyroflow protobuf Mov（1.6.3 Nightly）"), app.debugDescription)
        picker.tap(); app.buttons["原视频+GCSV"].tap()
    }

    func testCameraParameterPanels() {
        let app = XCUIApplication()
        app.launch()
        for name in ["分辨率", "帧率", "最长曝光", "白平衡"] {
            let button = app.buttons["control_" + name]
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            XCTAssertTrue(button.isHittable, app.debugDescription)
            button.tap()
            XCTAssertTrue(app.otherElements["cameraControlPanel_" + name].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.buttons["closeCameraControl"].isHittable, app.debugDescription)
            app.buttons["closeCameraControl"].tap()
        }

    }

    func testPortraitControlsOverlayFullScreenPreview() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        for name in ["分辨率", "帧率", "最长曝光", "白平衡"] {
            let button = app.buttons["control_" + name]
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            button.tap()
            let panel = app.otherElements["cameraControlPanel_" + name]
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(panel.frame.width, app.frame.width * 0.85)
            XCTAssertLessThan(panel.frame.height, 205)
            let preview = app.otherElements["cameraViewfinder"].frame
            XCTAssertEqual(preview.width, app.frame.width, accuracy: 1)
            XCTAssertEqual(preview.height, app.frame.height, accuracy: 1)
            XCTAssertTrue(preview.contains(panel.frame.intersection(app.frame)))
            XCTAssertLessThanOrEqual(panel.frame.maxY, app.buttons["recordToggle"].frame.minY + 1)
            XCTAssertTrue(app.buttons["closeCameraControl"].isHittable)
            XCTAssertTrue(app.buttons["settingsButton"].isHittable)
            app.buttons["closeCameraControl"].tap()
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testRepeatedCameraRotation() {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["control_最长曝光"].waitForExistence(timeout: 10))
        // Cover both the closed layout and an expanded parameter panel.
        for expanded in [false, true] {
            if expanded { app.buttons["control_最长曝光"].tap() }
            for orientation: UIDeviceOrientation in [.landscapeLeft, .portrait, .landscapeRight, .portrait] {
                XCUIDevice.shared.orientation = orientation
                let preview = app.otherElements["cameraViewfinder"]
                let landscape = orientation.isLandscape
                let sizeReady = NSPredicate { _, _ in
                    let frame = preview.frame
                    return landscape ? frame.width > frame.height : frame.height > frame.width
                }
                expectation(for: sizeReady, evaluatedWith: preview)
                waitForExpectations(timeout: 5)
                XCTAssertTrue(app.buttons["recordToggle"].isHittable)
                XCTAssertTrue(app.buttons["settingsButton"].isHittable)
                XCTAssertTrue(app.buttons["control_最长曝光"].isHittable)
                XCTAssertEqual(preview.frame.width, app.frame.width, accuracy: 1)
                XCTAssertEqual(preview.frame.height, app.frame.height, accuracy: 1)
                if expanded {
                    XCTAssertTrue(app.buttons["closeCameraControl"].isHittable)
                }
                let image = XCTAttachment(screenshot: app.screenshot())
                image.lifetime = .keepAlways
                add(image)
            }
        }
    }

    func testSimpleCameraControls() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["control_最长曝光"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["switchCameraButton"].exists)
        XCTAssertGreaterThan(app.buttons["settingsButton"].frame.midY, app.frame.midY)
        XCTAssertFalse(app.buttons["control_最长曝光"].label.contains("最长曝光"))
        for removed in ["镜头", "ISO", "色调", "快门"] {
            XCTAssertFalse(app.buttons["control_" + removed].exists)
        }
        app.buttons["control_最长曝光"].tap()
        // Simulator has no capture formats; verify capability-independent UI here.
        // A concrete exposure limit is separately exercised on the physical phone.
        XCTAssertTrue(app.buttons["系统默认"].exists)
        XCTAssertFalse(app.buttons["exposureManual"].exists)
        app.buttons["closeCameraControl"].tap()
        app.buttons["settingsButton"].tap()
        XCTAssertFalse(app.staticTexts["设备能力"].exists)
        XCTAssertFalse(app.staticTexts["同步时间补偿"].exists)
        XCTAssertTrue(app.buttons["outputModePicker"].exists)
    }

    func testMediaFixturePreviewAndDelete() {
        // Seeded by the host in this simulator's Documents; never targets user clips.
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["libraryButton"].waitForExistence(timeout: 10))
        app.buttons["libraryButton"].tap()
        let actions = app.buttons["recordingActions_recording_ui_fixture"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        app.buttons["预览"].tap()
        XCTAssertTrue(app.buttons["closeVideoPreview"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["closeVideoPreview"].isHittable)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["closeVideoPreview"].isHittable)
        app.buttons["closeVideoPreview"].tap()
        actions.tap()
        app.buttons["删除录制"].tap()
        XCTAssertTrue(app.buttons["删除"].waitForExistence(timeout: 5))
        app.buttons["删除"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: actions)
        waitForExpectations(timeout: 5)
    }

    func testCameraNavigation() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 10))
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["录制设置"].waitForExistence(timeout: 5))
        let storage = app.buttons["storageLocationPicker"]
        XCTAssertTrue(storage.exists)
        storage.tap()
        XCTAssertTrue(app.buttons["文件"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["SSD"].waitForExistence(timeout: 5))
        app.buttons["文件"].tap()
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
        app.buttons["视频编码"].tap()
        let raw = app.buttons[hq ? "ProRes RAW HQ" : "ProRes RAW"].firstMatch
        XCTAssertTrue(raw.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(raw.isEnabled, "RAW capability unavailable: \(app.debugDescription)")
        raw.tap()
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
                expectation(for: NSPredicate(format: "value BEGINSWITH[c] %@", "Recording"), evaluatedWith: app.buttons["recordToggle"])
                waitForExpectations(timeout: 15)
                Thread.sleep(forTimeInterval: 5)
                toggle.tap()
                expectation(for: NSPredicate(format: "value BEGINSWITH[c] %@", "Completed"), evaluatedWith: app.buttons["recordToggle"])
                waitForExpectations(timeout: 45)
            }
            return
        }
        expectation(for: NSPredicate(format: "value BEGINSWITH[c] %@", "Recording"), evaluatedWith: app.buttons["recordToggle"])
        waitForExpectations(timeout: 20)
        Thread.sleep(forTimeInterval: 5)
        toggle.tap()
        expectation(for: NSPredicate(format: "value BEGINSWITH[c] %@", "Completed"), evaluatedWith: app.buttons["recordToggle"])
        waitForExpectations(timeout: 60)
    }

    func testDeviceCappedExposureRecording() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        let picker = app.buttons.matching(NSPredicate(format: "value BEGINSWITH[c] %@", "最长曝光时间")).firstMatch
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
        expectation(for: NSPredicate(format: "value BEGINSWITH[c] %@", "Recording"),
                    evaluatedWith: app.buttons["recordToggle"])
        waitForExpectations(timeout: 15)
        Thread.sleep(forTimeInterval: 5)
        toggle.tap()
        expectation(for: NSPredicate(format: "value BEGINSWITH[c] %@", "Completed"),
                    evaluatedWith: app.buttons["recordToggle"])
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
        XCTAssertTrue(app.buttons["recordToggle"].waitForExistence(timeout: 10))
        let recording = NSPredicate(format: "value BEGINSWITH[c] %@", "Recording")
        expectation(for: recording, evaluatedWith: app.buttons["recordToggle"])
        waitForExpectations(timeout: 10)
        if lensName != nil {
            for lens in app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "lens_")).allElementsBoundByIndex {
                XCTAssertFalse(lens.isEnabled, "Lens must be locked while recording")
            }
        }
        Thread.sleep(forTimeInterval: seconds)
        toggle.tap()
        let completed = NSPredicate(format: "value BEGINSWITH[c] %@", "Completed")
        expectation(for: completed, evaluatedWith: app.buttons["recordToggle"])
        waitForExpectations(timeout: 40)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
