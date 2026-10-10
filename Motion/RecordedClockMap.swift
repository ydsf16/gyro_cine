import Foundation

/// Fit paired per-frame host and encoded-video times; centered to retain precision.
struct RecordedClockMap: Codable {
    let origin: Double
    let slope: Double
    let intercept: Double
    let maxResidual: Double

    init(host: [Double], video: [Double]) throws {
        guard host.count == video.count, host.count >= 2,
              (host + video).allSatisfy(\.isFinite),
              zip(host, host.dropFirst()).allSatisfy({ $0 < $1 }),
              zip(video, video.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw RecorderError.unavailable("Invalid clock correspondence")
        }
        origin = host[0]
        let x = host.map { $0 - host[0] }
        let mx = x.reduce(0, +) / Double(x.count)
        let my = video.reduce(0, +) / Double(video.count)
        let denominator = x.reduce(0) { $0 + pow($1 - mx, 2) }
        guard denominator > 0 else { throw RecorderError.unavailable("Insufficient clock span") }
        slope = zip(x, video).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / denominator
        intercept = my - slope * mx
        let a = slope, b = intercept
        maxResidual = zip(x, video).map { abs($1 - (a * $0 + b)) }.max() ?? 0
        guard (0.999...1.001).contains(slope), maxResidual <= 0.001 else {
            throw RecorderError.unavailable("Clock fit outside 1000 ppm or 1ms residual; raw files retained")
        }
    }

    func videoSeconds(for host: Double) -> Double { (host - origin) * slope + intercept }
}
