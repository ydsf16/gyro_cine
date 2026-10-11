import AVFoundation

struct CameraMode: Hashable, Identifiable {
    let width: Int
    let height: Int
    let fps: Int
    let formatIndex: Int
    var id: String { "\(width)x\(height)@\(fps)#\(formatIndex)" }
    var label: String { "\(width)×\(height) · \(fps) fps" }
    var resolutionBadge: String {
        switch (width, height) {
        case (4224, 3024): "Gate"
        case (4224, 2240), (3840, 2160): "4K"
        case (1920, 1080): "HD"
        default: "\(width)×\(height)"
        }
    }
    var resolutionLabel: String {
        let kind: String
        switch (width, height) {
        case (4224, 3024): kind = "Open Gate"
        case (4224, 2240): kind = "4K RAW"
        case (3840, 2160): kind = "4K 16:9"
        case (3840, 2880), (4032, 3024), (4096, 3072): kind = "4K 4:3"
        case (4096, 2160): kind = "4K DCI"
        case (1920, 1080): kind = "HD 16:9"
        default: kind = resolutionBadge
        }
        return "\(kind) · \(width)×\(height)"
    }
    static func preferred(in modes: [CameraMode], previous: CameraMode?) -> CameraMode? {
        if let previous, let match = modes.first(where: {
            $0.width == previous.width && $0.height == previous.height && $0.fps == previous.fps
        }) { return match }
        let priorities = [(3840, 2160, 60), (4224, 2240, 60),
                          (3840, 2160, 30), (4224, 2240, 30),
                          (1920, 1080, 60), (1920, 1080, 30)]
        for (width, height, fps) in priorities {
            if let match = modes.first(where: { $0.width == width && $0.height == height && $0.fps == fps }) {
                return match
            }
        }
        return modes.first(where: { $0.fps == 30 }) ?? modes.first
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

    static func lenses(position: AVCaptureDevice.Position = .back) -> [CameraLens] {
        let physical = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera,
            .builtInWideAngleCamera, .builtInTelephotoCamera], mediaType: .video, position: position).devices
        let virtual = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTripleCamera,
            .builtInDualWideCamera, .builtInDualCamera], mediaType: .video, position: position).devices
        var ratios: [String: Double] = [:]
        for camera in virtual.sorted(by: { $0.constituentDevices.count > $1.constituentDevices.count }) {
            let devices = camera.constituentDevices
            guard let wide = devices.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }),
                  let factors = normalizedLensFactors(camera.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue), wideIndex: wide),
                  factors.count == devices.count else { continue }
            for (device, ratio) in zip(devices, factors) where ratios[device.uniqueID] == nil { ratios[device.uniqueID] = ratio }
        }
        return physical.filter { position != .front || $0.deviceType == .builtInWideAngleCamera }.map { camera in
            let name = position == .front ? "前置" : camera.deviceType == .builtInUltraWideCamera ? "超广角" : camera.deviceType == .builtInTelephotoCamera ? "长焦" : "主摄"
            return CameraLens(id: camera.uniqueID, name: name, deviceType: camera.deviceType.rawValue,
                displayMultiplier: camera.deviceType == .builtInWideAngleCamera ? 1 : ratios[camera.uniqueID],
                supports4K30: hevcModes(device: camera).contains { $0.width == 3840 && $0.height == 2160 && $0.fps == 30 })
        }.sorted { ($0.displayMultiplier ?? 99) < ($1.displayMultiplier ?? 99) }
    }

    static func device(id: String) -> AVCaptureDevice? { AVCaptureDevice(uniqueID: id) }

    static func mainCamera() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    static func modes(device: AVCaptureDevice, codec: RecordingCodec, color: RecordingColorSpace? = nil) -> [CameraMode] {
        var result: [CameraMode] = []
        var seen = Set<String>()
        for (index, format) in device.formats.enumerated() {
            if !codec.isRAW, let color, !format.supportedColorSpaces.contains(color.captureSpace) { continue }
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let isBayer = CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_96VersatileBayerPacked12
            guard isBayer == codec.isRAW else { continue }
            let standardVideoSizes = [(1280, 720), (1920, 1080), (2560, 1440), (3840, 2160), (3840, 2880), (4032, 3024), (4096, 2160), (4096, 3072)]
            if !codec.isRAW && !standardVideoSizes.contains(where: { $0.0 == Int(d.width) && $0.1 == Int(d.height) }) { continue }
            let frameRates = codec.isRAW ? [24, 25, 30, 50, 60] : [24, 25, 30, 50, 60, 120, 240]
            for fps in frameRates where format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) }) {
                let key = "\(d.width)x\(d.height)@\(fps)"
                guard seen.insert(key).inserted else { continue }
                result.append(CameraMode(width: Int(d.width), height: Int(d.height), fps: fps, formatIndex: index))
            }
        }
        return result.sorted { $0.width * $0.height == $1.width * $1.height ? $0.fps < $1.fps : $0.width * $0.height < $1.width * $1.height }
    }

    static func hevcModes(device: AVCaptureDevice) -> [CameraMode] { modes(device: device, codec: .hevc) }
}
