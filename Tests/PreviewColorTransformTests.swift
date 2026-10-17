import XCTest
import simd
@testable import GyroCine

final class PreviewColorTransformTests: XCTestCase {
    func testAppleLogReferencePoints() {
        XCTAssertEqual(PreviewColorTransform.decodeLog(0.69336945), 0.99035948, accuracy: 1e-8)
        XCTAssertEqual(PreviewColorTransform.decodeLog(0), -0.05641088, accuracy: 1e-8)
        // Inverse round trip at diffuse middle gray, toe breakpoint, and a bright highlight.
        for linear in [0.0, 0.01, 0.18, 4.0] {
            let encoded = linear < 0.01 ? 47.28711236 * pow(linear + 0.05641088, 2)
                : 0.08550479 * log2(linear + 0.00964052) + 0.69336945
            XCTAssertEqual(PreviewColorTransform.decodeLog(encoded), linear, accuracy: 1e-7)
        }
    }
    func testGamutPreservesD65AndMatchesBT2020Reference() {
        for p in [PreviewColorTransform.Profile.appleLog, .appleLog2] {
            let white = PreviewColorTransform.matrix(p) * SIMD3<Double>(repeating: 1)
            XCTAssertEqual(white.x, 1, accuracy: 1e-8)
            XCTAssertEqual(white.y, 1, accuracy: 1e-8)
            XCTAssertEqual(white.z, 1, accuracy: 1e-8)
        }
        let red = PreviewColorTransform.matrix(.appleLog) * SIMD3<Double>(1, 0, 0)
        XCTAssertEqual(red.x, 1.660491, accuracy: 1e-5)
        XCTAssertEqual(red.y, -0.124550, accuracy: 1e-5)
        XCTAssertEqual(red.z, -0.018151, accuracy: 1e-5)
    }
    func testLUTFiniteAndHighlightMonotonic() {
        for p in [PreviewColorTransform.Profile.appleLog, .appleLog2] {
            let data = PreviewColorTransform.cube(p)
            XCTAssertEqual(data.count, 33 * 33 * 33 * 4 * 4)
            data.withUnsafeBytes { raw in
                for v in raw.bindMemory(to: Float.self) { XCTAssertTrue(v.isFinite && v >= 0 && v <= 1.00001) }
            }
        }
        let samples = [0.0, 0.18, 0.8, 1, 2, 4].map(PreviewColorTransform.encode709)
        XCTAssertEqual(samples, samples.sorted())
        XCTAssertLessThan(samples.last!, 1)
        let rgb = SIMD3<Double>(0.1, 0.5, 0.9)
        XCTAssertEqual(PreviewColorTransform.convert(rgb, profile: .rec709), rgb)
    }
}
