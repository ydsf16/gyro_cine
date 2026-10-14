import XCTest
import AVFoundation
@testable import GyroCine

final class DefaultsAndOrientationTests: XCTestCase {
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
        for (x, y, angle) in [(0.0, -1.0, 0.0), (1.0, 0.0, Double.pi / 2),
                              (-1.0, 0.0, -Double.pi / 2), (0.0, 1.0, Double.pi)] {
            let pose = HorizonGuidePose(gravity: .init(timestamp: 0, x: x, y: y, z: 0))!
            XCTAssertEqual(pose.angle, angle, accuracy: 1e-9)
            XCTAssertTrue(pose.aligned)
        }
        XCTAssertNil(HorizonGuidePose(gravity: .init(timestamp: 0, x: 0.01, y: 0.02, z: -1)))
        let tilted = HorizonGuidePose(gravity: .init(timestamp: 0, x: 0.1, y: -0.99, z: 0))!
        XCTAssertFalse(tilted.aligned)
    }
    func testExposureDefaultsAcrossFrameRates() {
        for fps in [24.0, 25, 29.97, 30, 59.94, 60, 120] {
            XCTAssertEqual(CaptureDefaults.maximumExposure(fps: fps, minimum: 1/10000, maximum: 1), 1/200, accuracy: 1e-9)
        }
        XCTAssertEqual(CaptureDefaults.maximumExposure(fps: 240, minimum: 1/10000, maximum: 1), 1/240, accuracy: 1e-9)
        XCTAssertEqual(CaptureDefaults.maximumExposure(fps: 120, minimum: 1/150, maximum: 1), 1/150, accuracy: 1e-9)
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
