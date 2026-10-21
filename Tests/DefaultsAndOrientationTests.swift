import XCTest
import AVFoundation
@testable import GyroCine

final class DefaultsAndOrientationTests: XCTestCase {
    func testFreshWhiteBalanceDefaultsToAutoLockWithoutOverridingSavedChoice() {
        let name = "wb-default-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        XCTAssertEqual(SavedCameraControls.load(preferences).whiteBalance, "Auto-L")
        for choice in ["Auto", "Manual", "Auto-L"] {
            var controls = SavedCameraControls.load(preferences)
            controls.whiteBalance = choice
            controls.save(preferences)
            XCTAssertEqual(SavedCameraControls.load(preferences).whiteBalance, choice)
        }
    }

    func testHEVCBitratePresetsScaleWithRasterAndFrameRate() {
        XCTAssertEqual(HEVCBitratePreset.allCases.count, 4)
        XCTAssertEqual(HEVCBitratePreset.stored(nil), .balanced)
        XCTAssertEqual(HEVCBitratePreset.stored("automatic"), .balanced)
        XCTAssertEqual(HEVCBitratePreset.stored("compact"), .compact)
        XCTAssertEqual(HEVCBitratePreset.stored("quality"), .quality)
        XCTAssertEqual(HEVCBitratePreset.compact.targetBitsPerSecond(width: 3840, height: 2160, fps: 60), 29_859_840)
        XCTAssertEqual(HEVCBitratePreset.balanced.targetBitsPerSecond(width: 3840, height: 2160, fps: 60), 49_766_400)
        XCTAssertEqual(HEVCBitratePreset.quality.targetBitsPerSecond(width: 3840, height: 2160, fps: 60), 89_579_520)
        XCTAssertEqual(HEVCBitratePreset.maximum.targetBitsPerSecond(width: 3840, height: 2160, fps: 60), 119_439_360)
        XCTAssertEqual(HEVCBitratePreset.balanced.targetBitsPerSecond(width: 3840, height: 2160, fps: 30), 24_883_200)
        XCTAssertEqual(HEVCBitratePreset.balanced.targetBitsPerSecond(width: 1920, height: 1080, fps: 60), 12_441_600)
        XCTAssertNil(HEVCBitratePreset.quality.targetBitsPerSecond(width: 0, height: 2160, fps: 60))
        XCTAssertNil(HEVCBitratePreset.quality.targetBitsPerSecond(width: 3840, height: 2160, fps: .nan))
    }

    func testDisabled240FrameRateFallsBackTo120() {
        XCTAssertEqual(CaptureFrameRatePolicy.maximum, 120)
        XCTAssertEqual(CaptureFrameRatePolicy.normalized(240), 120)
        XCTAssertEqual(CaptureFrameRatePolicy.normalized(119.88), 119.88)
    }

    func testProVideoStorageRequiresRuntimeSupport() {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 else { return }
        let output = AVCaptureMovieFileOutput()
        XCTAssertFalse(ProVideoStorageBridge.isSupported())
        XCTAssertFalse(ProVideoStorageBridge.isOutputSupported(output))
        XCTAssertNotNil(ProVideoStorageBridge.configureOutput(output, enabled: true))
        XCTAssertNil(ProVideoStorageBridge.configureOutput(output, enabled: false))
    }

