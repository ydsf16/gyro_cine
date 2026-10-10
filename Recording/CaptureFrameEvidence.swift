import AVFoundation
import simd

// Own diagnostic format: source PTS and API-provided K, never hardware readout timestamps.
struct CaptureFrameEvidence: Codable {
    var hostPTSSeconds: Double? = nil
    let sourcePTSSeconds: Double
    let cameraIntrinsicMatrix: [Double]?
    let intrinsicSource: String
    let activeVideoStabilizationMode: Int

    static func intrinsicMatrix(_ sample: CMSampleBuffer) -> [Double]? {
        guard let attachment = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                               attachmentModeOut: nil), CFGetTypeID(attachment) == CFDataGetTypeID() else { return nil }
        let data = attachment as! CFData
        guard CFDataGetLength(data) >= MemoryLayout<simd_float3x3>.size else { return nil }
        var matrix = matrix_identity_float3x3
        withUnsafeMutableBytes(of: &matrix) { bytes in
            bytes.copyBytes(from: UnsafeRawBufferPointer(start: CFDataGetBytePtr(data), count: MemoryLayout<simd_float3x3>.size))
        }
        let values = (0..<3).flatMap { row in (0..<3).map { col in Double(matrix[col][row]) } }
        guard values.allSatisfy(\.isFinite), values[0] > 0, values[4] > 0 else { return nil }
        return values
    }
}
