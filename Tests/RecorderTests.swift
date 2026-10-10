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