    func testSessionMigrationSeparatesMoviesAndLogs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacy = root.appendingPathComponent("Documents/Sessions")
        let movies = root.appendingPathComponent("Documents/Media")
        let diagnostics = root.appendingPathComponent("Documents/Log")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["IMG_0001.mov", "IMG_0001.imu_raw.jsonl", "IMG_0001.camera_frames.jsonl",
                     "IMG_0001.mov.pending-imu.json", "focus-test.jsonl"] {
            try Data(name.utf8).write(to: legacy.appendingPathComponent(name))
        }
        try RecordingStoragePaths.migrateSessions(from: legacy, moviesTo: movies, diagnosticsTo: diagnostics)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: movies.path), ["IMG_0001.mov"])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: diagnostics.path)),
                       Set(["IMG_0001.imu_raw.jsonl", "IMG_0001.camera_frames.jsonl",
                            "IMG_0001.mov.pending-imu.json", "focus-test.jsonl"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testDeleteCleansOnlyMatchingMedia() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = ["clip.mov", "clip.mov.pending-imu.json", "clip.mov.metadata-recovery.json", "clip.imu_raw.jsonl", "clip.camera_frames.jsonl", "other.mov", "clip-other.imu_raw.jsonl"]
        for name in names { try Data("fixture".utf8).write(to: directory.appendingPathComponent(name)) }
        try CameraManager.removeMediaFiles(directory.appendingPathComponent("clip.mov"))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), Set(names.suffix(2)))
    }

    func testRecoveryRejectsTraversal() throws {
        let job = PendingIMUJob(movieName: "../clip.mov", imuName: "../clip.imu_raw.jsonl",
            framesName: "../clip.camera_frames.jsonl", firstHost: 1, orientation: .portrait,
            camera: "test", lens: "wide", mode: "SonyMov", retainDebug: false)
        XCTAssertThrowsError(try job.complete(in: FileManager.default.temporaryDirectory)) { error in
            XCTAssertTrue(String(describing: error).contains("Invalid recovery file paths"))
        }
    }

    func testSpaceAndSynchronizationFailures() throws {
        XCTAssertEqual(MOVTelemetryMuxer.captureVolumeCapacity(reported: 0, externalDevice: 2_000), 2_000)
        XCTAssertEqual(MOVTelemetryMuxer.captureVolumeCapacity(reported: nil, externalDevice: 2_000), 2_000)
        XCTAssertEqual(MOVTelemetryMuxer.captureVolumeCapacity(reported: 500, externalDevice: 2_000), 500)
        XCTAssertNil(MOVTelemetryMuxer.captureVolumeCapacity(reported: 0, externalDevice: -1))
        XCTAssertThrowsError(try MOVTelemetryMuxer.checkCopyCapacity(ordinary: 9, important: 100, required: 10))
        XCTAssertThrowsError(try MOVTelemetryMuxer.checkCopyCapacity(ordinary: nil, important: nil, required: 10))
        XCTAssertNoThrow(try MOVTelemetryMuxer.checkCopyCapacity(ordinary: 10, important: nil, required: 10))
        var called = false
        XCTAssertThrowsError(try MOVTelemetryMuxer.synchronize(primary: { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }, fallback: { called = true; return 0 }))
        XCTAssertFalse(called)
        XCTAssertNoThrow(try MOVTelemetryMuxer.synchronize(primary: { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)) }, fallback: { 0 }))
    }

    func testDiscreteStopsAndDeviceLimits() {
        let range = 75.0...900.0
        XCTAssertEqual(ControlStops.legal(ControlStops.iso, range: range).first, 75)
        XCTAssertEqual(ControlStops.legal(ControlStops.iso, range: range).last, 900)
        XCTAssertEqual(ControlStops.snap(410, values: ControlStops.iso, range: range, mapping: .logarithmic), 400)
        XCTAssertEqual(ControlStops.snap(10000, values: ControlStops.iso, range: range, mapping: .logarithmic), 900)
        XCTAssertEqual(ControlStops.snap(1.0/119, values: ControlStops.shutter, range: 1.0/8000...1.0/60, mapping: .logarithmic), 1.0/120)
        XCTAssertEqual(ControlStops.snap(179, values: ControlStops.angle, range: 1...360, mapping: .linear), 180)
    }

    func testRulerEndpointsAndRoundTrip() {
        for mapping in [RulerMapping.linear, .logarithmic] {
            for fraction in [0.0, 0.25, 0.5, 0.75, 1] {
                let value = mapping.value(at: fraction, in: 0.00025...0.1)
                XCTAssertEqual(mapping.fraction(for: value, in: 0.00025...0.1), fraction, accuracy: 1e-9)
            }
            XCTAssertEqual(mapping.value(at: -1, in: 1...100), 1, accuracy: 1e-9)
            XCTAssertEqual(mapping.value(at: 2, in: 1...100), 100, accuracy: 1e-9)
        }
    }

    func testIntrinsicAlignmentEstimatesMissingTimeButRejectsWrongRaster() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let video = ActualVideoInfo(frames: [.init(pts: 0), .init(pts: 1.0/30)], width: 1920, height: 1080, duration: 2.0/30, codecFourCC: "hvc1")
        let matrix: [Double] = [1000,0,960,0,1000,540,0,0,1]
        func write(_ width: Int, _ shift: Double) throws {
            let frames = [100.0, 100 + 1.0/30].map { CameraIntrinsicsRecorder.Frame(hostTime: $0+shift, width: width, height: 1080, matrix: matrix, exposure: 1.0/120, iso: 100) }
            try frames.reduce(into: Data()) { $0 += try JSONEncoder().encode($1) + Data([10]) }.write(to: url)
        }
        try write(1920, 0)
        XCTAssertEqual(try CameraIntrinsicsRecorder.aligned(url, video: video, firstHost: 100, interval: 1.0/30).count, 2)
        try write(1920, 0.02)
        let estimate = try CameraIntrinsicsRecorder.alignment(url, video: video, firstHost: 100, interval: 1.0/30)
        XCTAssertEqual(estimate.frames.count, 2)
        XCTAssertGreaterThan(estimate.interpolatedCount + estimate.nearestFallbackCount, 0)
        try write(1080, 0)
        XCTAssertThrowsError(try CameraIntrinsicsRecorder.aligned(url, video: video, firstHost: 100, interval: 1.0/30))
    }

    func testIntrinsicAlignmentInterpolatesOneDroppedCallback() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let step = 1.0 / 60
        let video = ActualVideoInfo(frames: [0.0, step, 2 * step].map { .init(pts: $0) },
            width: 3840, height: 2160, duration: 3 * step, codecFourCC: "hvc1")
        let matrices = [1000.0, 1200.0]
        let evidence = zip([100.0, 100.0 + 2 * step], matrices).map { time, focal in
            CameraIntrinsicsRecorder.Frame(hostTime: time, width: 3840, height: 2160,
                matrix: [focal, 0, 1920, 0, focal, 1080, 0, 0, 1], exposure: 1.0 / 200, iso: 100)
        }
        try evidence.reduce(into: Data()) { $0 += try JSONEncoder().encode($1) + Data([10]) }.write(to: url)
        let result = try CameraIntrinsicsRecorder.alignment(url, video: video, firstHost: 100, interval: step)
        XCTAssertEqual(result.interpolatedCount, 1)
        XCTAssertEqual(result.frames[1].matrix[0], 1100, accuracy: 0.001)
    }

    func testIntrinsicAlignmentAllowsMeasuredMovieClockPhase() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let interval = 1.0 / 60
        let video = ActualVideoInfo(frames: [.init(pts: 0), .init(pts: interval)],
            width: 3840, height: 2160, duration: 2 * interval, codecFourCC: "hvc1")
        let matrix: [Double] = [2000, 0, 1920, 0, 2000, 1080, 0, 0, 1]
        func write(shift: Double) throws {
            let frames = [100.0, 100 + interval].map {
                CameraIntrinsicsRecorder.Frame(hostTime: $0 + shift, width: 3840, height: 2160,
                    matrix: matrix, exposure: 1.0 / 200, iso: 100)
            }
            try frames.reduce(into: Data()) { $0 += try JSONEncoder().encode($1) + Data([10]) }.write(to: url)
        }
        try write(shift: -0.007513)
        XCTAssertEqual(try CameraIntrinsicsRecorder.aligned(url, video: video,
            firstHost: 100, interval: interval).count, 2)
        try write(shift: -0.012)
        let estimated = try CameraIntrinsicsRecorder.alignment(url, video: video,
            firstHost: 100, interval: interval)
        XCTAssertGreaterThan(estimated.nearestFallbackCount, 0)
    }

    func testMetadataJournalRollbackPreservesOriginal() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: MOVTelemetryMuxer.recoveryURL(url)) }
        let original = MOVTelemetryMuxer.box("moov", Data([1,2,3,4]))
        var interrupted = original
        interrupted.replaceSubrange(4..<8, with: Data("free".utf8))
        interrupted += Data(repeating: 99, count: 50)
        try interrupted.write(to: url)
        try JSONEncoder().encode(MOVTelemetryMuxer.Recovery(originalLength: UInt64(original.count), moovOffset: 0)).write(to: MOVTelemetryMuxer.recoveryURL(url))
        try MOVTelemetryMuxer.recoverIfNeeded(url)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: MOVTelemetryMuxer.recoveryURL(url).path))
        try JSONEncoder().encode(MOVTelemetryMuxer.Recovery(originalLength: UInt64(original.count), moovOffset: UInt64.max)).write(to: MOVTelemetryMuxer.recoveryURL(url))
        XCTAssertThrowsError(try MOVTelemetryMuxer.recoverIfNeeded(url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertThrowsError(try MOVTelemetryMuxer.atoms(Data([0,0,0,40,109,111,111,118])))
    }

    func testUnboundedFinalMdatRollbackRestoresOriginalHeader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: MOVTelemetryMuxer.recoveryURL(url)) }
        let moov = MOVTelemetryMuxer.box("moov", Data([1, 2, 3, 4]))
        let mdat = Data(repeating: 0, count: 4) + Data("mdat".utf8) + Data(repeating: 9, count: 64)
        let original = moov + mdat
        XCTAssertEqual(MOVTelemetryMuxer.boundedFinalMdatSize(offset: UInt64(moov.count), fileLength: UInt64(original.count)), UInt32(mdat.count))
        XCTAssertNil(MOVTelemetryMuxer.boundedFinalMdatSize(offset: 0, fileLength: UInt64(UInt32.max) + 1))
        var interrupted = original
        interrupted.replaceSubrange(moov.count..<(moov.count + 4), with: Data.be(UInt64(mdat.count), 4))
        interrupted.replaceSubrange(4..<8, with: Data("free".utf8))
        interrupted += Data(repeating: 8, count: 20)
        try interrupted.write(to: url)
        try JSONEncoder().encode(MOVTelemetryMuxer.Recovery(originalLength: UInt64(original.count), moovOffset: 0,
            unboundedAtomOffset: UInt64(moov.count))).write(to: MOVTelemetryMuxer.recoveryURL(url))
        try MOVTelemetryMuxer.recoverIfNeeded(url)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testTelemetryBadgeRejectsMarkerWithoutSamples() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = MOVTelemetryMuxer.box("moov", MOVTelemetryMuxer.box("trak", MOVTelemetryMuxer.box("hdlr", Data("Sony RTMD compatibility\0".utf8))))
        try fake.write(to: url)
        XCTAssertFalse(MOVTelemetryMuxer.hasTelemetry(url))
    }

    func testPendingJobPersistsRelativePathsAndFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var job = PendingIMUJob(movieName: "clip.mov", imuName: "clip.imu_raw.jsonl",
            framesName: "clip.camera_frames.jsonl", firstHost: 123.5, orientation: .portrait,
            camera: "iPhone", lens: "wide", mode: "SonyMov", retainDebug: false)
        job.ready = true
        job.recordingFailure = "Incomplete movie"
        job.recordingWarning = "SSD disconnected"
        try job.save(in: directory)
        let restored = try JSONDecoder().decode(PendingIMUJob.self, from: Data(contentsOf: job.url(in: directory)))
        XCTAssertEqual(restored.firstHost, 123.5)
        XCTAssertEqual(restored.orientation, .portrait)
        XCTAssertEqual(restored.movieName, "clip.mov")
        XCTAssertTrue(restored.ready)
        XCTAssertEqual(restored.recordingWarning, "SSD disconnected")
        XCTAssertThrowsError(try restored.complete(in: directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.url(in: directory).path))
    }

    func testRecordingCompletionWithSystemWarning() {
        XCTAssertTrue(CameraManager.recordingFileSucceeded(nil))
        let saved = NSError(domain: AVFoundationErrorDomain, code: -11818,
            userInfo: [AVErrorRecordingSuccessfullyFinishedKey: true])
        XCTAssertTrue(CameraManager.recordingFileSucceeded(saved))
        XCTAssertNil(CameraManager.recordingFailureReason(saved))
        XCTAssertNil(CameraManager.recordingFailureReason(nil))
        for info: [String: Any] in [[:], [AVErrorRecordingSuccessfullyFinishedKey: false]] {
            let error = NSError(domain: AVFoundationErrorDomain, code: -11818, userInfo: info)
            XCTAssertFalse(CameraManager.recordingFileSucceeded(error))
            XCTAssertNotNil(CameraManager.recordingFailureReason(error))
        }
        XCTAssertFalse(CameraManager.recordingFileSucceeded(NSError(domain: "Other", code: 1,
            userInfo: [AVErrorRecordingSuccessfullyFinishedKey: true])))
    }

    func testGravityDirectionsAndFlatFallback() {
        var tracker = RecordingDirectionTracker()
        XCTAssertEqual(tracker.resolve(nil, at: 100).orientation, .portrait)
        for (x, y, expected) in [(0.0, -1.0, RecordingOrientation.portrait),
                                (-1.0, 0.0, .landscapeRight), (0.0, 1.0, .portraitUpsideDown),
                                (1.0, 0.0, .landscapeLeft)] {
            XCTAssertEqual(tracker.resolve(.init(timestamp: 100, x: x, y: y, z: 0), at: 100.1).orientation, expected)
        }
        XCTAssertEqual(tracker.resolve(.init(timestamp: 100, x: 0.02, y: 0.01, z: -1), at: 100.1).orientation, .landscapeLeft)
        XCTAssertEqual(tracker.resolve(.init(timestamp: 90, x: 0, y: -1, z: 0), at: 100).orientation, .landscapeLeft)
    }
    func testHorizonGuideInPortraitAndLandscape() {
        for (x, y, angle) in [(0.0, -1.0, 0.0), (1.0, 0.0, -Double.pi / 2),
                              (-1.0, 0.0, Double.pi / 2), (0.0, 1.0, Double.pi)] {
            let pose = HorizonGuidePose(gravity: .init(timestamp: 0, x: x, y: y, z: 0))!
            XCTAssertEqual(cos(pose.angle), cos(angle), accuracy: 1e-9)
            XCTAssertEqual(sin(pose.angle), sin(angle), accuracy: 1e-9)
            XCTAssertTrue(pose.aligned)
        }
        XCTAssertNil(HorizonGuidePose(gravity: .init(timestamp: 0, x: 0.01, y: 0.02, z: -1)))
        let tilted = HorizonGuidePose(gravity: .init(timestamp: 0, x: 0.1, y: -0.99, z: 0))!
        XCTAssertFalse(tilted.aligned)
        for degrees in stride(from: -180.0, through: 180.0, by: 5) {
            let a = degrees * .pi / 180
            let gx = sin(a), gy = -cos(a)
            let pose = HorizonGuidePose(gravity: .init(timestamp: 0, x: gx, y: gy, z: 0))!
            // Rendered line direction must be orthogonal to screen-space gravity.
            XCTAssertEqual(cos(pose.angle) * gx - sin(pose.angle) * gy, 0, accuracy: 1e-9)
        }
    }
    func testExposureDefaultsAcrossFrameRates() {
        for fps in [24.0, 25, 29.97, 30, 59.94, 60, 120] {
            XCTAssertEqual(CaptureDefaults.maximumExposure(fps: fps, minimum: 1/10000, maximum: 1),
                           1 / (2 * fps), accuracy: 1e-9)
        }
        XCTAssertEqual(CaptureDefaults.maximumExposure(fps: 240, minimum: 1/10000, maximum: 1), 1/480, accuracy: 1e-9)
        XCTAssertEqual(CaptureDefaults.maximumExposure(fps: 120, minimum: 1/150, maximum: 1), 1/150, accuracy: 1e-9)
        XCTAssertEqual(CaptureDefaults.exposure(forShutterAngle: 180, fps: 24,
            minimum: 1/10000, maximum: 1), 1/48, accuracy: 1e-9)
        XCTAssertEqual(CaptureDefaults.exposure(forShutterAngle: 180, fps: 30,
            minimum: 1/10000, maximum: 1), 1/60, accuracy: 1e-9)
        XCTAssertEqual(CaptureDefaults.exposure(forShutterAngle: 45, fps: 60,
            minimum: 1/10000, maximum: 1), 1/480, accuracy: 1e-9)
        XCTAssertEqual(CaptureDefaults.exposure(forShutterAngle: 360, fps: 120,
            minimum: 1/10000, maximum: 1), 1/120, accuracy: 1e-9)
    }
    func testManualExposureClampsToNewFrameAndSensorLimits() {
        XCTAssertEqual(CaptureDefaults.clampedManualExposure(1/60, fps: 120,
            minimum: 1/10000, maximum: 1), 1/120, accuracy: 1e-9)
        XCTAssertEqual(CaptureDefaults.clampedManualExposure(1/1000, fps: 30,
            minimum: 1/500, maximum: 1), 1/500, accuracy: 1e-9)
        XCTAssertEqual(CaptureDefaults.clampedManualExposure(1/200, fps: 30,
            minimum: 1/10000, maximum: 1), 1/200, accuracy: 1e-9)
    }
    func testLocalizedRecordingErrorsKeepDiagnosticsSeparate() {
        let raw = "unavailable(视频帧时间异常：60 fps 最大间隔 600 ms)"
        let english = AppText.message(raw, language: "en")
        XCTAssertTrue(english.contains("invalid or missing frames"))
        XCTAssertFalse(english.contains("unavailable("))
        XCTAssertTrue(AppText.message(raw, language: "zh-Hans").contains("视频帧数据异常"))
        XCTAssertTrue(PendingIMUJob.isPermanentFailure(raw))
        XCTAssertTrue(AppText.message("ProRes RAW 需要专用视频存储或外部 SSD。请在设置中选择存储位置。", language: "en").contains("Pro Video Storage"))
        XCTAssertEqual(AppText.message("测速已取消，临时文件已清理 / Cancelled; test file removed", language: "en"), "Cancelled; test file removed")
        XCTAssertTrue(AppText.message("Lens switch: camera input unavailable", language: "zh-Hans").contains("镜头切换失败"))
    }

    func testAllUserControlsPersistAcrossLaunch() throws {
        let suite = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        CaptureDefaults.restoreIfNeeded(preferences)
        var controls = SavedCameraControls()
        controls.shutter = "angle"; controls.angle = 90; controls.seconds = 1.0 / 240
        controls.iso = 640; controls.maximumSeconds = 1.0 / 100; controls.ev = -1.5
        controls.whiteBalance = "Manual"; controls.kelvin = 4300
        controls.focus = "Manual"; controls.focusPosition = 0.8; controls.focusX = 0.3; controls.focusY = 0.7
        controls.save(preferences)
        for (key, value) in ["filenameType": "simple", "outputFormat": "GyroflowProto", "previewLUTLook": "rec709"] {
            preferences.set(value, forKey: key)
        }
        for key in ["showCompositionGrid", "showHorizonLevel", "rulerHaptics", "previewLUTEnabled"] { preferences.set(true, forKey: key) }
        var slate = RecordingSlate(); slate.production = "Keep me"; slate.save(preferences)
        let relaunched = try XCTUnwrap(UserDefaults(suiteName: suite))
        CaptureDefaults.restoreIfNeeded(relaunched)
        XCTAssertEqual(SavedCameraControls.load(relaunched), controls)
        XCTAssertEqual(RecordingSlate.load(relaunched), slate)
        XCTAssertEqual(relaunched.string(forKey: "filenameType"), "simple")
        XCTAssertEqual(relaunched.string(forKey: "outputFormat"), "GyroflowProto")
        for key in ["showCompositionGrid", "showHorizonLevel", "rulerHaptics", "previewLUTEnabled"] { XCTAssertTrue(relaunched.bool(forKey: key)) }
        for mode in ["auto", "autoMax", "manual", "angle"] {
            controls.shutter = mode; controls.save(preferences)
            XCTAssertEqual(SavedCameraControls.load(relaunched).shutter, mode)
        }
        for mode in ["Auto-L", "Auto", "Manual"] {
            controls.whiteBalance = mode; controls.save(preferences)
            XCTAssertEqual(SavedCameraControls.load(relaunched).whiteBalance, mode)
        }
    }

    func testCaptureConfigurationSurvivesRestart() throws {
        let suite = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        CaptureDefaults.restoreIfNeeded(preferences)
        XCTAssertNil(SavedCaptureConfiguration.load(preferences))
        let expected = SavedCaptureConfiguration(lensID: "telephoto", encoding: "proResRAWHQ", width: 4224, height: 3024, fps: 59.94)
        expected.save(preferences)
        preferences.set("外部 SSD", forKey: "storageLocation")
        preferences.set("speed", forKey: "exposureType")
        let relaunched = try XCTUnwrap(UserDefaults(suiteName: suite))
        CaptureDefaults.restoreIfNeeded(relaunched)
        relaunched.register(defaults: ["storageLocation": "内部文件", "exposureType": "angle"])
        XCTAssertEqual(SavedCaptureConfiguration.load(relaunched), expected)
        XCTAssertEqual(relaunched.string(forKey: "storageLocation"), "外部 SSD")
        XCTAssertEqual(relaunched.string(forKey: "exposureType"), "speed")
        relaunched.set(Data("broken".utf8), forKey: SavedCaptureConfiguration.key)
        XCTAssertNil(SavedCaptureConfiguration.load(relaunched))
    }

    func testPermanentIMUFailureLeavesAutomaticRetryQueue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pending = directory.appendingPathComponent("clip.mov.pending-imu.json")
        let movie = directory.appendingPathComponent("clip.mov")
        let imu = directory.appendingPathComponent("clip.imu_raw.jsonl")
        for file in [pending, movie, imu] { try Data("preserve".utf8).write(to: file) }
        XCTAssertTrue(PendingIMUJob.isPermanentFailure("视频帧时间异常：60 fps 最大间隔 600 ms"))
        XCTAssertFalse(PendingIMUJob.isPermanentFailure("无法访问 SSD 素材，请重新连接 SSD"))
        try PendingIMUJob.retire(pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("clip.mov.failed-imu.json")), Data("preserve".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movie.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imu.path))
        // A restarted scanner only selects pending manifests, including after movie deletion.
        try FileManager.default.removeItem(at: movie)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".pending-imu.json") })
    }

    func testSSDSpeedSpecificationGuidance() {
        let report = SSDSpeedReport(drive: "SSD", driveID: nil, configuration: "test", requiredMBps: 31,
            fps: 60, averageMBps: 300, sustainedMBps: 214, maximumWriteMS: 668, maximumFlushMS: 100)
        let hevc = SSDSpeedSpecification(encoding: .hevc, width: 3840, height: 2160,
            fps: 60, requiredMBps: 31, learned: false)
        XCTAssertEqual(hevc.recommendedMBps, 40.3, accuracy: 0.001)
        XCTAssertEqual(hevc.assessment(using: report), .usable)
        let raw = SSDSpeedSpecification(encoding: .proResRAW, width: 4224, height: 2240,
            fps: 60, requiredMBps: 143, learned: true)
        XCTAssertEqual(raw.assessment(using: report), .risky)
        let hq = SSDSpeedSpecification(encoding: .proResRAWHQ, width: 4224, height: 3024,
            fps: 120, requiredMBps: 800, learned: false)
        XCTAssertEqual(hq.assessment(using: report), .insufficient)
        XCTAssertNotEqual(raw.id, hq.id)
    }

    func testSSDSpeedReusesMeasurementForChangedConfiguration() {
        var report = SSDSpeedReport(drive: "SSD", driveID: "disk-a", configuration: "H.265 4K60", requiredMBps: 31,
            fps: 60, averageMBps: 333, sustainedMBps: 237, maximumWriteMS: 20, maximumFlushMS: 50)
        let timestamp = report.date
        XCTAssertEqual(report.assessment, .usable)
        report.configuration = "ProRes RAW HQ 4K60"
        report.requiredMBps = 340
        XCTAssertEqual(report.assessment, .insufficient)
        XCTAssertEqual(report.sustainedMBps, 237)
        XCTAssertEqual(report.date, timestamp)
    }

    func testSSDSpeedAssessmentUsesHeadroomAndStalls() {
        XCTAssertEqual(SSDSpeedReport.assess(sustained: 214, required: 31, stallMS: 668, fps: 60), .usable)
        XCTAssertEqual(SSDSpeedReport.assess(sustained: 214, required: 143, stallMS: 668, fps: 60, bufferedFrameLimit: 10), .risky)
        XCTAssertEqual(SSDSpeedReport.assess(sustained: 237, required: 340, stallMS: 10, fps: 60), .insufficient)
        XCTAssertEqual(SSDSpeedReport.assess(sustained: 237, required: 143, stallMS: 668, fps: 30, bufferedFrameLimit: 10), .risky)
        XCTAssertEqual(SSDSpeedReport.assess(sustained: 350, required: 300, stallMS: 10, fps: 60), .risky)
        XCTAssertEqual(SSDSpeedReport.assess(sustained: 500, required: 300, stallMS: 20, fps: 60), .usable)
        XCTAssertEqual(SSDSpeedReport.assess(sustained: .nan, required: 300, stallMS: 20, fps: 60), .insufficient)
    }
    func testSSDSpeedCancellationCleansOnlyItsFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tmp")
        let token = SSDSpeedCancellation(); token.cancel()
        XCTAssertThrowsError(try SSDSpeedTest.run(url: url, cancellation: token) { _, _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let midWrite = SSDSpeedCancellation()
        XCTAssertThrowsError(try SSDSpeedTest.run(url: url, cancellation: midWrite) { _, _ in midWrite.cancel() })
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try Data("keep".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try SSDSpeedTest.run(url: url, cancellation: token) { _, _ in })
        XCTAssertEqual(try String(contentsOf: url), "keep")
    }

    func testRAWCadenceGuardStopsSustainedLoss() {
        var guardrail = RAWCadenceGuard()
        var stopped = false
        for frame in 0...300 {
            if guardrail.observe(Double(frame) / 48, fps: 60) != nil { stopped = true }
        }
        XCTAssertTrue(stopped)
        var missingGuard = RAWCadenceGuard()
        var result: Int?
        for frame in 0...360 where frame % 5 != 4 {
            if let missing = missingGuard.observe(Double(frame) / 60, fps: 60) { result = missing }
        }
        XCTAssertNotNil(result)
    }
    func testRAWCadenceGuardAllowsSparseLoss() {
        var guardrail = RAWCadenceGuard()
        for frame in 0...900 where frame != 40 && frame != 700 {
            XCTAssertNil(guardrail.observe(Double(frame) / 60, fps: 60))
        }
    }

    func testRAWFrameBudgetIncludesQueuedSamples() {
        let budget = RAWFrameBudget(limit: 10)
        for _ in 0..<10 { XCTAssertTrue(budget.acquire()) }
        XCTAssertFalse(budget.acquire())
        XCTAssertEqual(budget.peak, 10)
        budget.release()
        XCTAssertTrue(budget.acquire())
        XCTAssertFalse(budget.acquire())
        for _ in 0..<10 { budget.release() }
        XCTAssertTrue(budget.acquire())
        budget.release()
    }

    func testVideoCadenceRejectsDuplicateAndInvalidPTS() {
        XCTAssertThrowsError(try VideoCadenceHealth(frames: [.init(pts: 0), .init(pts: 0)], fps: 60).validate(fps: 60))
        XCTAssertThrowsError(try VideoCadenceHealth(frames: [.init(pts: 0), .init(pts: .nan)], fps: 60).validate(fps: 60))
    }
    func testVideoCadenceAllowsSparsePTSButRejectsHeavyLoss() throws {
        let healthy = (0..<600).map { ActualVideoFrame(pts: Double($0) / 60) }
        XCTAssertFalse(VideoCadenceHealth(frames: healthy, fps: 60).isSeverelyDiscontinuous)
        let interrupted = healthy.filter { $0.pts < 3 || $0.pts > 3.25 }
        let result = VideoCadenceHealth(frames: interrupted, fps: 60)
        XCTAssertTrue(result.isSeverelyDiscontinuous)
        XCTAssertGreaterThan(result.maximumGap, 0.25)
        XCTAssertNoThrow(try result.validate(fps: 60))
        let recurringLoss = healthy.enumerated().compactMap { $0.offset.isMultiple(of: 10) ? nil : $0.element }
        let recurring = VideoCadenceHealth(frames: recurringLoss, fps: 60)
        XCTAssertLessThan(recurring.maximumGap, 0.1)
        XCTAssertTrue(recurring.isSeverelyDiscontinuous)
        XCTAssertThrowsError(try recurring.validate(fps: 60))
    }
    func testSettingsMigrationRunsOnce() {
        let suite = "GyroCineTests.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(120, forKey: "capture.fps.camera")
        preferences.set(true, forKey: "debugEnabled")
        CaptureDefaults.restoreIfNeeded(preferences)
        XCTAssertNil(preferences.object(forKey: "capture.fps.camera"))
        XCTAssertFalse(preferences.bool(forKey: "debugEnabled"))
        XCTAssertEqual(preferences.string(forKey: "outputFormat"), "SonyMov")
        preferences.set(60, forKey: "capture.fps.camera")
        CaptureDefaults.restoreIfNeeded(preferences)
        XCTAssertEqual(preferences.integer(forKey: "capture.fps.camera"), 60)
    }
}
