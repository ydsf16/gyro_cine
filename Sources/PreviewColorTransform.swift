import CoreImage
import simd

/// Technical monitoring transform, generated once. Never used by either recorder.
/// Apple Log equation and gamut chromaticities: Apple white paper / OCIO AppleCameras.cpp.
/// https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/main/src/OpenColorIO/transforms/builtins/AppleCameras.cpp
/// This is our SDR viewing transform, not Apple's proprietary creative LUT.
enum PreviewColorTransform {
    enum Profile: String { case appleLog, appleLog2, rec709 }
    static let dimension = 33
    static func decodeLog(_ v: Double) -> Double {
        let threshold = 47.28711236 * pow(0.01 + 0.05641088, 2)
        return v >= threshold ? pow(2, (v - 0.69336945) / 0.08550479) - 0.00964052
            : sqrt(max(v, 0) / 47.28711236) - 0.05641088
    }
    static func encode709(_ linear: Double) -> Double {
        // Preserve diffuse values; compress highlights smoothly into SDR headroom.
        let x = max(0, linear)
        let mapped = x <= 0.8 ? x : 0.8 + 0.2 * (1 - exp(-(x - 0.8) / 0.2))
        return mapped < 0.018 ? 4.5 * mapped : 1.099 * pow(mapped, 0.45) - 0.099
    }
    private static func rgbToXYZ(_ xy: [SIMD2<Double>]) -> simd_double3x3 {
        let columns = xy.map { SIMD3($0.x / $0.y, 1, (1 - $0.x - $0.y) / $0.y) }
        let base = simd_double3x3(columns: (columns[0], columns[1], columns[2]))
        let scale = base.inverse * SIMD3(0.3127 / 0.3290, 1, (1 - 0.3127 - 0.3290) / 0.3290)
        return simd_double3x3(columns: (columns[0] * scale.x, columns[1] * scale.y, columns[2] * scale.z))
    }
    static func matrix(_ profile: Profile) -> simd_double3x3 {
        let rec709 = rgbToXYZ([SIMD2(0.64, 0.33), SIMD2(0.30, 0.60), SIMD2(0.15, 0.06)])
        let source = profile == .appleLog2
            ? rgbToXYZ([SIMD2(0.725, 0.301), SIMD2(0.221, 0.814), SIMD2(0.068, -0.076)])
            : rgbToXYZ([SIMD2(0.708, 0.292), SIMD2(0.170, 0.797), SIMD2(0.131, 0.046)])
        return rec709.inverse * source
    }
    static func convert(_ rgb: SIMD3<Double>, profile: Profile) -> SIMD3<Double> {
        if profile == .rec709 { return rgb }
        return convert(rgb, matrix: matrix(profile))
    }
    private static func convert(_ rgb: SIMD3<Double>, matrix: simd_double3x3) -> SIMD3<Double> {
        let linear = matrix * SIMD3(decodeLog(rgb.x), decodeLog(rgb.y), decodeLog(rgb.z))
        return SIMD3(encode709(linear.x), encode709(linear.y), encode709(linear.z))
    }
    static func cube(_ profile: Profile) -> Data {
        var values = [Float](); values.reserveCapacity(dimension * dimension * dimension * 4)
        let matrix = matrix(profile)
        for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
            let rgb = SIMD3(Double(r), Double(g), Double(b)) / Double(dimension - 1)
            let mapped = profile == .rec709 ? rgb : convert(rgb, matrix: matrix)
            values.append(contentsOf: [Float(mapped.x), Float(mapped.y), Float(mapped.z), 1])
        } } }
        return values.withUnsafeBytes { Data($0) }
    }
}
