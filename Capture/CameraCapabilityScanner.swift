import AVFoundation

struct CameraMode: Hashable, Identifiable {
    let width: Int
    let height: Int
    let fps: Int
    let formatIndex: Int
    var id: String { "\(width)x\(height)@\(fps)#\(formatIndex)" }
    var label: String { "\(width)×\(height) · \(fps) fps" }
    static func preferred(in modes: [CameraMode], previous: CameraMode?) -> CameraMode? {
        modes.first { $0.width == previous?.width && $0.height == previous?.height && $0.fps == previous?.fps }
            ?? modes.first { $0.width == 1920 && $0.height == 1080 && $0.fps == 30 }
            ?? modes.first { $0.fps == 30 } ?? modes.first
    }
}

struct CameraLens: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let deviceType: String
    let displayMultiplier: Double?
    let supports4K30: Bool
    var label: String {
        guard let value = displayMultiplier else { return name }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
            .replacingOccurrences(of: ".0", with: "") + "×"
    }
}

enum CameraCapabilityScanner {
    static func normalizedLensFactors(_ switchFactors: [Double], wideIndex: Int) -> [Double]? {
        let factors = [1.0] + switchFactors
        guard factors.indices.contains(wideIndex), factors.allSatisfy({ $0.isFinite && $0 > 0 }),
              zip(factors, factors.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        return factors.map { $0 / factors[wideIndex] }
    }

    static func lenses() -> [CameraLens] {
        let physical = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera,
            .builtInWideAngleCamera, .builtInTelephotoCamera], mediaType: .video, position: .back).devices
        let virtual = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTripleCamera,
            .builtInDualWideCamera, .builtInDualCamera], mediaType: .video, position: .back).devices
        var ratios: [String: Double] = [:]
        for camera in virtual.sorted(by: { $0.constituentDevices.count > $1.constituentDevices.count }) {
            let devices = camera.constituentDevices
            guard let wide = devices.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }),
                  let factors = normalizedLensFactors(camera.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue), wideIndex: wide),
                  factors.count == devices.count else { continue }
            for (device, ratio) in zip(devices, factors) where ratios[device.uniqueID] == nil { ratios[device.uniqueID] = ratio }
        }
        return physical.map { camera in
            let name = camera.deviceType == .builtInUltraWideCamera ? "超广角" : camera.deviceType == .builtInTelephotoCamera ? "长焦" : "主摄"
            return CameraLens(id: camera.uniqueID, name: name, deviceType: camera.deviceType.rawValue,
                displayMultiplier: camera.deviceType == .builtInWideAngleCamera ? 1 : ratios[camera.uniqueID],
                supports4K30: hevcModes(device: camera).contains { $0.width == 3840 && $0.height == 2160 && $0.fps == 30 })
        }.sorted { ($0.displayMultiplier ?? 99) < ($1.displayMultiplier ?? 99) }
    }

    static func device(id: String) -> AVCaptureDevice? { AVCaptureDevice(uniqueID: id) }

    static func mainCamera() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    static func modes(device: AVCaptureDevice, codec: RecordingCodec) -> [CameraMode] {
        var result: [CameraMode] = []
        var seen = Set<String>()
        for (index, format) in device.formats.enumerated() {
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let isBayer = CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_96VersatileBayerPacked12
            guard isBayer == codec.isRAW else { continue }
            if !codec.isRAW && ![(1920, 1080), (3840, 2160)].contains(where: { $0.0 == Int(d.width) && $0.1 == Int(d.height) }) { continue }
            for fps in [24, 25, 30, 60] where format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) }) {
                let key = "\(d.width)x\(d.height)@\(fps)"
                guard seen.insert(key).inserted else { continue }
                result.append(CameraMode(width: Int(d.width), height: Int(d.height), fps: fps, formatIndex: index))
            }
        }
        return result.sorted { $0.width * $0.height == $1.width * $1.height ? $0.fps < $1.fps : $0.width * $0.height < $1.width * $1.height }
    }

    static func hevcModes(device: AVCaptureDevice) -> [CameraMode] { modes(device: device, codec: .hevc) }
}
