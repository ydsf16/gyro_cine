import XCTest
import AVFoundation
import simd
@testable import RawMotionRecorder

final class RecorderTests: XCTestCase {
    func testAssetReaderCountsEncodedFramesNotControlBuffers() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "writer3frames", withExtension: "mov"))
        let video = try RecordingFinalizer.inspectVideo(url)
        XCTAssertEqual(video.frames.count, 3)
        XCTAssertEqual(video.frames.map(\.pts), [0, 1.0 / 30, 2.0 / 30])
    }

    func testAPIIntrinsicsUseRowMajorBufferCoordinatesAndRejectShortPayload() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "writer3frames", withExtension: "mov"))
        let asset = AVURLAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        let sample = try XCTUnwrap(output.copyNextSampleBuffer())
        XCTAssertNil(CaptureFrameEvidence.intrinsicMatrix(sample))
        var matrix = simd_float3x3(columns: (SIMD3(1200, 0, 0), SIMD3(0, 1300, 0), SIMD3(1920, 1080, 1)))
        let payload = withUnsafeBytes(of: &matrix) { Data($0) }
        CMSetAttachment(sample, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                        value: payload as CFData, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertEqual(CaptureFrameEvidence.intrinsicMatrix(sample), [1200, 0, 1920, 0, 1300, 1080, 0, 0, 1])
        CMSetAttachment(sample, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                        value: Data([0, 1]) as CFData, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertNil(CaptureFrameEvidence.intrinsicMatrix(sample))
    }

    func testLegacyBundlePreservesGyroClockUnitsAndPortableReferences() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = ActualVideoInfo(frames: [ActualVideoFrame(pts: 0.25)], width: 3840, height: 2160,
                                    duration: 1, codecFourCC: "hvc1")
        let events = [MotionEvent(kind: .gyro, timestamp: 99.5, x: .pi, y: -2, z: 3),
                      MotionEvent(kind: .accel, timestamp: 99.6, x: 0, y: 0, z: 9.8),
                      MotionEvent(kind: .gyro, timestamp: 100.5, x: 4, y: 5, z: 6)]
        let evidence = [CaptureFrameEvidence(sourcePTSSeconds: 100,
            cameraIntrinsicMatrix: [2000, 0, 1920, 0, 2000, 1080, 0, 0, 1],
            intrinsicSource: "API", activeVideoStabilizationMode: 0)]
        try LegacyGyroflowExporter.write(folder: folder, video: video, events: events,
                                         sourceFirstPTS: 100, fps: 30, evidence: evidence,
                                         lens: CameraLens(id: "test-ultra", name: "超广角", deviceType: "test",
                                                          displayMultiplier: 0.5, supports4K30: true))
        let csv = try String(contentsOf: folder.appendingPathComponent("clip.gcsv"), encoding: .utf8)
        let rows = csv.components(separatedBy: "t,gx,gy,gz\n")[1].split(separator: "\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].split(separator: ",").compactMap { Double($0) }, [-0.25, .pi, -2, 3])
        XCTAssertEqual(rows[1].split(separator: ",").compactMap { Double($0) }, [0.75, 4, 5, 6])
        let project = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            folder.appendingPathComponent("clip.gyroflow"))) as? [String: Any])
        XCTAssertTrue(((project["calibration_data"] as? [String: Any])?["camera_setting"] as? String)?.contains("超广角 0.5×") == true)
        XCTAssertTrue(csv.contains("lens_info,0.5×"))
        let stabilization = try XCTUnwrap(project["stabilization"] as? [String: Any])
        XCTAssertEqual(stabilization["adaptive_zoom_window"] as? Double, 4.0)
        XCTAssertTrue(stabilization["max_zoom"] is NSNull)
        let profile = try XCTUnwrap(project["calibration_data"] as? [String: Any])
        XCTAssertNotNil(profile["camera_model"])
        XCTAssertNotNil(profile["lens_model"])
        XCTAssertTrue((profile["calibrated_by"] as? String)?.contains("not calibrated") == true)
        XCTAssertEqual(project["videofile"] as? String, folder.appendingPathComponent("clip.mov").absoluteString)
        XCTAssertEqual((project["gyro_source"] as? [String: Any])?["filepath"] as? String, folder.appendingPathComponent("clip.gcsv").absoluteString)
        XCTAssertEqual((project["offsets"] as? [String: Double])?["0"], -250)
        XCTAssertThrowsError(try LegacyGyroflowExporter.write(folder: folder, video: video, events: events,
            sourceFirstPTS: 100, fps: 30, evidence: []))
        XCTAssertThrowsError(try LegacyGyroflowExporter.write(folder: folder, video: video, events: [events[0], events[0]],
            sourceFirstPTS: 100, fps: 30, evidence: evidence))
    }

    func testLensFactorsNormalizeAgainstMainCamera() {
        XCTAssertEqual(CameraCapabilityScanner.normalizedLensFactors([2, 6], wideIndex: 1), [0.5, 1, 3])
        XCTAssertEqual(CameraCapabilityScanner.normalizedLensFactors([2, 10], wideIndex: 1), [0.5, 1, 5])
        XCTAssertEqual(CameraCapabilityScanner.normalizedLensFactors([2], wideIndex: 0), [1, 2])
        XCTAssertNil(CameraCapabilityScanner.normalizedLensFactors([0], wideIndex: 1))
        XCTAssertNil(CameraCapabilityScanner.normalizedLensFactors([2], wideIndex: 2))
    }

    @MainActor
    func testLensSelectionLockedDuringCaptureAndFinalization() {
        let model = RecorderViewModel()
        for state in [RecordingState.configuring, .recording, .finalizing] {
            model.state = state
            XCTAssertFalse(model.canSelectLens)
        }
        model.state = .completed
        XCTAssertTrue(model.canSelectLens)
    }

    func testRecordedClockFitHandlesRateDifferenceAndRejectsOutliers() throws {
        let host = [10000.0, 10001, 10002, 10003]
        let video = [0.002, 1.0021, 2.0022, 3.0023]
        let map = try RecordedClockMap(host: host, video: video)
        XCTAssertEqual(map.slope, 1.0001, accuracy: 1e-9)
        XCTAssertEqual(map.videoSeconds(for: 10000.5), 0.50205, accuracy: 1e-9)
        XCTAssertThrowsError(try RecordedClockMap(host: host, video: [0, 1, 2.1, 3]))
        XCTAssertThrowsError(try RecordedClockMap(host: [1, 1], video: [0, 1]))
    }

    func testRecordedClockFitAllowsOneMOVTickButRejectsTwo() throws {
        // A device recording had 270 complete frames; the last three MOV PTS
        // moved by one 1/600 s tick and triggered the former 1 ms gate.
        let host = (0..<270).map { 31_199.099388093 + Double($0) / 30 }
        let expected = (0..<270).map { Double($0) / 30 }
        let oneTick = expected.enumerated().map { $0.offset >= 267 ? $0.element + 1.0 / 600 : $0.element }
        let twoTicks = expected.enumerated().map { $0.offset >= 267 ? $0.element + 2.0 / 600 : $0.element }
        let map = try RecordedClockMap(host: host, video: oneTick)
        XCTAssertGreaterThan(map.maxResidual, 0.001)
        XCTAssertLessThanOrEqual(map.maxResidual, RecordedClockMap.maximumFitResidualSeconds)
        XCTAssertThrowsError(try RecordedClockMap(host: host, video: twoTicks))
    }

    func testHostClockConversionRejectsMissingClockAndPreservesHostPTS() throws {
        let host = CMClockGetHostTimeClock()
        let pts = CMClockGetTime(host)
        XCTAssertEqual(try ClockAligner.hostTime(pts, clock: host), pts.seconds, accuracy: 1e-8)
        XCTAssertThrowsError(try ClockAligner.hostTime(pts, clock: nil))
        XCTAssertThrowsError(try ClockAligner.hostTime(.invalid, clock: host))
        let evidence = ClockAligner.evidence(firstPTS: CMTime(seconds: 10, preferredTimescale: 1000),
                                             hostPTS: 10.05, callbackHostTime: 10.07)
        XCTAssertEqual(evidence.firstVideoHostPTSSeconds, 10.05)
        XCTAssertEqual(evidence.callbackMinusPTSSeconds, 0.02, accuracy: 1e-8)
    }

    func testRadiansToDegrees() {
        XCTAssertEqual(ClockAligner.degreesPerSecond(.pi), 180, accuracy: 1e-10)
    }

    func testFrameGroupingUsesActualPTSIncludingVFR() {
        let groups = GyroflowJSONLWriter.groupIndices(framePTS: [0, 0.033, 0.100],
                                                       samplePTS: [-0.01, 0.01, 0.03, 0.08, 0.2])
        XCTAssertEqual(groups, [[0, 1], [2], [3, 4]])
        XCTAssertEqual(groups.flatMap { $0 }, [0, 1, 2, 3, 4])
    }

    func testCanonicalJSONNumbersAndHeader() throws {
        let message = GFMain(magicString: "GyroflowProtobuf", protocolVersion: 1,
                             header: GFHeader(camera: GFCamera(cameraBrand: "Apple", cameraModel: "iPhone"),
                                              clip: GFClip(frameWidth: 3840, frameHeight: 2160,
                                                           durationUs: 1000, fileFrameRate: 30)),
                             frame: GFFrame(frameNumber: 1, imu: [GFIMU(sampleTimestampUs: 12,
                                                                        gyroscopeX: 1, gyroscopeY: 2, gyroscopeZ: 3,
                                                                        accelerometerX: 4, accelerometerY: 5, accelerometerZ: 6)]))
        let dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        XCTAssertEqual(dictionary["magicString"] as? String, "GyroflowProtobuf")
        XCTAssertTrue(dictionary["protocolVersion"] is NSNumber)
        XCTAssertNotNil((dictionary["frame"] as? [String: Any])?["imu"])
    }
}
