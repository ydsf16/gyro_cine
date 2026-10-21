import XCTest
import simd
@testable import GyroCine

final class PreviewColorTransformTests: XCTestCase {
    func testExplicitColorSpaceDefaultsAndLegacyMigration() {
        XCTAssertFalse(RecordingColorSpace.selectableCases.contains(.systemDefault))
        XCTAssertEqual(RecordingColorSpace.restored(nil), .rec709)
        XCTAssertEqual(RecordingColorSpace.restored("systemDefault"), .rec709)
        XCTAssertEqual(RecordingColorSpace.restored("rec2020HDR"), .rec2020HDR)
    }

    func testRAWAlwaysRejectsLUTBurnRecipe() throws {
        let defaults = UserDefaults.standard
        let oldBurn = defaults.object(forKey: "lutBurnEnabled")
        let oldPreview = defaults.object(forKey: "previewLUTEnabled")
        defer {
            defaults.set(oldBurn, forKey: "lutBurnEnabled")
            defaults.set(oldPreview, forKey: "previewLUTEnabled")
        }
        defaults.set(true, forKey: "lutBurnEnabled"); defaults.set(true, forKey: "previewLUTEnabled")
        for encoding: VideoEncoding in [.proResRAW, .proResRAWHQ] {
            XCTAssertNil(try LUTBurnRecipe.snapshot(encoding: encoding, profile: .appleLog2,
                directory: FileManager.default.temporaryDirectory))
        }
    }

    func testImportedLUTCopiesPersistsAndDeletesOnlyItsOwnFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("My Look.cube")
        try ("LUT_3D_SIZE 2\n" + Array(repeating: "1 0 0", count: 8).joined(separator: "\n"))
            .write(to: source, atomically: true, encoding: .utf8)
        let item = try PreviewLUTLibrary.importFile(source, in: library)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(PreviewLUTLibrary.load(in: library), [item])
        let data = try PreviewLUTLibrary.cube(item, profile: .rec709, in: library)
        XCTAssertEqual(data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(4)) }, [1, 0, 0, 1])
        let other = library.appendingPathComponent("untouched.txt")
        try Data("keep".utf8).write(to: other)
        try PreviewLUTLibrary.remove(item, in: library)
        XCTAssertTrue(PreviewLUTLibrary.load(in: library).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.file(in: library).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testImportedLUTRejectsInvalidAndOversizedFilesWithoutSaving() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("invalid.cube")
        for text in ["LUT_3D_SIZE 2\n0 0 0", "LUT_1D_SIZE 2\n0 0 0", "LUT_3D_SIZE 9999"] {
            try text.write(to: source, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try PreviewLUTLibrary.importFile(source, in: library))
        }
        try Data(repeating: 32, count: 16 * 1024 * 1024 + 1).write(to: source)
        XCTAssertThrowsError(try PreviewLUTLibrary.importFile(source, in: library))
        XCTAssertTrue(PreviewLUTLibrary.load(in: library).isEmpty)
    }

    func testSourceLUTDoesNotApplyLogConversionTwice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var lines = ["LUT_3D_SIZE 2"]
        for b in 0...1 { for g in 0...1 { for r in 0...1 { lines.append("\(r) \(g) \(b)") } } }
        let source = root.appendingPathComponent("identity.cube")
        try lines.joined(separator: "\n").write(to: source, atomically: true, encoding: .utf8)
        let item = try PreviewLUTLibrary.importFile(source, in: root)
        for profile: PreviewColorTransform.Profile in [.rec709, .appleLog, .appleLog2] {
            let direct = try PreviewLUTLibrary.cube(item, profile: profile, in: root)
            XCTAssertEqual(direct, PreviewColorTransform.cube(.rec709))
        }
    }

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
    func testCubeInterpolationAndValidation() throws {
        var lines = ["LUT_3D_SIZE 2", "DOMAIN_MIN 0 0 0", "DOMAIN_MAX 1 1 1"]
        for b in 0...1 { for g in 0...1 { for r in 0...1 { lines.append("\(b) \(r) \(g)") } } }
        let cube = try CubeLook(text: lines.joined(separator: "\n"))
        let sample = cube.sample(SIMD3(0.2, 0.4, 0.8))
        XCTAssertEqual(sample.x, 0.8, accuracy: 1e-9)
        XCTAssertEqual(sample.y, 0.2, accuracy: 1e-9)
        XCTAssertEqual(sample.z, 0.4, accuracy: 1e-9)
        XCTAssertThrowsError(try CubeLook(text: "LUT_3D_SIZE 1000"))
        XCTAssertThrowsError(try CubeLook(text: "LUT_3D_SIZE 2\n0 0 0"))
        XCTAssertThrowsError(try CubeLook(text: lines.joined(separator: "\n") + "\nnan 0 0"))
    }
    func testBundledLooksAndComposedCubes() throws {
        let technical = PreviewColorTransform.cube(.appleLog2)
        var distinct = Set<Data>()
        for look in PreviewLook.allCases where look != .rec709 {
            let cube = try XCTUnwrap(look.load(bundle: Bundle(for: CameraManager.self)))
            XCTAssertEqual(cube.dimension, 33)
            let composed = cube.compose(technical: technical)
            XCTAssertEqual(composed.count, technical.count)
            distinct.insert(composed)
            composed.withUnsafeBytes { raw in
                for v in raw.bindMemory(to: Float.self) { XCTAssertTrue(v.isFinite && v >= 0 && v <= 1) }
            }
        }
        XCTAssertEqual(distinct.count, 5)
        XCTAssertFalse(distinct.contains(technical))
    }

}
