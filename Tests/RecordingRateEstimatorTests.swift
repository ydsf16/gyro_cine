import XCTest
@testable import GyroCine

final class RecordingRateEstimatorTests: XCTestCase {
    func testWarmupThenUsesActualRateWithoutTheoreticalFloor() {
        var estimator = RecordingRateEstimator()
        estimator.observe(bytes: 4_000_000, at: 2)
        estimator.observe(bytes: 8_000_000, at: 4)
        XCTAssertNil(estimator.bytesPerSecond)
        estimator.observe(bytes: 12_000_000, at: 6)
        XCTAssertEqual(estimator.bytesPerSecond ?? 0, 2_000_000, accuracy: 1)
        XCTAssertEqual(RecordingRateEstimator.displayRate(live: estimator.bytesPerSecond,
            learned: 20_000_000, fallback: 50_000_000), 2_000_000)
    }

    func testBatchedFlushesAverageOverWindowInsteadOfUsingOneBurst() {
        var estimator = RecordingRateEstimator()
        for second in stride(from: 0, through: 24, by: 2) {
            let bytes = Int64(second / 4) * 4_000_000
            estimator.observe(bytes: bytes, at: Double(second))
        }
        XCTAssertEqual(estimator.bytesPerSecond ?? 0, 1_000_000, accuracy: 100_000)
        XCTAssertEqual(estimator.measuredSeconds, 12)
    }

    func testRateAdaptsToSceneChangeAndDoesNotStickToWholeClipAverage() {
        var estimator = RecordingRateEstimator()
        var bytes: Int64 = 0
        for second in stride(from: 0, through: 60, by: 2) {
            if second > 0 { bytes += second <= 20 ? 4_000_000 : 16_000_000 }
            estimator.observe(bytes: bytes, at: Double(second))
        }
        XCTAssertEqual(estimator.bytesPerSecond ?? 0, 8_000_000, accuracy: 100_000)
    }

    func testStalledOrInvalidSamplesCannotProduceInfiniteRemainingTime() {
        var estimator = RecordingRateEstimator()
        for second in stride(from: 0, through: 8, by: 2) {
            estimator.observe(bytes: Int64(second) * 1_000_000, at: Double(second))
        }
        for second in stride(from: 10, through: 40, by: 2) {
            estimator.observe(bytes: 8_000_000, at: Double(second))
        }
        let rate = estimator.bytesPerSecond
        XCTAssertGreaterThanOrEqual(rate ?? 0, 100_000)
        estimator.observe(bytes: -1, at: 42)
        estimator.observe(bytes: 8_000_000, at: .nan)
        XCTAssertEqual(estimator.bytesPerSecond, rate)
        estimator.observe(bytes: 0, at: 44) // New/truncated file resets the old rate.
        XCTAssertNil(estimator.bytesPerSecond)
    }

    func testStandbyUsesHistoryAndRejectsInvalidValues() {
        XCTAssertEqual(RecordingRateEstimator.displayRate(live: nil, learned: 2_000_000, fallback: 50_000_000), 2_000_000)
        XCTAssertEqual(RecordingRateEstimator.displayRate(live: .nan, learned: .infinity, fallback: 50_000_000), 50_000_000)
    }
}
