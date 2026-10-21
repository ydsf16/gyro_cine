import CoreImage
import simd

/// Technical monitoring transform; optional LUT burn-in uses the same mapping.
/// Apple Log equation and gamut chromaticities: Apple white paper / OCIO AppleCameras.cpp.
/// https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/main/src/OpenColorIO/transforms/builtins/AppleCameras.cpp
/// This is our SDR viewing transform, not Apple's proprietary creative LUT.
enum PreviewColorTransform {
    enum Profile: String { case appleLog, appleLog2, rec709, p3D65, rec2020HLG }
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
        let source: simd_double3x3
        switch profile {
        case .p3D65:
            source = rgbToXYZ([SIMD2(0.680, 0.320), SIMD2(0.265, 0.690), SIMD2(0.150, 0.060)])
        case .appleLog2:
            source = rgbToXYZ([SIMD2(0.725, 0.301), SIMD2(0.221, 0.814), SIMD2(0.068, -0.076)])
        default:
            source = rgbToXYZ([SIMD2(0.708, 0.292), SIMD2(0.170, 0.797), SIMD2(0.131, 0.046)])
        }
        return rec709.inverse * source
    }
    private static func decodeHLG(_ value: Double) -> Double {
        let a = 0.17883277, b = 0.28466892, c = 0.55991073
        return value <= 0.5 ? value * value / 3 : (exp((value - c) / a) + b) / 12
    }
    private static func decodeP3(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    static func convert(_ rgb: SIMD3<Double>, profile: Profile) -> SIMD3<Double> {
        if profile == .rec709 { return rgb }
        return convert(rgb, matrix: matrix(profile))
    }
    private static func convert(_ rgb: SIMD3<Double>, matrix: simd_double3x3) -> SIMD3<Double> {
        let linear = matrix * SIMD3(decodeLog(rgb.x), decodeLog(rgb.y), decodeLog(rgb.z))
        return SIMD3(encode709(linear.x), encode709(linear.y), encode709(linear.z))
    }
    private static func convert(_ rgb: SIMD3<Double>, profile: Profile,
                                matrix: simd_double3x3) -> SIMD3<Double> {
        let decode: (Double) -> Double = profile == .rec2020HLG ? decodeHLG : decodeP3
        let linear = matrix * SIMD3(decode(rgb.x), decode(rgb.y), decode(rgb.z))
        return SIMD3(encode709(linear.x), encode709(linear.y), encode709(linear.z))
    }
    static func cube(_ profile: Profile) -> Data {
        var values = [Float](); values.reserveCapacity(dimension * dimension * dimension * 4)
        let matrix = matrix(profile)
        for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
            let rgb = SIMD3(Double(r), Double(g), Double(b)) / Double(dimension - 1)
            let mapped: SIMD3<Double>
            switch profile {
            case .rec709: mapped = rgb
            case .p3D65, .rec2020HLG: mapped = convert(rgb, profile: profile, matrix: matrix)
            case .appleLog, .appleLog2: mapped = convert(rgb, matrix: matrix)
            }
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
        case .amber: AppText.value("暖阳 · Amber", "Amber", locale: .current)
        case .fade: AppText.value("褪色 · Fade", "Fade", locale: .current)
        case .neon: AppText.value("霓虹 · Neon", "Neon", locale: .current)
        case .film: AppText.value("电影 · Film", "Film", locale: .current)
        case .portrait: AppText.value("人像 · Portrait", "Portrait", locale: .current)
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

/// Imported files are copied into the app. No recording or encoder uses this library.
struct ImportedPreviewLUT: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    var selectionID: String { "custom:\(id.uuidString)" }
    func file(in directory: URL) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathExtension("cube") }
}

