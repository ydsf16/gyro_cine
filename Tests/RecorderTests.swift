import XCTest
@testable import RawMotionRecorder

final class RecorderTests: XCTestCase {
    func testAssetReaderCountsEncodedFramesNotControlBuffers() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "writer3frames", withExtension: "mov"))
        let video = try RecordingFinalizer.inspectVideo(url)
        XCTAssertEqual(video.frames.count, 3)
        XCTAssertEqual(video.frames.map(\.pts), [0, 1.0 / 30, 2.0 / 30])
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
