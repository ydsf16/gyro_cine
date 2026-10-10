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
                                         sourceFirstPTS: 100, fps: 30, evidence: evidence)
        let csv = try String(contentsOf: folder.appendingPathComponent("clip.gcsv"), encoding: .utf8)
        let rows = csv.components(separatedBy: "t,gx,gy,gz\n")[1].split(separator: "\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].split(separator: ",").compactMap { Double($0) }, [-0.25, .pi, -2, 3])
        XCTAssertEqual(rows[1].split(separator: ",").compactMap { Double($0) }, [0.75, 4, 5, 6])
        let project = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            folder.appendingPathComponent("clip.gyroflow"))) as? [String: Any])
        XCTAssertEqual(project["videofile"] as? String, folder.appendingPathComponent("clip.mov").absoluteString)
        XCTAssertEqual((project["gyro_source"] as? [String: Any])?["filepath"] as? String, folder.appendingPathComponent("clip.gcsv").absoluteString)
        XCTAssertTrue((project["offsets"] as? [String: Double])?.isEmpty == true)
        XCTAssertThrowsError(try LegacyGyroflowExporter.write(folder: folder, video: video, events: events,
            sourceFirstPTS: 100, fps: 30, evidence: []))
        XCTAssertThrowsError(try LegacyGyroflowExporter.write(folder: folder, video: video, events: [events[0], events[0]],
            sourceFirstPTS: 100, fps: 30, evidence: evidence))
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
