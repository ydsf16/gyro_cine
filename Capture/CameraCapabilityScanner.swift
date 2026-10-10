import AVFoundation

struct CameraMode: Hashable, Identifiable {
    let width: Int
    let height: Int
    let fps: Int
    let formatIndex: Int
    var id: String { "\(width)x\(height)@\(fps)#\(formatIndex)" }
    var label: String { "\(width)×\(height) · \(fps) fps" }
}

enum CameraCapabilityScanner {
    static func mainCamera() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    static func hevcModes(device: AVCaptureDevice) -> [CameraMode] {
        device.formats.enumerated().compactMap { index, format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width == 3840, dimensions.height == 2160,
                  format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) else { return nil }
            return CameraMode(width: 3840, height: 2160, fps: 30, formatIndex: index)
        }
    }
}
