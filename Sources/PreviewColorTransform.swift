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

/// Display-referred looks. Applied after the technical RAW-to-709 transform.
enum PreviewLook: String, CaseIterable, Identifiable {
    case rec709, amber, fade, neon, film, portrait
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rec709: "Rec.709"
        case .amber: "暖阳 · Amber"
        case .fade: "褪色 · Fade"
        case .neon: "霓虹 · Neon"
        case .film: "电影 · Film"
        case .portrait: "人像 · Portrait"
        }
    }
    var filename: String? {
        switch self {
        case .rec709: nil
        case .amber: "slay-01-amber"
        case .fade: "slay-02-fade"
        case .neon: "slay-03-neon"
        case .film: "slay-04-film"
        case .portrait: "slay-05-portrait"
        }
    }
    func load(bundle: Bundle = .main) throws -> CubeLook? {
        guard let filename else { return nil }
        guard let url = bundle.url(forResource: filename, withExtension: "cube", subdirectory: "LUTs")
            ?? bundle.url(forResource: filename, withExtension: "cube") else { throw CubeLook.Invalid.file }
        return try CubeLook(text: String(contentsOf: url, encoding: .utf8))
    }
}

/// Strict 3D .cube reader; red varies fastest. Loading/composition runs off the capture queue.
struct CubeLook {
    enum Invalid: Error { case file, header, samples }
    let dimension: Int
    let values: [SIMD3<Double>]
    let minimum: SIMD3<Double>
    let maximum: SIMD3<Double>
    init(text: String) throws {
        var size: Int?
        var low = SIMD3<Double>(repeating: 0), high = SIMD3<Double>(repeating: 1)
        var samples: [SIMD3<Double>] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let tokens = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .split(whereSeparator: \.isWhitespace)
            guard let first = tokens.first else { continue }
            if first == "TITLE" { continue }
            if first == "LUT_3D_SIZE" {
                guard tokens.count == 2, size == nil, let n = Int(tokens[1]), (2...65).contains(n) else { throw Invalid.header }
                size = n; continue
            }
            if first == "DOMAIN_MIN" || first == "DOMAIN_MAX" {
                guard tokens.count == 4 else { throw Invalid.header }
                let v = tokens.dropFirst().compactMap { Double($0) }
                guard v.count == 3, v.allSatisfy(\.isFinite) else { throw Invalid.header }
                if first == "DOMAIN_MIN" { low = SIMD3(v[0], v[1], v[2]) } else { high = SIMD3(v[0], v[1], v[2]) }
                continue
            }
            let v = tokens.compactMap { Double($0) }
            guard tokens.count == 3, v.count == 3, v.allSatisfy(\.isFinite), samples.count < 65 * 65 * 65 else { throw Invalid.samples }
            samples.append(SIMD3(v[0], v[1], v[2]))
        }
        guard let size, samples.count == size * size * size,
              high.x > low.x, high.y > low.y, high.z > low.z else { throw Invalid.samples }
        dimension = size; values = samples; minimum = low; maximum = high
    }
    func sample(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let p = simd_clamp((rgb - minimum) / (maximum - minimum), .zero, SIMD3(repeating: 1)) * Double(dimension - 1)
        let lo = SIMD3(Int(p.x), Int(p.y), Int(p.z))
        let hi = SIMD3(min(lo.x + 1, dimension - 1), min(lo.y + 1, dimension - 1), min(lo.z + 1, dimension - 1))
        let f = p - SIMD3(Double(lo.x), Double(lo.y), Double(lo.z))
        func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Double> { values[(b * dimension + g) * dimension + r] }
        func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> { a + (b - a) * t }
        return mix(mix(mix(at(lo.x, lo.y, lo.z), at(hi.x, lo.y, lo.z), f.x),
                       mix(at(lo.x, hi.y, lo.z), at(hi.x, hi.y, lo.z), f.x), f.y),
                   mix(mix(at(lo.x, lo.y, hi.z), at(hi.x, lo.y, hi.z), f.x),
                       mix(at(lo.x, hi.y, hi.z), at(hi.x, hi.y, hi.z), f.x), f.y), f.z)
    }
    func compose(technical: Data) -> Data {
        var result = technical.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        for i in stride(from: 0, to: result.count, by: 4) {
            let rgb = sample(SIMD3(Double(result[i]), Double(result[i + 1]), Double(result[i + 2])))
            result[i] = Float(max(0, min(1, rgb.x)))
            result[i + 1] = Float(max(0, min(1, rgb.y)))
            result[i + 2] = Float(max(0, min(1, rgb.z)))
        }
        return result.withUnsafeBytes { Data($0) }
    }
}