enum PreviewLUTLibrary {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PreviewLUTs", isDirectory: true)
    }
    enum ImportError: LocalizedError {
        case invalid, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalid: AppText.value("请选择有效的 3D .cube LUT（2–65 阶）。", "Choose a valid 3D .cube LUT (size 2–65).", locale: .current)
            case .tooLarge: AppText.value("LUT 文件不能超过 16 MB。", "LUT files must be 16 MB or smaller.", locale: .current)
            }
        }
    }
    static func load(in directory: URL = directory) -> [ImportedPreviewLUT] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("library.json")),
              let items = try? JSONDecoder().decode([ImportedPreviewLUT].self, from: data) else { return [] }
        return items.filter { FileManager.default.fileExists(atPath: $0.file(in: directory).path) }
    }
    static func save(_ items: [ImportedPreviewLUT], in directory: URL = directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(items).write(to: directory.appendingPathComponent("library.json"), options: .atomic)
    }
    static func importFile(_ url: URL, in directory: URL = directory) throws -> ImportedPreviewLUT {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.pathExtension.lowercased() == "cube" else { throw ImportError.invalid }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 16 * 1024 * 1024 else { throw ImportError.tooLarge }
        guard let text = String(data: data, encoding: .utf8), (try? CubeLook(text: text)) != nil else { throw ImportError.invalid }
        let item = ImportedPreviewLUT(id: UUID(), name: String(url.deletingPathExtension().lastPathComponent.prefix(80)))
        var items = load(in: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: item.file(in: directory), options: .atomic)
        items.append(item)
        do { try save(items, in: directory) }
        catch { try? FileManager.default.removeItem(at: item.file(in: directory)); throw error }
        return item
    }
    static func remove(_ item: ImportedPreviewLUT, in directory: URL = directory) throws {
        try save(load(in: directory).filter { $0.id != item.id }, in: directory)
        try FileManager.default.removeItem(at: item.file(in: directory))
    }
    static func cube(_ item: ImportedPreviewLUT, profile: PreviewColorTransform.Profile,
                     in directory: URL = directory) throws -> Data {
        let look = try CubeLook(text: String(contentsOf: item.file(in: directory), encoding: .utf8))
        // Custom LUTs map source values directly; their author defines the input color space.
        return look.compose(technical: PreviewColorTransform.cube(.rec709))
    }
}

// Durable snapshot: changing/deleting a library LUT after capture cannot alter a pending clip.
struct LUTBurnRecipe: Codable {
    let id: String
    let cube: Data
    let codec: String
    var highBitDepth: Bool? = nil
    static func snapshot(encoding: VideoEncoding, profile: RecordingColorSpace, directory: URL) throws -> LUTBurnRecipe? {
        let defaults = UserDefaults.standard
        guard !encoding.isRAW, defaults.bool(forKey: "lutBurnEnabled"), defaults.bool(forKey: "previewLUTEnabled") else { return nil }
        let technical: PreviewColorTransform.Profile
        switch profile {
        case .appleLog: technical = .appleLog
        case .appleLog2: technical = .appleLog2
        case .p3D65: technical = .p3D65
        case .rec2020HDR: technical = .rec2020HLG
        default: technical = .rec709
        }
        let cube: Data
        if let id = defaults.string(forKey: "previewImportedLUTID"),
           let item = PreviewLUTLibrary.load().first(where: { $0.selectionID == id }) {
            guard !(defaults.stringArray(forKey: "disabledLUTIDs") ?? []).contains(id) else {
                throw RecorderError.unavailable("LUT is disabled")
            }
            cube = try PreviewLUTLibrary.cube(item, profile: technical)
        } else {
            let look = PreviewLook(rawValue: defaults.string(forKey: "previewLUTLook") ?? "") ?? .rec709
            guard !(defaults.stringArray(forKey: "disabledLUTIDs") ?? []).contains(look.rawValue) else {
                throw RecorderError.unavailable("LUT is disabled")
            }
            let base = PreviewColorTransform.cube(technical)
            cube = try look.load()?.compose(technical: base) ?? base
        }
        var recipe = LUTBurnRecipe(id: UUID().uuidString, cube: cube, codec: encoding.codec.rawValue,
            highBitDepth: encoding.isProRes422 || [.appleLog, .appleLog2, .rec2020HDR].contains(profile))
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--lut-high-bit-smoke") { recipe.highBitDepth = true }
        #endif
        return recipe
    }
}
