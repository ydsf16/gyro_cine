import XCTest
import AVFoundation
@testable import GyroCine

final class CameraControlsTests: XCTestCase {
    func testGravityRejectsStaleFlatAndAmbiguousReadings() {
        let valid = RecordingGravity(timestamp: 10, x: -1, y: 0, z: 0)
        XCTAssertEqual(valid.direction(at: 10.05), .landscapeRight)
        XCTAssertNil(valid.direction(at: 10.6))
        XCTAssertNil(valid.direction(at: 9.9))
        XCTAssertNil(RecordingGravity(timestamp: 10, x: 0, y: 0, z: 1).direction(at: 10))
        XCTAssertNil(RecordingGravity(timestamp: 10, x: 0.7, y: -0.7, z: 0).direction(at: 10))
        XCTAssertEqual(RecordingOrientation.previewAngle(for: .portrait), 90)
        XCTAssertEqual(RecordingOrientation.previewAngle(for: .portraitUpsideDown), 270)
        XCTAssertNil(RecordingOrientation.previewAngle(for: .unknown))
        // Portrait-locked UI stays portrait while physical recording is landscape.
        XCTAssertEqual(valid.direction(at: 10), .landscapeRight)
        XCTAssertEqual(RecordingOrientation.previewAngle(for: .portrait), 90)
    }

    func testFullTransformValidationAcrossSensorSizes() {
        for (w, h) in [(1920, 1080), (3840, 2160), (3840, 2880), (4032, 3024), (4224, 2240), (4224, 3024)] {
            for direction in [RecordingOrientation.landscapeRight, .portrait, .landscapeLeft, .portraitUpsideDown] {
                let transform = direction.movieTransform(width: w, height: h)
                XCTAssertTrue(direction.matchesMovieTransform(transform, width: w, height: h))
                var wrong = transform; wrong.tx += 1
                XCTAssertFalse(direction.matchesMovieTransform(wrong, width: w, height: h))
                wrong = transform; wrong.c *= -1; wrong.d *= -1
                XCTAssertFalse(direction.matchesMovieTransform(wrong, width: w, height: h))
            }
        }
    }

    func testRecordingDirectionUsesGravityIndependentlyOfInterfaceLock() {
        XCTAssertEqual(RecordingOrientation.fromGravity(x: 0, y: -1, z: 0), .portrait)
        XCTAssertEqual(RecordingOrientation.fromGravity(x: -1, y: 0, z: 0), .landscapeRight)
        XCTAssertEqual(RecordingOrientation.fromGravity(x: 1, y: 0, z: 0), .landscapeLeft)
        XCTAssertEqual(RecordingOrientation.fromGravity(x: 0, y: 1, z: 0), .portraitUpsideDown)
        XCTAssertNil(RecordingOrientation.fromGravity(x: 0.1, y: 0.1, z: -0.99))
        XCTAssertNil(RecordingOrientation.fromGravity(x: .nan, y: 0, z: 0))
    }
    func testMovieTransformsKeepAllFourOrientationsInPositiveBounds() {
        for orientation in [RecordingOrientation.landscapeRight, .portrait, .landscapeLeft, .portraitUpsideDown] {
            let bounds = CGRect(x: 0, y: 0, width: 3840, height: 2160)
                .applying(orientation.movieTransform(width: 3840, height: 2160))
            XCTAssertEqual(bounds.origin, .zero)
            XCTAssertEqual(bounds.width, orientation.isPortrait ? 2160 : 3840)
            XCTAssertEqual(bounds.height, orientation.isPortrait ? 3840 : 2160)
        }
    }
    func testCodecOptionsHideH264() async {
        XCTAssertEqual(RecordingCodec.selectableCases, [.hevc, .proResRAW, .proResRAWHQ])
        let options = await MainActor.run { RecorderViewModel().codecOptions }
        XCTAssertFalse(options.contains(.h264))
        XCTAssertFalse(options.contains(.proRes422))
        XCTAssertFalse(options.contains(.proRes422HQ))
    }
    func testResolutionBadges() {
        XCTAssertEqual(CameraMode(width: 4224, height: 3024, fps: 30, formatIndex: 0).resolutionBadge, "Gate")
        XCTAssertEqual(CameraMode(width: 4224, height: 2240, fps: 30, formatIndex: 0).resolutionBadge, "4K")
        XCTAssertEqual(CameraMode(width: 3840, height: 2160, fps: 30, formatIndex: 0).resolutionBadge, "4K")
        XCTAssertEqual(CameraMode(width: 1920, height: 1080, fps: 30, formatIndex: 0).resolutionBadge, "HD")
    }
    func testCodecContracts() {
        XCTAssertFalse(RecordingCodec.h264.isRAW)
        XCTAssertFalse(RecordingCodec.hevc.isRAW)
        XCTAssertTrue(RecordingCodec.proResRAW.isRAW)
        XCTAssertTrue(RecordingCodec.proResRAWHQ.isRAW)
        XCTAssertEqual(RecordingCodec.h264.avCodec, .h264)
        XCTAssertEqual(RecordingCodec.h264.fourCC, "avc1")
        XCTAssertEqual(RecordingCodec.proResRAWHQ.fourCC, "aprh")
        XCTAssertEqual(RecordingCodec.proRes422.fourCC, "apcn")
        XCTAssertEqual(RecordingCodec.proRes422HQ.fourCC, "apch")
    }
    func testPresentationRotationPreservesSensorAxes() {
        let source = [1.0, 2.0, 3.0]
        XCTAssertEqual(RecordingOrientation.landscapeRight.remap(source), [1, 2, 3])
        XCTAssertEqual(RecordingOrientation.portrait.remap(source), [1, 2, 3])
        XCTAssertEqual(RecordingOrientation.landscapeLeft.remap(source), [1, 2, 3])
        XCTAssertEqual(RecordingOrientation.portraitUpsideDown.remap(source), [1, 2, 3])
        for orientation in [RecordingOrientation.landscapeRight, .portrait, .landscapeLeft, .portraitUpsideDown] {
            XCTAssertEqual(orientation.remap(source).map { $0 * $0 }.reduce(0, +), 14)
            XCTAssertEqual(orientation.imuOrientation, "XYZ")
        }
    }
    func testWhiteBalanceGainsAreValidWhenSwitchingRawLenses() {
        let gains = CameraControls.validWhiteBalanceGains(.init(redGain: .nan, greenGain: 0.5, blueGain: 9), maximum: 4)
        XCTAssertEqual(gains.redGain, 1)
        XCTAssertEqual(gains.greenGain, 1)
        XCTAssertEqual(gains.blueGain, 4)
    }
    func testGainAndISOSafety() {
        XCTAssertEqual(CameraControls.clamped(.nan, minimum: 1, maximum: 4), 1)
        XCTAssertEqual(CameraControls.clamped(-2, minimum: 1, maximum: 4), 1)
        XCTAssertEqual(CameraControls.clamped(9, minimum: 1, maximum: 4), 4)
        XCTAssertEqual(CameraControls.clamped(2, minimum: 1, maximum: 4), 2)
    }
}
