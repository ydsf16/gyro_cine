import AVFoundation

struct CameraMode: Hashable, Identifiable {
    let width: Int
    let height: Int
    let fps: Int
    let formatIndex: Int
    var id: String { "\(width)x\(height)@\(fps)#\(formatIndex)" }
    var label: String { "\(width)×\(height) · \(fps) fps" }
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
                supports4K30: !hevcModes(device: camera).isEmpty)
        }.sorted { ($0.displayMultiplier ?? 99) < ($1.displayMultiplier ?? 99) }
    }

    static func device(id: String) -> AVCaptureDevice? { AVCaptureDevice(uniqueID: id) }

    static func mainCamera() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    static func modes(device: AVCaptureDevice, codec: RecordingCodec) -> [CameraMode] {
        guard codec.isRAW else { return hevcModes(device: device) }
        guard #available(iOS 26.0, *) else { return [] }
        return device.formats.enumerated().compactMap { index, format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_96VersatileBayerPacked12,
                  format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) else { return nil }
            return CameraMode(width: Int(dimensions.width), height: Int(dimensions.height), fps: 30, formatIndex: index)
        }.sorted { $0.width * $0.height > $1.width * $1.height }
    }

    static func hevcModes(device: AVCaptureDevice) -> [CameraMode] {
        device.formats.enumerated().compactMap { index, format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard CMFormatDescriptionGetMediaSubType(format.formatDescription) != kCVPixelFormatType_96VersatileBayerPacked12,
                  dimensions.width == 3840, dimensions.height == 2160,
                  format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) else { return nil }
            return CameraMode(width: 3840, height: 2160, fps: 30, formatIndex: index)
        }
    }
}
