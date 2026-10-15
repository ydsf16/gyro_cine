import XCTest

final class IMURecordingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        let systemAlert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if systemAlert.exists && systemAlert.label.contains("GyroCine") && systemAlert.buttons["允许"].exists {
            systemAlert.buttons["允许"].tap()
        }
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
        app.buttons["parameter.Shutter"].tap()
        Thread.sleep(forTimeInterval: 0.5)
        for (rate, denominator) in [("60.0 fps", "1/200"), ("30.0 fps", "1/200")] {
            app.buttons["settingsOpen"].tap()
            if !app.buttons["fpsMenu"].waitForExistence(timeout: 2) {
                app.buttons["settingsOpen"].tap()
            }
            XCTAssertTrue(app.buttons["fpsMenu"].waitForExistence(timeout: 5))
            let fpsReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"),
                                                      object: app.buttons["fpsMenu"])
            XCTAssertEqual(XCTWaiter.wait(for: [fpsReady], timeout: 30), .completed,
                           "Wait for any startup IMU finalization before changing FPS")
            tapFPSOption(rate, in: app)
            app.buttons["完成"].tap()
            app.buttons["parameter.Shutter"].tap()
            let label = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "最长", denominator)).firstMatch
            XCTAssertTrue(label.waitForExistence(timeout: 5), app.debugDescription)
            app.buttons["parameter.Shutter"].tap()
            Thread.sleep(forTimeInterval: 0.4)
        }
        app.buttons["settingsOpen"].tap()
        XCTAssertTrue(app.buttons["fpsMenu"].waitForExistence(timeout: 5))
        tapFPSOption("60.0 fps", in: app)
        app.buttons["完成"].tap()
    }

    func testShutterAngleTracksFrameRate() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["parameter.Shutter"].waitForExistence(timeout: 20))
        app.buttons["settingsOpen"].tap()
        XCTAssertTrue(app.buttons["fpsMenu"].waitForExistence(timeout: 5))
        tapFPSOption("30.0 fps", in: app)
        app.buttons["exposureTypeMenu"].tap()
        app.buttons["exposureType.angle"].tap()
        app.buttons["完成"].tap()

        app.buttons["parameter.Shutter"].tap()
        XCTAssertTrue(app.buttons["M"].waitForExistence(timeout: 3))
        app.buttons["M"].tap()
        let atThirty = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "180°", "1/60")).firstMatch
        XCTAssertTrue(atThirty.waitForExistence(timeout: 5), app.debugDescription)

        app.buttons["settingsOpen"].tap()
        XCTAssertTrue(app.buttons["fpsMenu"].waitForExistence(timeout: 5))
        tapFPSOption("60.0 fps", in: app)
        app.buttons["完成"].tap()
        app.buttons["parameter.Shutter"].tap()
        let atSixty = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "180°", "1/120")).firstMatch
        XCTAssertTrue(atSixty.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["A-Max"].tap()
        app.buttons["settingsOpen"].tap()
        app.buttons["exposureTypeMenu"].tap()
        app.buttons["exposureType.speed"].tap()
        app.buttons["完成"].tap()
    }

    private func tapFPSOption(_ rate: String, in app: XCUIApplication) {
        let option = app.buttons["fpsOption.\(rate)"]
        for _ in 0..<3 {
            let menuFrame = app.buttons["fpsMenu"].frame
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: menuFrame.midX, dy: menuFrame.midY)).tap()
            if option.waitForExistence(timeout: 3) {
                let frame = option.frame
                if frame.midX.isFinite && frame.midY.isFinite {
                    app.coordinate(withNormalizedOffset: .zero)
                        .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTFail("Frame rate option is not on screen: \(rate)")
    }

    func testViewfinderGuides() {
        let app = XCUIApplication(); app.launch()
        if app.alerts.firstMatch.waitForExistence(timeout: 2) {
            let dismiss = app.alerts.firstMatch.buttons["确定"]
            if dismiss.exists { dismiss.tap() }
        }
        app.buttons["settingsOpen"].tap()
        let grid = app.switches["gridToggle"]
        let level = app.switches["levelToggle"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        for _ in 0..<3 where !grid.isHittable || !level.isHittable { app.swipeUp() }
        XCTAssertTrue(grid.isHittable && level.isHittable)
        if grid.value as? String != "1" {
            grid.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        if level.value as? String != "1" {
            level.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertEqual(grid.value as? String, "1")
        XCTAssertEqual(level.value as? String, "1")
        app.buttons["完成"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Grid and horizon enabled"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testRestoreViewfinderGuidesOff() {
        let app = XCUIApplication(); app.launch()
        app.buttons["settingsOpen"].tap()
        let grid = app.switches["gridToggle"]
        let level = app.switches["levelToggle"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        for _ in 0..<3 where !grid.isHittable || !level.isHittable { app.swipeUp() }
        if grid.value as? String == "1" {
            grid.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        if level.value as? String == "1" {
            level.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertEqual(grid.value as? String, "0")
        XCTAssertEqual(level.value as? String, "0")
        app.buttons["完成"].tap()
    }

    func testGyroflowProtoRecording() {
        record(format: "Gyroflow Proto MOV")
    }

    func testRaw4KResolutionAndSSDSetupPrompt() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 20))
        app.buttons["settingsOpen"].tap()
        XCTAssertTrue(app.buttons["codecMenu"].waitForExistence(timeout: 10))
        app.buttons["codecMenu"].tap()
        app.buttons["ProRes RAW"].tap()
        XCTAssertTrue(app.buttons["resolutionMenu"].waitForExistence(timeout: 10))
        app.buttons["resolutionMenu"].tap()
        let raw4K = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "4K · ")).firstMatch
        XCTAssertTrue(raw4K.waitForExistence(timeout: 10),
                      "RAW should expose a supported wide 4K capture format")
        raw4K.tap()
        app.buttons["完成"].tap()
        app.buttons["recordToggle"].tap()
        XCTAssertTrue(app.alerts.buttons["设置 SSD"].waitForExistence(timeout: 10))
        app.alerts.buttons["设置 SSD"].tap()
        XCTAssertTrue(app.buttons["outputFormatMenu"].waitForExistence(timeout: 10))
    }

    func testSonyRecording() {
        record(format: "Sony MOV")
    }

    func testIntrinsicsAfterLensSwitch() {
        record(format: "Gyroflow Proto MOV", switchLenses: true)
    }

    func testSonyFinalizesAfterBackgroundAndRelaunch() {
        record(format: "Sony MOV", resumeAfterBackground: true)
    }

    func testMediaSelectionAndDeletion() {
        record(format: "Sony MOV")
        let app = XCUIApplication()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mediaRow.UITEST_"))
        let first = rows.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let identifier = first.identifier
        first.press(forDuration: 1.1)
        XCTAssertTrue(app.buttons["mediaDeleteSelected"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["mediaShareSelected"].isEnabled)
        app.buttons["mediaSelect"].tap()
        XCTAssertFalse(app.buttons["mediaDeleteSelected"].exists)
        app.buttons["mediaSelect"].tap()
        app.buttons[identifier].tap()
        app.buttons["mediaDeleteSelected"].tap()
        app.buttons["删除文件"].tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons[identifier])
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testParameterModesAndPanelMonitoring() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["parameter.Shutter"].waitForExistence(timeout: 20))
        for (parameter, manual, auto) in [("Shutter", "M", "A-Max"), ("ISO", "M", "A"), ("WB", "M", "A"), ("Focus", "MF", "AF-C")] {
            app.buttons["parameter.\(parameter)"].tap()
            Thread.sleep(forTimeInterval: 3)
            XCTAssertTrue(app.buttons[manual].exists, "Panel should remain open for monitoring")
            app.buttons[manual].tap()
            app.buttons[auto].tap()
            Thread.sleep(forTimeInterval: 3)
            XCTAssertFalse(app.buttons[manual].exists, "Panel should close after adjustment")
            XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
        }
    }

    func testLongRecording() { record(format: "Sony MOV", seconds: 60) }

    func testBatchShareAndDelete() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["mediaOpen"].waitForExistence(timeout: 20))
        app.buttons["mediaOpen"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mediaRow.UITEST_"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        let ids = [rows.element(boundBy: 0).identifier, rows.element(boundBy: 1).identifier]
        app.buttons["mediaSelect"].tap()
        for id in ids { app.buttons[id].tap() }
        app.buttons["mediaShareSelected"].tap()
        Thread.sleep(forTimeInterval: 2)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(app.otherElements["ActivityListView"].exists || app.buttons["拷贝"].exists || app.buttons["Copy"].exists || app.buttons["关闭"].exists, app.debugDescription)
        // Dismiss without choosing a recipient or transmitting media.
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["mediaOpen"].waitForExistence(timeout: 20)); app.buttons["mediaOpen"].tap()
        app.buttons["mediaSelect"].tap()
        for id in ids { app.buttons[id].tap() }
        app.buttons["mediaDeleteSelected"].tap(); app.buttons["删除文件"].tap()
        for id in ids {
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons[id])
            XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed)
        }
    }

    func testVideoSettingsAndRecordingLocks() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 20))
        app.buttons["settingsOpen"].tap()
        for codec in ["H.265 HQ", "H.265"] {
            app.buttons["codecMenu"].tap(); app.buttons[codec].tap()
            Thread.sleep(forTimeInterval: 1)
            XCTAssertFalse(app.alerts.firstMatch.exists)
        }
        app.buttons["resolutionMenu"].tap()
        let options = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1920×1080"))
        XCTAssertTrue(options.firstMatch.waitForExistence(timeout: 5)); options.firstMatch.tap()
        app.buttons["完成"].tap()
        app.buttons["recordToggle"].tap()
        let started = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "停止录制"), object: app.buttons["recordToggle"])
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 15), .completed)
        app.buttons["settingsOpen"].tap()
        for id in ["codecMenu", "resolutionMenu", "fpsMenu", "outputFormatMenu"] { XCTAssertFalse(app.buttons[id].isEnabled) }
        app.buttons["完成"].tap(); app.buttons["recordToggle"].tap()
        Thread.sleep(forTimeInterval: 4)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testRulersTapAndHoldFocus() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["parameter.Focus"].waitForExistence(timeout: 20))
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        center.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["parameter.Focus"].label.contains("锁定"))
        center.tap()
        XCTAssertTrue(app.buttons["parameter.Focus"].label.contains("AF-C"))
        for (name, manual, auto) in [("Shutter", "M", "A-Max"), ("ISO", "M", "A"), ("WB", "M", "A"), ("Focus", "MF", "AF-C")] {
            app.buttons["parameter.\(name)"].tap(); app.buttons[manual].tap()
            let ruler = app.otherElements["parameterRuler"]
            XCTAssertTrue(ruler.waitForExistence(timeout: 2))
            ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)).press(forDuration: 0.1,
                thenDragTo: ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)))
            if !app.buttons[auto].exists { app.buttons["parameter.\(name)"].tap() }
            app.buttons[auto].tap()
            Thread.sleep(forTimeInterval: 3)
            XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
        }
    }

    func testMediaPreviewAndPhotoImport() {
        record(format: "Sony MOV")
        let app = XCUIApplication()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mediaRow.UITEST_")).firstMatch
        let filename = String(row.identifier.dropFirst("mediaRow.".count))
        app.buttons["mediaSave.\(filename)"].tap()
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if permission.waitForExistence(timeout: 2), permission.buttons["允许"].exists { permission.buttons["允许"].tap() }
        let saved = app.alerts.firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 15))
        XCTAssertTrue(saved.staticTexts["已存入相册"].exists, app.debugDescription)
        saved.buttons["确定"].tap()
        row.tap()
        XCTAssertTrue(app.staticTexts["imuBadge.\(filename)"].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
    }

    func testMediaSwipeDeletion() {
        record(format: "Sony MOV")
        let app = XCUIApplication()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mediaRow.UITEST_")).firstMatch
        let id = row.identifier
        row.swipeLeft()
        app.buttons["删除"].firstMatch.tap(); app.buttons["删除文件"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons[id])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed)
    }

    func testZZRestoreAndCleanTestMedia() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["mediaOpen"].waitForExistence(timeout: 20))
        app.buttons["mediaOpen"].tap()
        for _ in 0..<12 {
            let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mediaRow.UITEST_"))
            let visible = rows.allElementsBoundByIndex.filter { $0.isHittable }.map(\.identifier)
            if visible.isEmpty { break }
            app.buttons["mediaSelect"].tap()
            for id in visible { app.buttons[id].tap() }
            app.buttons["mediaDeleteSelected"].tap(); app.buttons["删除文件"].tap()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mediaRow.UITEST_")).count, 0)
        app.buttons["完成"].tap(); app.buttons["settingsOpen"].tap()
        XCTAssertTrue(app.buttons["resolutionMenu"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        let menuFrame = app.buttons["resolutionMenu"].frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: menuFrame.midX, dy: menuFrame.midY)).tap()
        let resolution = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "3840×2160")).firstMatch
        if !resolution.waitForExistence(timeout: 3) { app.buttons["resolutionMenu"].tap() }
        XCTAssertTrue(resolution.waitForExistence(timeout: 5))
        resolution.tap()
        Thread.sleep(forTimeInterval: 1)
        app.buttons["fpsMenu"].tap(); Thread.sleep(forTimeInterval: 1)
        let option = app.buttons["fpsOption.60.0 fps"]
        let frame = option.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "3840×2160", "60.0fps")).firstMatch.exists)
        XCUIDevice.shared.press(.home)
    }

    func testPerformanceADebugOff4K60() {
        record(format: "Sony MOV", seconds: 60, debug: false, require4K60: true)
    }
    func testPerformanceBDebugOn4K60() {
        record(format: "Sony MOV", seconds: 60, debug: true, require4K60: true)
    }

    func testCleanupUITestClipsAcrossMediaList() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.buttons["mediaOpen"].tap()
        app.buttons["mediaSelect"].tap()
        var selected = Set<String>()
        for _ in 0..<15 {
            let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mediaRow.UITEST_"))
            let visible = rows.allElementsBoundByIndex.filter { $0.isHittable && !selected.contains($0.identifier) }
            for row in visible {
                let id = row.identifier
                row.tap()
                selected.insert(id)
            }
            app.swipeUp()
        }
        if selected.isEmpty { return }
        app.buttons["mediaDeleteSelected"].tap()
        app.buttons["删除文件"].tap()
        XCTAssertTrue(app.buttons["mediaSelect"].waitForExistence(timeout: 10))
    }

    private func record(format: String, switchLenses: Bool = false, resumeAfterBackground: Bool = false, seconds: Double = 4, debug: Bool = true, require4K60: Bool = false) {
        let app = XCUIApplication()
        app.launchArguments = ["-outputFormat", format == "Sony MOV" ? "SonyMov" : "GyroflowProto",
            "-debugEnabled", debug ? "YES" : "NO", "--ui-testing"]
        app.launch()
        let record = app.buttons["recordToggle"]
        XCTAssertTrue(record.waitForExistence(timeout: 20))
        // Previously retained failures may be reported during startup recovery.
        if app.alerts.firstMatch.waitForExistence(timeout: 2) {
            let dismiss = app.alerts.firstMatch.buttons["确定"]
            if dismiss.exists { dismiss.tap() }
        }
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
        if require4K60 {
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "3840×2160", "60.0fps")).firstMatch.exists)
        }
        record.tap()
        let stop = app.buttons["recordToggle"]
        let began = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "停止录制"), object: stop)
        guard XCTWaiter.wait(for: [began], timeout: 15) == .completed else {
            XCTFail("Recording did not start: \(app.debugDescription)"); return
        }
        Thread.sleep(forTimeInterval: seconds)
        if resumeAfterBackground {
            XCUIApplication(bundleIdentifier: "com.apple.Preferences").activate()
            let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.state == .runningBackground || app.state == .runningBackgroundSuspended
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 5), .completed, "App did not enter background")
            Thread.sleep(forTimeInterval: 3)
            app.terminate()
            app.launch()
            if app.alerts.firstMatch.waitForExistence(timeout: 2) {
                let dismiss = app.alerts.firstMatch.buttons["确定"]
                if dismiss.exists { dismiss.tap() }
            }
        } else {
            stop.tap()
        }
        XCTAssertTrue(app.buttons["mediaOpen"].waitForExistence(timeout: 30))
        app.buttons["mediaOpen"].tap()
        let badge = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "imuBadge.")).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        let embedded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "IMU"), object: badge)
        XCTAssertEqual(XCTWaiter.wait(for: [embedded], timeout: 30), .completed)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }
}
