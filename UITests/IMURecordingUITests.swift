import XCTest

final class IMURecordingUITests: XCTestCase {
    func testLocationSettingBothLanguages() {
        addUIInterruptionMonitor(withDescription: "Location permission") { alert in
            for name in ["Allow While Using App", "使用 App 时允许", "使用App时允许", "使用期间允许"] {
                if alert.buttons[name].exists { alert.buttons[name].tap(); return true }
            }
            return false
        }
        for language in ["en", "zh-Hans"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--settings-ui-preview", "-AppleLanguages", "(\(language))"]
            app.launch()
            let toggle = app.switches["recordLocationToggle"]
            for _ in 0..<10 {
                if toggle.exists && toggle.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            if (toggle.value as? String) == "1" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap() // Handle a possible permission sheet.
            XCTAssertEqual(toggle.value as? String, "1")
            controlScreenshot(app, "location-setting-\(language)")
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertEqual(toggle.value as? String, "0")
            app.terminate()
        }
    }

    func testLocationRecordingOnThenOff() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)"]
        app.launch()
        let record = app.buttons["recordToggle"]
        XCTAssertTrue(record.waitForExistence(timeout: 25))
        for enabled in [true, false] {
            app.buttons["settingsOpen"].tap()
            let toggle = app.switches["recordLocationToggle"]
            for _ in 0..<10 {
                if toggle.exists && toggle.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(toggle.exists)
            if ((toggle.value as? String) == "1") != enabled { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
            if enabled {
                XCTAssertTrue(app.staticTexts["The recording location will be shared with the video."].waitForExistence(timeout: 20), "A real location fix is required for this recording test")
            }
            app.buttons["captureSettingsClose"].tap()
            record.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == 'Stop recording'"), object: record)], timeout: 15), .completed)
            Thread.sleep(forTimeInterval: 3)
            record.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "enabled == true AND label == 'Record'"), object: record)], timeout: 20), .completed)
            XCTAssertFalse(app.alerts.firstMatch.exists)
        }
    }

    /// Supply real, finalized SSD clips; this test never creates or deletes user media.
    func testSSDRAWInformationBothLanguages() throws {
        guard let fixtures = ProcessInfo.processInfo.environment["GYROCINE_RAW_METADATA_FILES"],
              let data = fixtures.data(using: .utf8),
              let clips = try JSONSerialization.jsonObject(with: data) as? [[String: String]], !clips.isEmpty else {
            throw XCTSkip("Provide GYROCINE_RAW_METADATA_FILES with file and codec fields")
        }
        for language in ["en", "zh-Hans"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "-AppleLanguages", "(\(language))", "-storageLocation", "外部 SSD"]
            app.launch()
            XCTAssertTrue(app.buttons["mediaOpen"].waitForExistence(timeout: 30))
            app.buttons["mediaOpen"].tap()
            for clip in clips {
                let file = try XCTUnwrap(clip["file"])
                let codec = try XCTUnwrap(clip["codec"])
                let row = app.buttons["mediaRow.\(file)"]
                XCTAssertTrue(row.waitForExistence(timeout: 15))
                row.tap()
                XCTAssertTrue(app.buttons["mediaInfo"].waitForExistence(timeout: 15))
                app.buttons["mediaInfo"].tap()
                XCTAssertTrue(app.staticTexts[codec].waitForExistence(timeout: 15))
                XCTAssertTrue(app.staticTexts["Embedded"].exists || app.staticTexts["已嵌入"].exists)
                XCTAssertTrue(app.staticTexts["2240 × 4224"].exists || app.staticTexts["4224 × 2240"].exists)
                controlScreenshot(app, "ssd-raw-info-\(file)-\(language)")
                app.swipeUp(velocity: .slow)
                controlScreenshot(app, "ssd-raw-settings-\(file)-\(language)")
                app.swipeUp(velocity: .slow)
                controlScreenshot(app, "ssd-raw-slate-\(file)-\(language)")
                app.buttons["mediaInformationDone"].tap()
                XCTAssertTrue(app.buttons["mediaInfo"].waitForExistence(timeout: 5))
                app.buttons["mediaPlayerDone"].tap()
                XCTAssertTrue(app.buttons["mediaDone"].waitForExistence(timeout: 5))
            }
            app.terminate()
        }
    }

    func testCapturedMovieInformation() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["mediaOpen"].waitForExistence(timeout: 25))
        app.buttons["mediaOpen"].tap()
        let row = app.buttons["mediaRow.UITEST_METADATA_DEVICE.mov"]
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        XCTAssertTrue(app.buttons["mediaInfo"].waitForExistence(timeout: 10)); app.buttons["mediaInfo"].tap()
        XCTAssertTrue(app.buttons["mediaInformationDone"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["H.265"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["已嵌入"].exists || app.staticTexts["Embedded"].exists)
        controlScreenshot(app, "device-metadata-video")
        app.swipeUp(velocity: .slow)
        controlScreenshot(app, "device-metadata-settings")
        app.buttons["mediaInformationDone"].tap()
        XCTAssertTrue(app.buttons["mediaInfo"].waitForExistence(timeout: 5))
        app.buttons["mediaPlayerDone"].tap()
        XCTAssertTrue(app.buttons["mediaDone"].waitForExistence(timeout: 5))
    }

    func testMediaInformationBothLanguages() {
        for language in ["zh-Hans", "en"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "-AppleLanguages", "(\(language))"]
            app.launch()
            XCTAssertTrue(app.buttons["mediaOpen"].waitForExistence(timeout: 25))
            app.buttons["mediaOpen"].tap()
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mediaRow.UITEST_METADATA")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.tap()
            XCTAssertTrue(app.buttons["mediaInfo"].waitForExistence(timeout: 10))
            app.buttons["mediaInfo"].tap()
            XCTAssertTrue(app.buttons["mediaInformationDone"].waitForExistence(timeout: 10))
            let label = language == "en" ? "Original video" : "原始视频"
            XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["H.264"].exists)
            controlScreenshot(app, "metadata-information-\(language)")
            for _ in 0..<3 {
                if app.staticTexts["5600 K"].isHittable { break }
                app.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(app.staticTexts["5600 K"].exists)
            XCTAssertTrue(app.staticTexts["1/60 s"].exists)
            controlScreenshot(app, "metadata-settings-\(language)")
            app.buttons["mediaInformationDone"].tap()
            XCTAssertTrue(app.buttons["mediaInfo"].waitForExistence(timeout: 5))
            app.buttons["mediaPlayerDone"].tap()
            XCTAssertTrue(app.buttons["mediaDone"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    func testExplicitColorSpaceMenuBothLanguages() {
        for language in ["zh-Hans", "en"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "-AppleLanguages", "(\(language))"]
            app.launch()
            XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 30))
            app.buttons["settingsOpen"].tap()
            let menu = app.buttons["colorSpaceMenu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 10))
            for _ in 0..<3 {
                menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                if app.buttons["colorSpaceOption.rec709"].waitForExistence(timeout: 3) { break }
            }
            XCTAssertTrue(app.buttons["colorSpaceOption.rec709"].exists)
            XCTAssertTrue(app.buttons["colorSpaceOption.rec2020HDR"].exists)
            XCTAssertTrue(app.buttons["colorSpaceOption.p3D65"].exists)
            XCTAssertFalse(app.buttons["colorSpaceOption.systemDefault"].exists)
            XCTAssertFalse(app.staticTexts["System Default"].exists)
            XCTAssertFalse(app.staticTexts["系统默认"].exists)
            controlScreenshot(app, "explicit-color-space-\(language)")
            app.terminate()
        }
    }

    func testProResAndColorMenus() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 30))
        app.buttons["settingsOpen"].tap()
        func select(_ menu: String, _ optionName: String) {
            let option = app.buttons[optionName]
            for _ in 0..<3 {
                let row = app.buttons[menu]
                XCTAssertTrue(row.waitForExistence(timeout: 5))
                row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                if option.waitForExistence(timeout: 3) {
                    if menu == "colorSpaceMenu" { XCTAssertFalse(app.buttons["colorSpaceOption.systemDefault"].exists) }
                    Thread.sleep(forTimeInterval: 0.5) // Native menu presentation animation.
                    let frame = option.frame
                    if frame.midX.isFinite && frame.width > 0 {
                        app.coordinate(withNormalizedOffset: .zero)
                            .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
                        Thread.sleep(forTimeInterval: 0.5)
                        return
                    }
                }
            }
            XCTFail("Menu option unavailable: \(optionName)")
        }
        for codec in ["ProRes 422 HQ", "ProRes 422", "ProRes 422 LT", "ProRes 422 Proxy"] {
            select("codecMenu", codec)
            for (id, label) in [("rec709", "Rec.709"), ("rec2020HDR", "Rec.2020 · HDR"), ("p3D65", "P3 D65")] {
                select("colorSpaceMenu", "colorSpaceOption.\(id)")
                let applied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", label),
                    object: app.buttons["colorSpaceMenu"])
                XCTAssertEqual(XCTWaiter.wait(for: [applied], timeout: 10), .completed)
                XCTAssertFalse(app.alerts.firstMatch.exists)
            }
        }
        controlScreenshot(app, "prores-color-settings")
        select("colorSpaceMenu", "colorSpaceOption.rec709")
        select("codecMenu", "H.265")
        app.buttons["captureSettingsClose"].tap()
        XCTAssertTrue(app.buttons["recordToggle"].waitForExistence(timeout: 5))
    }

    func testBuiltinLUTManagementChineseAndEnglish() {
        for (language, title, amber, group) in [
            ("zh-Hans", "LUT 管理", "暖阳 · Amber", "内置 LUT"),
            ("en", "LUT Management", "Amber", "Built-in LUTs")
        ] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "-AppleLanguages", "(\(language))"]
            app.launch()
            XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 25))
            func openManagement() {
                app.buttons["settingsOpen"].tap()
                let manage = app.buttons["settings.lutManagement"]
                for _ in 0..<6 where !manage.isHittable { app.swipeUp() }
                XCTAssertEqual(manage.label, title)
                manage.tap()
            }
            func setToggle(_ toggle: XCUIElement, _ on: Bool) {
                XCTAssertTrue(toggle.waitForExistence(timeout: 5))
                if (toggle.value as? String == "1") != on {
                    // Tap the leading edge of the actual switch, avoiding AssistiveTouch
                    // overlapping its trailing edge. The label is not tappable on iOS 26.
                    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.3)).tap()
                }
                let changed = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@", on ? "1" : "0"), object: toggle)
                XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
            }
            openManagement()
            XCTAssertTrue(app.staticTexts[group].exists)
            XCTAssertEqual(app.switches["lut.visible.builtin.amber"].label, amber)
            let builtin = app.switches["lut.visible.builtin.rec709"]
            setToggle(builtin, true)
            app.buttons["lut.managementDone"].tap(); app.buttons["captureSettingsClose"].tap()
            app.buttons["parameter.LUT"].tap(); app.buttons["lut.rec709"].tap()
            app.buttons["parameter.LUT"].tap()
            openManagement()
            setToggle(builtin, false)
            controlScreenshot(app, "builtin-lut-disabled-\(language)")
            app.buttons["lut.managementDone"].tap()
            XCTAssertEqual(app.switches["settings.lutBurn"].value as? String, "0")
            app.buttons["captureSettingsClose"].tap()
            app.buttons["parameter.LUT"].tap()
            XCTAssertFalse(app.buttons["lut.rec709"].exists)
            XCTAssertEqual(app.switches["lut.burn"].value as? String, "0")
            app.terminate(); app.launch()
            XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 25))
            openManagement(); setToggle(builtin, false); setToggle(builtin, true)
            app.buttons["lut.managementDone"].tap(); app.buttons["captureSettingsClose"].tap()
            app.buttons["parameter.LUT"].tap()
            XCTAssertTrue(app.buttons["lut.rec709"].exists)
            controlScreenshot(app, "builtin-lut-restored-\(language)")
            app.terminate()
        }
    }

    func testRealtimeLUTOnOffOnRecording() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)"]
        app.launch()
        let record = app.buttons["recordToggle"]
        XCTAssertTrue(record.waitForExistence(timeout: 25))
        for enabled in [true, false, true] {
            app.buttons["parameter.LUT"].tap()
            let burn = app.switches["lut.burn"]
            XCTAssertTrue(burn.waitForExistence(timeout: 5))
            if (burn.value as? String == "1") != enabled {
                burn.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
            XCTAssertEqual(burn.value as? String, enabled ? "1" : "0")
            app.buttons["parameter.LUT"].tap()
            record.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == 'Stop recording'"), object: record)], timeout: 15), .completed)
            Thread.sleep(forTimeInterval: 4)
            record.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "enabled == true AND label == 'Record'"), object: record)], timeout: 15), .completed)
            XCTAssertFalse(app.alerts.firstMatch.exists)
        }
    }

    func testLUTManagementAndBurnControls() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--lut-import-smoke", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 30))
        app.buttons["parameter.LUT"].tap()
        XCTAssertTrue(app.switches["lut.burn"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["lut.import"].exists)
        controlScreenshot(app, "lut-compact-realtime-controls")
        let burn = app.switches["lut.burn"]
        let before = burn.value as? String
        burn.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertNotEqual(burn.value as? String, before)
        burn.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(burn.value as? String, before)
        app.buttons["settingsOpen"].tap()
        let manage = app.buttons["settings.lutManagement"]
        for _ in 0..<5 where !manage.isHittable { app.swipeUp() }
        XCTAssertTrue(manage.isHittable); manage.tap()
        XCTAssertTrue(app.buttons["lut.import"].waitForExistence(timeout: 5))
        let item = app.switches["lut.visible.UITEST_PreviewRed"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        if item.value as? String == "1" { item.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(item.value as? String, "0")
        controlScreenshot(app, "lut-management-hidden")
        app.terminate()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 30))
        app.buttons["settingsOpen"].tap()
        for _ in 0..<5 where !manage.isHittable { app.swipeUp() }
        manage.tap()
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertEqual(item.value as? String, "0")
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap(); XCTAssertEqual(item.value as? String, "1")
        app.buttons["lut.import"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        controlScreenshot(app, "lut-management-enabled")
        app.terminate()
        app.launchArguments = ["--cleanup-lut-smoke", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 30))
    }

    func testPointFocusHoldAndRelease() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let focus = app.buttons["parameter.Focus"]
        XCTAssertTrue(focus.waitForExistence(timeout: 30))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.42)).tap()
        XCTAssertTrue(app.descendants(matching: .any)["focusFrameIndicator"].waitForExistence(timeout: 1))
        XCTAssertFalse(app.staticTexts["focusNotice"].exists)
        // Deliberately use two off-center locations to catch discarded points.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.42)).press(forDuration: 0.8)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "锁定"), object: focus)], timeout: 10) == .completed)
        let lockedHint = app.staticTexts["focusNotice"]
        XCTAssertTrue(lockedHint.waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["focusFrameIndicator"].exists)
        XCTAssertLessThan(lockedHint.frame.midX, app.frame.width * 0.45)
        controlScreenshot(app, "point-focus-held")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.58)).tap()
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "AF-C"), object: focus)], timeout: 10) == .completed)
        let autoHint = app.staticTexts["focusNotice"]
        XCTAssertTrue(autoHint.waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["focusFrameIndicator"].exists)
        XCTAssertGreaterThan(autoHint.frame.midX, app.frame.width * 0.55)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        controlScreenshot(app, "point-focus-released")
    }

    func testHEVCBitratePresetPersistsAcrossLaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 30))
        app.buttons["settingsOpen"].tap()
        let originalPreset = selectedHEVCBitratePreset(app)
        chooseHEVCBitratePreset("maximum", title: "最高", app: app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 30))
        app.buttons["settingsOpen"].tap()
        XCTAssertEqual(selectedHEVCBitratePreset(app), "maximum")
        chooseHEVCBitratePreset(originalPreset, title: bitrateTitle(originalPreset), app: app)
        app.buttons["captureSettingsClose"].tap()
    }

    func testHEVCBitratePresetsAndShortRecordings() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-storageLocation", "内部文件",
                               "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 30))
        app.buttons["settingsOpen"].tap()
        let originalCodec = app.buttons["codecMenu"].label
        if !originalCodec.contains("H.265") || originalCodec.contains("HQ") {
            app.buttons["codecMenu"].tap()
            app.buttons["H.265"].tap()
        }
        let originalPreset = selectedHEVCBitratePreset(app)
        for preset in ["compact", "quality", "maximum"] {
            chooseHEVCBitratePreset(preset, title: bitrateTitle(preset), app: app)
            controlScreenshot(app, "hevc-bitrate-\(preset)")
            app.buttons["captureSettingsClose"].tap()
            let record = app.buttons["recordToggle"]
            XCTAssertTrue(record.waitForExistence(timeout: 20))
            record.tap()
            XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label CONTAINS %@", "停止录制"), object: record)],
                timeout: 30) == .completed)
            Thread.sleep(forTimeInterval: 6)
            record.tap()
            XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "enabled == true AND label CONTAINS %@", "开始录制"), object: record)],
                timeout: 90) == .completed)
            XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
            print("HEVC_BITRATE_RECORDED \(preset)")
            app.buttons["settingsOpen"].tap()
        }
        chooseHEVCBitratePreset(originalPreset, title: bitrateTitle(originalPreset), app: app)
        if originalCodec.contains("HQ") || !originalCodec.contains("H.265") {
            app.buttons["codecMenu"].tap()
            let codec = originalCodec.contains("ProRes RAW HQ") ? "ProRes RAW HQ" :
                originalCodec.contains("ProRes RAW") ? "ProRes RAW" : "H.265 HQ"
            app.buttons[codec].tap()
        }
        app.buttons["captureSettingsClose"].tap()
    }

    private func bitrateTitle(_ preset: String) -> String {
        switch preset {
        case "compact": return "低"
        case "balanced": return "中"
        case "quality": return "高"
        default: return "最高"
        }
    }

    private func selectedHEVCBitratePreset(_ app: XCUIApplication) -> String {
        let label = app.buttons["hevcBitrateMenu"].label
        if label.contains("最高") { return "maximum" }
        if label.contains("高") { return "quality" }
        if label.contains("低") { return "compact" }
        return "balanced"
    }

    private func chooseHEVCBitratePreset(_ preset: String, title: String, app: XCUIApplication) {
        let menu = app.buttons["hevcBitrateMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        let option = app.buttons["hevcBitrateOption.\(preset)"]
        XCTAssertTrue(option.waitForExistence(timeout: 10))
        option.tap()
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", title), object: menu)], timeout: 15) == .completed)
    }

    func testMediaPlaybackVisualProbe() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["mediaOpen"].waitForExistence(timeout: 25))
        app.buttons["mediaOpen"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mediaRow.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.otherElements["mediaPlayer"].waitForExistence(timeout: 10))
        controlScreenshot(app, "player-open")
        let video = app.otherElements["mediaPlayer"]
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        controlScreenshot(app, "player-after-first-tap")
        Thread.sleep(forTimeInterval: 2)
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        controlScreenshot(app, "player-after-second-tap")
        let elapsed = app.staticTexts["Elapsed Time"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(Int(elapsed.label.split(separator: ":").last ?? "0") ?? 0, 0,
                             "The in-app player must advance after tapping the video")
    }

    func testLiveMenuQuiescenceProbe() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 25))
        app.buttons["settingsOpen"].tap()
        XCTAssertTrue(app.buttons["codecMenu"].waitForExistence(timeout: 10))
        controlScreenshot(app, "menu-before-open")
        app.buttons["codecMenu"].tap()
        controlScreenshot(app, "menu-after-open")
        XCTAssertTrue(app.buttons["H.265"].waitForExistence(timeout: 5))
    }

    // Run after physical-device QA to leave the camera in its normal capture configuration.
    func testRestoreQuickReleaseCameraDefaults() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 30))
        app.buttons["settingsOpen"].tap()
        if !app.buttons["codecMenu"].label.contains("H.265") || app.buttons["codecMenu"].label.contains("HQ") {
            app.buttons["codecMenu"].tap()
            app.buttons["H.265"].tap()
        }
        let resolution = app.buttons["resolutionMenu"]
        if !resolution.label.contains("3840×2160") {
            resolution.tap()
            app.buttons["4K · 3840×2160"].tap()
        }
        let fps = app.buttons["fpsMenu"]
        if !fps.label.contains("60.0") {
            fps.tap()
            app.buttons["fpsOption.60.0 fps"].tap()
        }
        let exposure = app.buttons["exposureTypeMenu"]
        if !exposure.label.contains("角度") {
            exposure.tap()
            app.buttons["exposureType.angle"].tap()
        }
        let storage = app.buttons["storageLocationMenu"]
        if !storage.isHittable { app.swipeUp() }
        if !storage.label.contains("专用视频存储") {
            storage.tap()
            app.buttons["专用视频存储"].tap()
        }
        app.buttons["captureSettingsClose"].tap()
        app.buttons["parameter.ISO"].tap()
        app.buttons["A"].tap()
        app.buttons["parameter.Shutter"].tap()
        app.buttons["A-Max"].tap()
        app.buttons["parameter.WB"].tap()
        app.buttons["wb.mode.Auto"].tap()
        XCTAssertTrue(app.buttons["captureSetupOpen"].label.contains("H.265"))
        XCTAssertTrue(app.buttons["captureSetupOpen"].label.contains("3840×2160"))
        XCTAssertTrue(app.buttons["captureSetupOpen"].label.contains("60.0fps"))
        controlScreenshot(app, "quick-release-defaults-restored")
    }
    func testProPurchaseEntryAndBilingualDisclosure() {
        let app = XCUIApplication()
        for language in ["en", "zh-Hans"] {
            app.launchArguments = ["--pro-ui-preview", "-AppleLanguages", "(\(language))",
                                   "-AppleLocale", language == "en" ? "en_US" : "zh_CN"]
            app.launch()
            XCTAssertTrue(app.navigationBars["GyroCine Pro"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.buttons["restorePro"].exists)
            XCTAssertFalse(app.buttons["redeemPro"].exists)
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@",
                language == "en" ? "2 minutes" : "2 分钟")).firstMatch.exists)
            controlScreenshot(app, "pro-\(language)")
            app.terminate()
        }
    }
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
    func testEnglishSettingsAndSlate() {
        let app = XCUIApplication()
        app.launchArguments = ["--settings-ui-preview", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-storageLocation", "外部 SSD"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        let storage = app.buttons["storageLocationMenu"]
        XCTAssertTrue(storage.waitForExistence(timeout: 10))
        XCTAssertTrue(storage.label.contains("External SSD"), storage.label)
        storage.tap()
        XCTAssertTrue(app.buttons["On My iPhone"].waitForExistence(timeout: 5))
        controlScreenshot(app, "english-storage-menu")
        app.terminate()
        app.launchArguments = ["--slate-ui-preview", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.textFields["slateDirector"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["slateDone"].label.contains("Done"))
        controlScreenshot(app, "english-slate")
    }

    func testEnglishDeviceScreens() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 40))
        app.buttons["settingsOpen"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        controlScreenshot(app, "device-english-settings")
        app.buttons["captureSettingsClose"].tap()
        app.buttons["parameter.LUT"].tap()
        XCTAssertTrue(app.buttons["lut.rec709"].waitForExistence(timeout: 10))
        controlScreenshot(app, "device-english-lut")
    }

    func testExternalSSDWirelessPreflight() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 40))
        app.buttons["settingsOpen"].tap()
        let storage = app.buttons["storageLocationMenu"]
        XCTAssertTrue(storage.waitForExistence(timeout: 15))
        XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
        let speed = app.buttons["ssdSpeedTest"]
        for _ in 0..<3 where !speed.isHittable { app.swipeUp() }
        XCTAssertTrue(speed.waitForExistence(timeout: 10))
        speed.tap()
        let start = app.buttons["ssdSpeedStart"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.staticTexts["Lowest second-half speed"].waitForExistence(timeout: 180), app.debugDescription)
        XCTAssertFalse(app.staticTexts["ssdSpeedError"].exists)
        controlScreenshot(app, "ssd-speed-wireless-preflight")
    }

    func testNativeMenusWithoutCamera() {
        let app = XCUIApplication()
        app.launchArguments = ["--settings-ui-preview", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let storage = app.buttons["storageLocationMenu"]
        XCTAssertTrue(storage.waitForExistence(timeout: 15))
        for x in [0.1, 0.5, 0.9] {
            storage.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
            let option = app.buttons["内部文件"]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            controlScreenshot(app, "storage-menu-\(x)")
            option.tap()
        }
        let naming = app.buttons["filenameTypePicker"]
        if !naming.isHittable { app.swipeUp() }
        naming.tap()
        XCTAssertTrue(app.buttons["简洁"].waitForExistence(timeout: 5))
        app.buttons["简洁"].tap()
        XCTAssertTrue(naming.label.contains("简洁"))
        naming.tap(); app.buttons["BMC"].tap()
        controlScreenshot(app, "settings-native-menu-result")
    }

    func testNativeSettingsMenusFullRow() throws {
        if ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil {
            throw XCTSkip("Requires physical camera formats for the codec menu")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 30))
        app.buttons["settingsOpen"].tap()
        let codec = app.buttons["codecMenu"]
        XCTAssertTrue(codec.waitForExistence(timeout: 10))
        for x in [0.1, 0.5, 0.9] {
            codec.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
            let option = app.buttons["H.265 HQ"]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.tap()
            XCTAssertTrue(app.buttons["captureSettingsClose"].exists)
        }
        codec.tap(); app.buttons["H.265"].tap()
        let storage = app.buttons["storageLocationMenu"]
        if !storage.isHittable { app.swipeUp() }
        for x in [0.1, 0.5, 0.9] {
            storage.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
            let option = app.buttons["内部文件"]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.tap()
            XCTAssertTrue(app.buttons["captureSettingsClose"].exists)
        }
        controlScreenshot(app, "native-settings-menus")
        app.buttons["captureSettingsClose"].tap()
        XCTAssertTrue(app.buttons["recordToggle"].waitForExistence(timeout: 5))
    }

    func test1080p240IsUnavailable() {
        let app = XCUIApplication()
        app.launchArguments = ["-storageLocation", "内部文件", "-AppleLanguages", "(zh-Hans)", "--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 30))
        app.buttons["settingsOpen"].tap()
        app.buttons["codecMenu"].tap()
        app.buttons["H.265"].tap()
        app.buttons["resolutionMenu"].tap()
        let resolution = app.buttons["1080p · 1920×1080"]
        XCTAssertTrue(resolution.waitForExistence(timeout: 10))
        resolution.tap()
        app.buttons["fpsMenu"].tap()
        XCTAssertFalse(app.buttons["240.0 fps"].exists)
        XCTAssertTrue(app.buttons["120.0 fps"].exists)
        controlScreenshot(app, "1080p-fps-capped-at-120")
    }

    func testSlateForm() {
        let app = XCUIApplication()
        app.launchArguments = ["--slate-ui-preview", "-AppleLanguages", "(zh-Hans)", "-filenameType", "BMC"]
        app.launch()
        let director = app.textFields["slateDirector"]
        XCTAssertTrue(director.waitForExistence(timeout: 15))
        director.tap(); director.typeText("QA Director")
        XCTAssertTrue(app.textFields["slateProduction"].exists)
        XCTAssertTrue(app.textFields["slateCinematographer"].exists)
        XCTAssertFalse(app.buttons["slateGoodTake"].exists)
        XCTAssertGreaterThan(app.buttons["slateDone"].frame.midX, app.frame.midX)
        controlScreenshot(app, "slate-project-fields")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["slateFilenamePreview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["slateFilenamePreview"].label.contains("_C"))
        controlScreenshot(app, "slate-clip-fields")
        app.terminate(); app.launch()
        XCTAssertTrue(director.waitForExistence(timeout: 15))
        XCTAssertEqual(director.value as? String, "QA Director")
    }

    func testSlatePanelAndRecording() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-storageLocation", "内部文件", "-filenameType", "BMC"]
        app.launch()
        XCTAssertTrue(app.buttons["slateOpen"].waitForExistence(timeout: 30))
        app.buttons["slateOpen"].tap()
        let director = app.textFields["slateDirector"]
        XCTAssertTrue(director.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["slateProduction"].exists)
        XCTAssertTrue(app.textFields["slateCinematographer"].exists)
        XCTAssertGreaterThan(app.buttons["slateDone"].frame.midX, app.frame.midX)
        controlScreenshot(app, "slate-single-page")
        app.buttons["slateDone"].tap()
        app.buttons["settingsOpen"].tap()
        app.swipeUp()
        XCTAssertTrue(app.otherElements["filenameTypePicker"].exists || app.buttons["filenameTypePicker"].exists)
        controlScreenshot(app, "slate-naming-setting")
        app.buttons["captureSettingsClose"].tap()
        let record = app.buttons["recordToggle"]
        XCTAssertTrue(record.isEnabled)
        record.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '停止录制'"), object: record)], timeout: 20), .completed)
        XCTAssertFalse(app.buttons["slateOpen"].isEnabled)
        Thread.sleep(forTimeInterval: 3)
        record.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND NOT (label CONTAINS '停止录制')"), object: record)], timeout: 60), .completed)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    #if !targetEnvironment(simulator)
    func testCaptureButtonsAndInterfacePolish() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-storageLocation", "内部文件", "-outputFormat", "SonyMov",
                               "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let record = app.buttons["recordToggle"]
        XCTAssertTrue(record.waitForExistence(timeout: 25))
        selectControlCodec("H.265", app: app)
        XCTAssertTrue(app.staticTexts["storageRemaining"].exists)
        app.buttons["settingsOpen"].tap()
        let close = app.buttons["captureSettingsClose"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(close.frame.midX, app.frame.midX)
        app.swipeUp()
        XCTAssertTrue(app.switches["rulerHapticsToggle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["rulerHapticsToggle"].label.contains("震动反馈"))
        XCTAssertFalse(app.switches["调试"].exists)
        XCUIDevice.shared.press(.volumeUp)
        XCTAssertFalse(record.label.contains("停止录制"))
        controlScreenshot(app, "settings-cleaned")
        close.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: record)], timeout: 20), .completed)
        XCUIDevice.shared.press(.volumeUp)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS '停止录制'"), object: record)], timeout: 20), .completed)
        Thread.sleep(forTimeInterval: 3)
        XCUIDevice.shared.press(.volumeDown)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true AND NOT (label CONTAINS '停止录制')"), object: record)], timeout: 60), .completed)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        app.buttons["mediaOpen"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mediaRow.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["mediaSaveSelected"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["mediaSaveSelected"].label.contains("保存相册"))
        XCTAssertLessThan(app.buttons["mediaShareSelected"].frame.maxX, app.buttons["mediaSaveSelected"].frame.minX)
        XCTAssertLessThan(app.buttons["mediaSaveSelected"].frame.maxX, app.buttons["mediaDeleteSelected"].frame.minX)
        controlScreenshot(app, "media-spaced-actions")
    }

    #endif
    func testSSDWriterBufferFailureThenRetry() {
        let app = XCUIApplication()
        app.launchArguments = ["--raw-ssd-smoke", "--ssd-matrix", "--ssd-fps=30",
            "--ssd-duration=8", "--ssd-verify-decode", "--writer-block-first-recording",
            "-storageLocation", "外部 SSD", "-debugEnabled", "YES", "-outputFormat", "SonyMov"]
        app.launch()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 40))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(
            format: "label CONTAINS '10 帧' OR label CONTAINS[c] 'buffer' OR label CONTAINS[c] 'writing'"
        )).firstMatch.exists,
                      alert.debugDescription)
        controlScreenshot(app, "ssd-buffer-overflow")
        let dismiss = alert.buttons["确定"].exists ? alert.buttons["确定"] : alert.buttons["OK"]
        dismiss.tap()
        let record = app.buttons["recordToggle"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: record)], timeout: 40), .completed)
        // Retry inside the same app process. Only the first writer has injected backpressure.
        record.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS '停止录制' OR label CONTAINS[c] 'stop'"), object: record)], timeout: 30), .completed)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true AND NOT (label CONTAINS '停止录制' OR label CONTAINS[c] 'stop')"), object: record)], timeout: 60), .completed)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
        controlScreenshot(app, "ssd-retry-after-buffer-overflow")
    }

    func testSSDHotplugThenRetryInSameProcess() throws {
        guard ProcessInfo.processInfo.environment["GYROCINE_RUN_SSD_HOTPLUG"] == "1" else {
            throw XCTSkip("Requires a person to unplug and reinsert the SSD during recording")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--raw-writer-integrated-auto", "--writer-ssd", "--ssd-matrix",
            "--ssd-duration=240", "--writer-duration=240", "-storageLocation", "外部 SSD", "-debugEnabled", "YES",
            "-outputFormat", "SonyMov"]
        app.launch()
        let record = app.buttons["recordToggle"]
        let ssd = app.staticTexts["status.SSD"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == 'connected'"), object: ssd)], timeout: 30), .completed)
        let recording = NSPredicate(format: "label CONTAINS '停止录制' OR label CONTAINS[c] 'stop'")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: recording, object: record)],
                                  timeout: 35), .completed)
        print("SSD_HOTPLUG_READY_TO_UNPLUG")
        controlScreenshot(app, "ssd-hotplug-recording")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == 'disconnected'"), object: ssd)], timeout: 180), .completed)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "NOT (label CONTAINS '停止录制' OR label CONTAINS[c] 'stop')"),
            object: record)], timeout: 65), .completed)
        controlScreenshot(app, "ssd-hotplug-interrupted")
        let alert = app.alerts.firstMatch
        if alert.exists {
            let dismiss = alert.buttons["确定"].exists ? alert.buttons["确定"] : alert.buttons["OK"]
            if dismiss.exists { dismiss.tap() }
        }
        print("SSD_HOTPLUG_READY_TO_REINSERT")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == 'connected'"), object: ssd)], timeout: 150), .completed)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: record)], timeout: 30), .completed)
        record.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: recording, object: record)],
                                  timeout: 30), .completed)
        Thread.sleep(forTimeInterval: 6)
        record.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true AND NOT (label CONTAINS '停止录制' OR label CONTAINS[c] 'stop')"),
            object: record)], timeout: 70), .completed)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
        controlScreenshot(app, "ssd-hotplug-recovered")
    }
    func testQuickCaptureAndMediaCards() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["captureSetupOpen"].waitForExistence(timeout: 25))
        app.buttons["captureSetupOpen"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "quickLens.")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["codecMenu"].exists)
        XCTAssertTrue(app.buttons["resolutionMenu"].exists)
        XCTAssertTrue(app.buttons["fpsMenu"].exists)
        controlScreenshot(app, "quick-capture-card")
        app.buttons["captureSettingsClose"].tap()
        app.buttons["mediaOpen"].tap()
        XCTAssertTrue(app.scrollViews["mediaGrid"].waitForExistence(timeout: 5))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mediaRow."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        controlScreenshot(app, "media-preview-cards")
        let first = rows.firstMatch
        first.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["mediaShareSelected"].isEnabled)
        XCTAssertTrue(app.buttons["mediaDeleteSelected"].isEnabled)
        // AssistiveTouch can cover the right side of this button on a physical phone.
        app.buttons["mediaDeleteSelected"].coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        controlScreenshot(app, "media-delete-confirmation")
        print("MEDIA_DELETE_UI \(app.debugDescription)")
        let confirmDelete = app.buttons["删除文件"].exists ? app.buttons["删除文件"] : app.buttons["Delete file"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5))
        let cancelDelete = app.buttons["取消"].exists ? app.buttons["取消"] : app.buttons["Cancel"]
        cancelDelete.tap() // Keep existing user recordings.
        app.buttons["mediaShareSelected"].tap()
        Thread.sleep(forTimeInterval: 2)
        controlScreenshot(app, "media-share-selection")
        // Do not select a recipient or send anything.
    }
    func testImmediateLensSwitchAndPlayback() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["captureSetupOpen"].waitForExistence(timeout: 25))
        app.buttons["captureSetupOpen"].tap()
        let lenses = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "quickLens."))
        XCTAssertTrue(lenses.firstMatch.waitForExistence(timeout: 10))
        print("QUICK_LENSES \(lenses.allElementsBoundByIndex.map(\.identifier))")
        let wide = lenses.matching(NSPredicate(format: "label == %@", "1×")).firstMatch
        let tele = lenses.matching(NSPredicate(format: "label == %@", "4×")).firstMatch
        XCTAssertTrue(wide.exists); XCTAssertTrue(tele.exists)
        for _ in 0..<3 {
            for lens in [tele, wide] {
                XCTAssertTrue(lens.waitForExistence(timeout: 10))
                lens.tap()
                XCTAssertTrue(NSPredicate(format: "value == %@ AND enabled == true", "selected")
                    .evaluate(with: lens) || XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "value == %@ AND enabled == true", "selected"),
                        object: lens)], timeout: 20) == .completed)
                XCTAssertTrue(app.buttons["codecMenu"].isEnabled)
            }
        }
        app.buttons["codecMenu"].tap()
        let rawOption = app.buttons["ProRes RAW"]
        if !rawOption.waitForExistence(timeout: 5) {
            controlScreenshot(app, "codec-after-lens-switch-missing-raw")
            print("CODEC_AFTER_LENS_SWITCH \(app.debugDescription)")
        }
        XCTAssertTrue(rawOption.exists)
        app.buttons["ProRes RAW"].tap()
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "ProRes RAW"),
            object: app.buttons["codecMenu"])], timeout: 15) == .completed)
        for lens in [tele, wide, tele, wide] {
            lens.tap()
            XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@ AND enabled == true", "selected"),
                object: lens)], timeout: 20) == .completed)
        }
        controlScreenshot(app, "lens-switch-immediate-completed")
        app.buttons["captureSettingsClose"].tap()
        app.buttons["mediaOpen"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mediaRow.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        Thread.sleep(forTimeInterval: 2)
        print("PLAYER_UI \(app.debugDescription)")
        controlScreenshot(app, "stable-playback-open")
        let video = app.otherElements["mediaPlayer"]
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 2)
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        controlScreenshot(app, "stable-playback-running")
        print("PLAYER_AFTER \(app.debugDescription)")
        let elapsed = app.staticTexts["Elapsed Time"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(Int(elapsed.label.split(separator: ":").last ?? "0") ?? 0, 0,
                             "Playback must advance despite live camera parameter updates")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mediaSave.")).firstMatch.exists)
    }

    func testBundledLUTLooks() throws {
        #if !DEBUG
        throw XCTSkip("Uses the existing Debug RAW capture harness to avoid system-menu automation delays.")
        #else
        let app = XCUIApplication()
        app.launchArguments = ["--raw-writer-integrated-auto", "--writer-60", "--writer-short", "-previewLUTEnabled", "YES", "-previewLUTLook", "rec709"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 25))
        Thread.sleep(forTimeInterval: 12)
        app.buttons["parameter.LUT"].tap()
        let status = app.staticTexts["lut.status"]
        let carousel = app.scrollViews["lut.carousel"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Rec.709'"), object: status)], timeout: 15), .completed)
        for name in ["Amber", "Fade", "Neon", "Film", "Portrait"] {
            carousel.swipeLeft()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", name), object: status)], timeout: 15), .completed)
            controlScreenshot(app, "lut-look-\(name)")
        }
        XCTAssertFalse(app.alerts.firstMatch.exists)
        #endif
    }
    func testLUTPreviewAndRecording() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 25))
        app.buttons["parameter.LUT"].tap()
        XCTAssertFalse(app.buttons["lut.rec709"].isEnabled)
        app.buttons["parameter.LUT"].tap()
        app.buttons["settingsOpen"].tap()
        app.buttons["storageLocationMenu"].tap()
        app.buttons["专用视频存储"].tap()
        app.buttons["完成"].tap()
        selectControlCodec("ProRes RAW", app: app)
        app.buttons["parameter.LUT"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["lut.rec709"])], timeout: 20), .completed)
        app.buttons["lut.rec709"].tap()
        let status = app.staticTexts["lut.status"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Rec.709 · 仅预览"), object: status)], timeout: 15), .completed)
        controlScreenshot(app, "lut-on-raw")
        app.buttons["lut.off"].tap(); controlScreenshot(app, "lut-off-raw")
        app.buttons["lut.rec709"].tap()
        app.buttons["parameter.LUT"].tap()
        // Record at 60 fps, toggle only the renderer while the movie is running.
        let record = app.buttons["recordToggle"]
        XCTAssertTrue(record.isEnabled)
        record.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '停止录制'"), object: record)], timeout: 25), .completed)
        Thread.sleep(forTimeInterval: 3)
        app.buttons["parameter.LUT"].tap()
        app.buttons["lut.off"].tap(); app.buttons["lut.rec709"].tap()
        Thread.sleep(forTimeInterval: 3)
        app.buttons["parameter.LUT"].tap(); record.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND NOT (label CONTAINS '停止录制')"), object: record)], timeout: 60), .completed)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        app.buttons["parameter.LUT"].tap()
        XCTAssertTrue(status.label.contains("Rec.709"))
        controlScreenshot(app, "lut-after-record")
        app.buttons["parameter.Lens"].tap(); app.buttons["lens.0.5×"].tap()
        Thread.sleep(forTimeInterval: 3)
        app.buttons["parameter.LUT"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Rec.709 · 仅预览"), object: status)], timeout: 15), .completed)
        controlScreenshot(app, "lut-ultrawide")
        app.buttons["parameter.Lens"].tap(); app.buttons["lens.1×"].tap()
        Thread.sleep(forTimeInterval: 3)
        selectControlCodec("H.265", app: app)
        app.buttons["parameter.LUT"].tap()
        XCTAssertFalse(app.buttons["lut.rec709"].isEnabled)
        app.buttons["lut.off"].tap()
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }
    func testLUTCarousel() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 25))
        selectControlCodec("ProRes RAW", app: app)
        app.buttons["parameter.LUT"].tap()
        let carousel = app.scrollViews["lut.carousel"]
        XCTAssertTrue(carousel.waitForExistence(timeout: 5))
        let status = app.staticTexts["lut.status"]
        // Scroll selection must work without tapping a card.
        carousel.swipeRight()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '已关闭'"), object: status)], timeout: 5), .completed)
        carousel.swipeLeft()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Rec.709 · 仅预览"), object: status)], timeout: 15), .completed)
        controlScreenshot(app, "lut-final-carousel")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Rec.709 · 仅预览"), object: status)], timeout: 20), .completed)
        app.buttons["parameter.LUT"].tap(); app.buttons["parameter.LUT"].tap()
        XCTAssertTrue(status.label.contains("Rec.709"))
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }
    func testLUTHighRateAndHQ() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 25))
        app.buttons["settingsOpen"].tap()
        app.buttons["storageLocationMenu"].tap(); app.buttons["专用视频存储"].tap()
        app.buttons["完成"].tap()
        for (codec, rate) in [("ProRes RAW", "120.0 fps"), ("ProRes RAW HQ", "30.0 fps")] {
            selectControlCodec(codec, app: app)
            app.buttons["settingsOpen"].tap(); tapFPSOption(rate, in: app); app.buttons["完成"].tap()
            app.buttons["parameter.LUT"].tap(); app.buttons["lut.rec709"].tap()
            let status = app.staticTexts["lut.status"]
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Rec.709 · 仅预览"), object: status)], timeout: 20), .completed)
            controlScreenshot(app, "lut-\(codec)-\(rate)")
            app.buttons["parameter.LUT"].tap()
            let record = app.buttons["recordToggle"]
            record.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '停止录制'"), object: record)], timeout: 25), .completed)
            Thread.sleep(forTimeInterval: 5)
            record.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND NOT (label CONTAINS '停止录制')"), object: record)], timeout: 60), .completed)
            XCTAssertFalse(app.alerts.firstMatch.exists)
        }
    }
    /// Runs against Release without any RAW experiment launch flags.
    func testReleaseDedicatedRAWRecording() {
        let app = XCUIApplication()
        app.launchArguments = ["-storageLocation", "专用视频存储", "-outputFormat", "SonyMov"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 20))
        app.buttons["settingsOpen"].tap()
        if !app.buttons["codecMenu"].label.contains("ProRes RAW") || app.buttons["codecMenu"].label.contains("HQ") {
            app.buttons["codecMenu"].tap()
            app.buttons["ProRes RAW"].tap()
        }
        app.buttons["完成"].tap()
        let record = app.buttons["recordToggle"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: record)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        record.tap()
        let started = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "停止录制"), object: record)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 20), .completed, app.debugDescription)
        Thread.sleep(forTimeInterval: 5)
        record.tap()
        let saved = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "IMU")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 30))
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND NOT (label CONTAINS %@)", "停止录制"), object: record)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 30), .completed)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
    }

    func testStorageReclaimDedicated() { storageCycle(location: "专用视频存储", codec: "ProRes RAW") }
    func testStorageReclaimInternal() { storageCycle(location: "内部文件", codec: "H.265") }
    func testStorageReclaimAfterModeSwitch() { storageCycle(location: "专用视频存储", codec: "ProRes RAW", deleteInInternal: true) }

    private func storageCycle(location: String, codec: String, deleteInInternal: Bool = false) {
        let app = XCUIApplication()
        app.launchArguments = ["-storageLocation", location, "-outputFormat", "SonyMov",
                               "--ui-testing", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 20))
        app.buttons["settingsOpen"].tap()
        if !app.buttons["codecMenu"].label.contains(codec) || app.buttons["codecMenu"].label.contains("HQ") {
            app.buttons["codecMenu"].tap(); app.buttons[codec].tap()
        }
        let entry = app.buttons["proVideoStorageSettings"]
        XCTAssertEqual(entry.exists, location == "专用视频存储")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "storage-settings-\(location)"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["完成"].tap()
        app.buttons["mediaOpen"].tap()
        let before = Set(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mediaRow.'")).allElementsBoundByIndex.map(\.identifier))
        app.buttons["完成"].tap()
        Thread.sleep(forTimeInterval: 3)
        let capacityBefore = app.staticTexts["storageRemaining"].label
        let record = app.buttons["recordToggle"]
        XCTAssertTrue(record.isEnabled)
        record.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '停止录制'"), object: record)], timeout: 20), .completed)
        Thread.sleep(forTimeInterval: 30)
        record.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND NOT (label CONTAINS '停止录制')"), object: record)], timeout: 60), .completed)
        Thread.sleep(forTimeInterval: 3)
        let capacityRecorded = app.staticTexts["storageRemaining"].label
        if deleteInInternal {
            app.terminate(); app.launchArguments = ["-storageLocation", "内部文件"]; app.launch()
            XCTAssertTrue(app.buttons["mediaOpen"].waitForExistence(timeout: 20))
        }
        app.buttons["mediaOpen"].tap()
        let after = Set(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mediaRow.'")).allElementsBoundByIndex.map(\.identifier))
        let added = after.subtracting(before)
        XCTAssertEqual(added.count, 1, "Delete only the one recording created by this test")
        guard let id = added.first, added.count == 1 else { return }
        print("STORAGE_TEST_FILE \(id)")
        app.buttons[id].press(forDuration: 1.1)
        app.buttons["mediaDeleteSelected"].tap(); app.buttons["删除文件"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons[id])], timeout: 30), .completed)
        app.buttons["完成"].tap()
        if deleteInInternal {
            Thread.sleep(forTimeInterval: 10)
            app.terminate(); app.launchArguments = ["-storageLocation", location]; app.launch()
            XCTAssertTrue(app.buttons["recordToggle"].waitForExistence(timeout: 20))
        }
        Thread.sleep(forTimeInterval: 10)
        let capacityDeleted = app.staticTexts["storageRemaining"].label
        let result = "mode=\(location) crossMode=\(deleteInInternal) before=\(capacityBefore) recorded=\(capacityRecorded) deleted=\(capacityDeleted) file=\(id)"
        print("STORAGE_CAPACITY \(result)")
        if location == "专用视频存储" {
            func gigabytes(_ label: String) -> Double? {
                guard let range = label.range(of: #"[0-9]+\.[0-9]+"#, options: .regularExpression) else { return nil }
                return Double(label[range])
            }
            if let start = gigabytes(capacityBefore), let used = gigabytes(capacityRecorded), let restored = gigabytes(capacityDeleted) {
                XCTAssertLessThan(used, start - 0.1, "RAW recording must consume reserved capacity")
                XCTAssertGreaterThanOrEqual(restored + 0.01, start - 0.1, "Deletion must replenish reserved capacity")
            } else { XCTFail("Missing capacity readout") }
        }
        let attachment = XCTAttachment(string: result); attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
        XCTAssertTrue(app.buttons["recordToggle"].isEnabled)
    }

    func testAuthorizeConnectedSSD() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 20))
        app.buttons["settingsOpen"].tap()
        let storage = app.buttons["storageLocationMenu"]
        if !storage.isHittable { app.swipeUp() }
        XCTAssertTrue(storage.waitForExistence(timeout: 10)); storage.tap()
        app.buttons["外部 SSD"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 5) {
            print("SSD_PERMISSION \(springboard.alerts.firstMatch.debugDescription)")
            let allow = springboard.alerts.firstMatch.buttons["允许"]
            if allow.exists { allow.tap() }
        }
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "外部 SSD"), object: storage)], timeout: 15) == .completed)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        controlScreenshot(app, "authorized-ssd")
    }

    func testStorageMissingSSD() {
        let app = XCUIApplication(); app.launchArguments = ["-storageLocation", "外部 SSD"]; app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 20))
        app.buttons["settingsOpen"].tap()
        XCTAssertFalse(app.buttons["proVideoStorageSettings"].exists)
        print("SSD_SETTINGS_UI \(app.debugDescription)")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "ssd-settings"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["完成"].tap()
        app.buttons["recordToggle"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        print("SSD_ALERT \(app.alerts.firstMatch.debugDescription)")
        XCTAssertTrue(app.alerts.firstMatch.staticTexts.containing(NSPredicate(format: "label CONTAINS 'SSD'")).firstMatch.exists)
    }

    func testStorageSystemSettingsEntry() {
        let app = XCUIApplication(); app.launchArguments = ["-storageLocation", "专用视频存储"]; app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 20))
        app.buttons["settingsOpen"].tap()
        app.buttons["proVideoStorageSettings"].tap()
        Thread.sleep(forTimeInterval: 3)
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertEqual(settings.state, .runningForeground)
        print("STORAGE_SYSTEM_UI \(settings.debugDescription)")
        let configure = settings.cells["CAM_VCC"]
        XCTAssertTrue(configure.waitForExistence(timeout: 5))
        if !configure.isHittable { settings.swipeUp() }
        configure.tap()
        Thread.sleep(forTimeInterval: 3)
        print("STORAGE_ALLOCATION_UI \(settings.debugDescription)")
        let shot = XCTAttachment(screenshot: settings.screenshot()); shot.name = "system-storage-settings"; shot.lifetime = .keepAlways; add(shot)
    }

    private func controlApp() -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["-storageLocation", "内部文件", "-outputFormat", "SonyMov", "-AppleLanguages", "(zh-Hans)", "--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 20))
        return app
    }
    private func selectControlCodec(_ name: String, app: XCUIApplication) {
        app.buttons["settingsOpen"].tap()
        if !app.buttons["codecMenu"].label.contains(name) || app.buttons["codecMenu"].label.contains("HQ") {
            for _ in 0..<2 {
                app.buttons["codecMenu"].tap()
                let option = app.buttons[name]
                if option.waitForExistence(timeout: 3) {
                    let frame = option.frame
                    app.coordinate(withNormalizedOffset: .zero)
                        .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
                    break
                }
            }
            XCTAssertTrue(app.buttons["codecMenu"].label.contains(name))
        }
        app.buttons["captureSettingsClose"].tap()
    }
    private func dragControl(_ app: XCUIApplication, left: Bool = true) {
        let ruler = app.otherElements["parameterRuler"]
        XCTAssertTrue(ruler.waitForExistence(timeout: 3))
        ruler.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.85 : 0.15, dy: 0.25))
            .press(forDuration: 0.1, thenDragTo: ruler.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.15 : 0.85, dy: 0.25)))
    }
    private func controlScreenshot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    func testStartupDefaultsAndAllRulers() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 20))
        for pass in 0..<2 {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label CONTAINS '1×'"),
                object: app.buttons["parameter.Lens"])], timeout: 20), .completed)
            app.buttons["settingsOpen"].tap()
            XCTAssertTrue(app.buttons["codecMenu"].label.contains("H.265"))
            XCTAssertFalse(app.buttons["codecMenu"].label.contains("HQ"))
            XCTAssertTrue(app.buttons["resolutionMenu"].label.contains("3840×2160"))
            XCTAssertTrue(app.buttons["fpsMenu"].label.contains("60.0 fps"))
            XCTAssertTrue(app.buttons["exposureTypeMenu"].label.contains("角度"))
            XCTAssertTrue(app.buttons["storageLocationMenu"].label.contains("内部文件"))
            for _ in 0..<4 where !app.switches["rulerHapticsToggle"].isHittable { app.swipeUp() }
            XCTAssertEqual(app.switches["rulerHapticsToggle"].value as? String, "1")
            app.buttons["完成"].tap()
            app.buttons["parameter.Shutter"].tap()
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '最长 1/120'")).firstMatch.exists)
            XCTAssertTrue(app.buttons["A-Max"].exists)
            if pass == 1 { break }
            dragControl(app); Thread.sleep(forTimeInterval: 3)
            for parameter in ["ISO", "WB", "Focus", "EV"] {
                app.buttons["parameter.\(parameter)"].tap()
                if parameter == "ISO" { app.buttons["M"].tap() }
                if parameter == "WB" { app.buttons["wb.mode.Manual"].tap() }
                if parameter == "Focus" { app.buttons["MF"].tap() }
                if parameter == "EV" {
                    app.buttons["parameter.ISO"].tap(); app.buttons["A"].tap()
                    app.buttons["parameter.EV"].tap()
                }
                dragControl(app); Thread.sleep(forTimeInterval: 3)
            }
            app.buttons["parameter.Lens"].tap(); app.buttons["lens.0.5×"].tap()
            Thread.sleep(forTimeInterval: 3)
            app.terminate(); app.launch()
            XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 20))
            XCTAssertTrue(app.buttons["parameter.WB"].label.contains("A"))
            XCTAssertTrue(app.buttons["parameter.Focus"].label.contains("AF-C"))
            XCTAssertTrue(app.buttons["parameter.EV"].label.contains("+0.0"))
        }
        controlScreenshot(app, "startup-defaults")
    }

    func testRAWWhiteBalanceAutoLockChoice() {
        let app = controlApp()
        for codec in ["ProRes RAW", "ProRes RAW HQ"] {
            selectControlCodec(codec, app: app)
            Thread.sleep(forTimeInterval: 2)
            app.buttons["parameter.WB"].tap()
            XCTAssertTrue(app.buttons["wb.mode.Auto-L"].exists)
            XCTAssertTrue(app.buttons["wb.mode.Manual"].exists)
            XCTAssertFalse(app.buttons["wb.mode.Auto"].exists)
            app.buttons["wb.mode.Auto-L"].tap()
            XCTAssertTrue(app.buttons["parameter.WB"].label.contains("A"))
            controlScreenshot(app, "raw-wb-autol-\(codec)")
            XCTAssertFalse(app.alerts.firstMatch.exists)
        }
        selectControlCodec("H.265", app: app)
        app.buttons["parameter.WB"].tap()
        XCTAssertTrue(app.buttons["wb.mode.Auto-L"].exists)
        XCTAssertTrue(app.buttons["wb.mode.Auto"].exists)
    }

    func testControlsDefaultLensAndRAWStoragePrompt() {
        let app = controlApp()
        XCTAssertTrue(app.buttons["parameter.Lens"].label.contains("1×"), app.debugDescription)
        selectControlCodec("ProRes RAW", app: app)
        app.buttons["recordToggle"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS '专用视频存储' AND label CONTAINS 'SSD'")).firstMatch.exists)
        XCTAssertTrue(app.alerts.buttons["设置存储"].exists)
        controlScreenshot(app, "friendly-raw-storage")
        app.alerts.buttons["设置存储"].tap()
        XCTAssertTrue(app.buttons["storageLocationMenu"].waitForExistence(timeout: 5))
    }
    func testControlsWhiteBalanceModesRecording() {
        let app = controlApp(); selectControlCodec("H.265", app: app)
        for mode in ["Auto-L", "Auto", "Manual"] {
            app.buttons["mediaOpen"].tap()
            let before = Set(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mediaRow.'")).allElementsBoundByIndex.map(\.identifier))
            app.buttons["完成"].tap()
            app.buttons["parameter.WB"].tap()
            XCTAssertTrue(app.buttons["wb.mode.\(mode)"].waitForExistence(timeout: 5))
            app.buttons["wb.mode.\(mode)"].tap()
            controlScreenshot(app, "white-balance-\(mode)")
            app.buttons["recordToggle"].tap()
            let rec = app.buttons["recordToggle"]
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '停止录制'"), object: rec)], timeout: 20), .completed)
            Thread.sleep(forTimeInterval: 4)
            app.buttons["recordToggle"].tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND NOT (label CONTAINS '停止录制')"), object: rec)], timeout: 40), .completed)
            XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
            Thread.sleep(forTimeInterval: 1)
            print("WB_MODE_FINISHED \(mode) \(app.buttons["parameter.WB"].label)")
            app.buttons["mediaOpen"].tap()
            let after = Set(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mediaRow.'")).allElementsBoundByIndex.map(\.identifier))
            let added = after.subtracting(before); XCTAssertEqual(added.count, 1)
            if let id = added.first, added.count == 1 {
                print("WB_TEST_FILE \(mode) \(id)")
                app.buttons[id].press(forDuration: 1.1)
                app.buttons["mediaDeleteSelected"].tap(); app.buttons["删除文件"].tap()
            }
            app.buttons["完成"].tap()
        }
    }
    func testControlsAngleEVAndHaptics() {
        let app = controlApp(); selectControlCodec("H.265", app: app)
        app.buttons["settingsOpen"].tap(); tapExposureType("angle", in: app)
        XCTAssertTrue(app.buttons["exposureTypeMenu"].label.contains("角度"))
        XCTAssertFalse(app.buttons["exposureTypeMenu"].label.contains("快门"))
        for _ in 0..<4 where !app.switches["rulerHapticsToggle"].isHittable { app.swipeUp() }
        let toggle = app.switches["rulerHapticsToggle"]; XCTAssertTrue(toggle.isHittable)
        if toggle.value as? String != "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["完成"].tap()
        app.buttons["parameter.Shutter"].tap()
        controlScreenshot(app, "angle-time-scale")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '°' AND label CONTAINS '1/'")).firstMatch.exists)
        dragControl(app)
        Thread.sleep(forTimeInterval: 3)
        app.buttons["parameter.EV"].tap()
        dragControl(app)
        Thread.sleep(forTimeInterval: 1)
        print("EV_CHANGED \(app.buttons["parameter.EV"].label)")
        XCTAssertFalse(app.buttons["parameter.EV"].label.contains("+0.0"))
        controlScreenshot(app, "six-parameter-ev")
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }
    func testControlsManualSurvivesLensAndFPS() {
        let app = controlApp(); selectControlCodec("H.265", app: app)
        app.buttons["settingsOpen"].tap(); tapExposureType("speed", in: app); tapFPSOption("30.0 fps", in: app); app.buttons["captureSettingsClose"].tap()
        app.buttons["parameter.Shutter"].tap(); app.buttons["M"].tap()
        dragControl(app, left: false)
        Thread.sleep(forTimeInterval: 3)
        app.buttons["parameter.ISO"].tap(); dragControl(app)
        Thread.sleep(forTimeInterval: 3)
        app.buttons["parameter.WB"].tap(); app.buttons["wb.mode.Manual"].tap()
        dragControl(app)
        Thread.sleep(forTimeInterval: 3)
        let shutter = app.buttons["parameter.Shutter"].label
        let iso = app.buttons["parameter.ISO"].label
        let wb = app.buttons["parameter.WB"].label
        print("MANUAL_BASE \(shutter) \(iso) \(wb)")
        for lens in ["0.5×", "1×"] {
            app.buttons["parameter.Lens"].tap()
            app.buttons["lens.\(lens)"].tap()
            Thread.sleep(forTimeInterval: 3)
            XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
            print("MANUAL_LENS \(lens) \(app.buttons["parameter.Shutter"].label) \(app.buttons["parameter.ISO"].label)")
        }
        for rate in ["60.0 fps", "30.0 fps"] {
            app.buttons["settingsOpen"].tap(); tapFPSOption(rate, in: app); app.buttons["captureSettingsClose"].tap()
            Thread.sleep(forTimeInterval: 2)
            XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
            print("MANUAL_FPS \(rate) \(app.buttons["parameter.Shutter"].label) \(app.buttons["parameter.ISO"].label)")
        }
        // Sensor line-time quantization can change the reported reciprocal slightly.
        let originalDenominator = Double(shutter.split(separator: "/").last ?? "") ?? 0
        let finalDenominator = Double(app.buttons["parameter.Shutter"].label.split(separator: "/").last ?? "") ?? 0
        XCTAssertGreaterThan(originalDenominator, 0)
        XCTAssertEqual(finalDenominator, originalDenominator, accuracy: max(1, originalDenominator * 0.01))
        XCTAssertEqual(app.buttons["parameter.ISO"].label, iso)
        let originalKelvin = Double(wb.filter(\.isNumber)) ?? 0
        let finalKelvin = Double(app.buttons["parameter.WB"].label.filter(\.isNumber)) ?? 0
        XCTAssertGreaterThan(originalKelvin, 0)
        XCTAssertEqual(finalKelvin, originalKelvin, accuracy: max(100, originalKelvin * 0.03))
        controlScreenshot(app, "manual-restored")
    }

    func testControlsZAngleSurvivesISOAndFPS() {
        let app = XCUIApplication()
        app.launchArguments = ["-storageLocation", "内部文件", "-exposureType", "angle"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsOpen"].waitForExistence(timeout: 20))
        selectControlCodec("H.265", app: app)
        app.buttons["parameter.Shutter"].tap(); app.buttons["M"].tap()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(app.buttons["parameter.Shutter"].label.contains("180°"))
        app.buttons["parameter.ISO"].tap(); dragControl(app)
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(app.buttons["parameter.Shutter"].label.contains("180°"))
        app.buttons["settingsOpen"].tap(); tapFPSOption("60.0 fps", in: app); app.buttons["完成"].tap()
        app.buttons["parameter.ISO"].tap(); dragControl(app, left: false)
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(app.buttons["parameter.Shutter"].label.contains("180°"), app.debugDescription)
        app.buttons["parameter.Shutter"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '180°' AND label CONTAINS '1/120'")).firstMatch.exists)
        controlScreenshot(app, "angle-after-iso-and-fps")
        app.buttons["settingsOpen"].tap()
        for _ in 0..<4 where !app.switches["rulerHapticsToggle"].isHittable { app.swipeUp() }
        let haptics = app.switches["rulerHapticsToggle"]
        XCTAssertTrue(haptics.isHittable)
        if haptics.value as? String == "1" {
            haptics.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        haptics.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(haptics.value as? String, "1")
        app.buttons["完成"].tap()
    }

    func testFrameRateRestoresAutoMax() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["parameter.Shutter"].waitForExistence(timeout: 20))
        app.tap()
        app.buttons["parameter.Shutter"].tap()
        // FPS changes update Auto-Max defaults only when the user is in Auto-Max.
        // Manual preservation is covered by testControlsManualSurvivesLensAndFPS.
        app.buttons["A-Max"].tap()
        app.buttons["parameter.Shutter"].tap()
        Thread.sleep(forTimeInterval: 0.5)
        for (rate, denominator) in [("60.0 fps", "1/120"), ("30.0 fps", "1/60")] {
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

    func testAutoMaxExposureTypeTracksFrameRate() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["parameter.Shutter"].waitForExistence(timeout: 20))
        app.buttons["settingsOpen"].tap()
        XCTAssertTrue(app.buttons["fpsMenu"].waitForExistence(timeout: 5))
        tapFPSOption("30.0 fps", in: app)
        tapExposureType("angle", in: app)
        app.buttons["完成"].tap()

        showShutterPanel(in: app)
        let angleDefault = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "最长", "180°")).firstMatch
        XCTAssertTrue(angleDefault.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["A-Max"].exists)

        app.buttons["settingsOpen"].tap()
        XCTAssertTrue(app.buttons["fpsMenu"].waitForExistence(timeout: 5))
        tapFPSOption("60.0 fps", in: app)
        app.buttons["完成"].tap()
        showShutterPanel(in: app)
        let atSixty = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "最长", "180°")).firstMatch
        XCTAssertTrue(atSixty.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["settingsOpen"].tap()
        tapExposureType("speed", in: app)
        app.buttons["完成"].tap()
        showShutterPanel(in: app)
        let speedDefault = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "最长", "1/120")).firstMatch
        XCTAssertTrue(speedDefault.waitForExistence(timeout: 5), app.debugDescription)
    }

    private func showShutterPanel(in app: XCUIApplication) {
        if !app.buttons["A-Max"].exists { app.buttons["parameter.Shutter"].tap() }
        XCTAssertTrue(app.buttons["A-Max"].waitForExistence(timeout: 3))
    }

    private func tapExposureType(_ type: String, in app: XCUIApplication) {
        let menu = app.buttons["exposureTypeMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        if menu.label.contains(type == "angle" ? "角度" : "速度") { return }
        for _ in 0..<4 where !menu.isHittable || !menu.frame.midY.isFinite {
            app.swipeUp()
        }
        XCTAssertTrue(menu.isHittable, app.debugDescription)
        let frame = menu.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        let option = app.buttons["exposureType.\(type)"]
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
        let optionFrame = option.frame
        XCTAssertTrue(optionFrame.midX.isFinite && optionFrame.midY.isFinite, app.debugDescription)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: optionFrame.midX, dy: optionFrame.midY)).tap()
    }

    private func tapFPSOption(_ rate: String, in app: XCUIApplication) {
        if app.buttons["fpsMenu"].label.contains(rate) { return }
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
        let app = XCUIApplication(); app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "--ui-testing"]; app.launch()
        if app.alerts.firstMatch.waitForExistence(timeout: 2) {
            let dismiss = app.alerts.firstMatch.buttons["确定"]
            if dismiss.exists { dismiss.tap() }
        }
        app.buttons["settingsOpen"].tap()
        let grid = app.switches["gridToggle"]
        let level = app.switches["levelToggle"]
        for _ in 0..<3 where !grid.exists || !level.exists { app.swipeUp() }
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        for _ in 0..<3 where !grid.isHittable || !level.isHittable { app.swipeUp() }
        XCTAssertTrue(grid.isHittable && level.isHittable)
        let originalGrid = grid.value as? String
        let originalLevel = level.value as? String
        if grid.value as? String != "1" {
            grid.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        if level.value as? String != "1" {
            level.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertEqual(grid.value as? String, "1")
        XCTAssertEqual(level.value as? String, "1")
        app.buttons["captureSettingsClose"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Grid and horizon enabled"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["settingsOpen"].tap()
        for _ in 0..<3 where !grid.isHittable || !level.isHittable { app.swipeUp() }
        if originalGrid == "0" { grid.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        if originalLevel == "0" { level.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(grid.value as? String, originalGrid)
        XCTAssertEqual(level.value as? String, originalLevel)
        app.buttons["captureSettingsClose"].tap()
    }

    func testRestoreViewfinderGuidesOff() {
        let app = XCUIApplication(); app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "--ui-testing"]; app.launch()
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
        app.buttons["captureSettingsClose"].tap()
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
            "-debugEnabled", debug ? "YES" : "NO", "-storageLocation", "内部文件",
            "-AppleLanguages", "(zh-Hans)", "--ui-testing"]
        app.launch()
        let record = app.buttons["recordToggle"]
        XCTAssertTrue(record.waitForExistence(timeout: 20))
        selectControlCodec("H.265", app: app)
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
