import AVFoundation

/// Prevent the encoder from retaining the capture device's small source pool.
/// Copies native pixels (including Bayer) and metadata, without color conversion or timestamp changes.
final class CaptureFrameCopier {
    private(set) var capacityDescription = "not allocated"
    private var pool: CVPixelBufferPool?
    private var signature: [Int] = []
    func copy(_ source: CMSampleBuffer) throws -> CMSampleBuffer {
        guard let image = CMSampleBufferGetImageBuffer(source),
              let format = CMSampleBufferGetFormatDescription(source) else { throw failure("missing image") }
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        let pixelFormat = CVPixelBufferGetPixelFormatType(image)
        let key = [width, height, Int(pixelFormat)]
        if signature != key || pool == nil {
            let attrs: [String: Any] = [kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferBytesPerRowAlignmentKey as String: CVPixelBufferGetBytesPerRow(image),
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess else {
                throw failure("cannot allocate frame pool")
            }
            signature = key
        }
        guard let pool else { throw failure("missing pool") }
        // Bound encoder-owned copies to 48 frames and approximately 768 MB.
        let count = max(1, min(48, 768_000_000 / max(1, CVPixelBufferGetDataSize(image))))
        capacityDescription = "frameBytes=\(CVPixelBufferGetDataSize(image)) maxFrames=\(count) budgetBytes=768000000"
        var copied: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey as String: count] as CFDictionary, &copied)
        guard status == kCVReturnSuccess, let copied else { throw failure("pool exhausted (\(status)); try lower frame rate") }
        guard CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { throw failure("source lock") }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard CVPixelBufferLockBaseAddress(copied, []) == kCVReturnSuccess else { throw failure("copy lock") }
        defer { CVPixelBufferUnlockBaseAddress(copied, []) }
        let planes = CVPixelBufferGetPlaneCount(image)
        guard planes == CVPixelBufferGetPlaneCount(copied) else { throw failure("plane layout") }
        for plane in 0..<max(1, planes) {
            let src = planes == 0 ? CVPixelBufferGetBaseAddress(image) : CVPixelBufferGetBaseAddressOfPlane(image, plane)
            let dst = planes == 0 ? CVPixelBufferGetBaseAddress(copied) : CVPixelBufferGetBaseAddressOfPlane(copied, plane)
            let srcStride = planes == 0 ? CVPixelBufferGetBytesPerRow(image) : CVPixelBufferGetBytesPerRowOfPlane(image, plane)
            let dstStride = planes == 0 ? CVPixelBufferGetBytesPerRow(copied) : CVPixelBufferGetBytesPerRowOfPlane(copied, plane)
            let rows = planes == 0 ? height : CVPixelBufferGetHeightOfPlane(image, plane)
            guard let src, let dst, srcStride > 0, dstStride >= srcStride else { throw failure("incompatible pixel stride") }
            for row in 0..<rows { memcpy(dst.advanced(by: row * dstStride), src.advanced(by: row * srcStride), srcStride) }
        }
        for mode in [CVAttachmentMode.shouldPropagate, .shouldNotPropagate] {
            if let attachments = CVBufferCopyAttachments(image, mode) { CVBufferSetAttachments(copied, attachments, mode) }
        }
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(source, at: 0, timingInfoOut: &timing) == noErr else { throw failure("timing") }
        var copiedFormat: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: copied,
            formatDescriptionOut: &copiedFormat) == noErr, let copiedFormat else { throw failure("copy format") }
        // Keep camera-specific RAW extensions, while refreshing pixel layout fields
        // derived from the destination surface (stride/plane allocation can differ).
        var extensions = (CMFormatDescriptionGetExtensions(format) as? [String: Any]) ?? [:]
        for (key, value) in (CMFormatDescriptionGetExtensions(copiedFormat) as? [String: Any]) ?? [:] {
            extensions[key] = value
        }
        var mergedFormat: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(allocator: nil, codecType: pixelFormat,
            width: Int32(width), height: Int32(height), extensions: extensions as CFDictionary,
            formatDescriptionOut: &mergedFormat) == noErr, let mergedFormat,
            CMVideoFormatDescriptionMatchesImageBuffer(mergedFormat, imageBuffer: copied) else {
            throw failure("metadata/layout mismatch")
        }
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: copied,
            formatDescription: mergedFormat, sampleTiming: &timing, sampleBufferOut: &result) == noErr,
            let result else { throw failure("sample creation") }
        for mode in [kCMAttachmentMode_ShouldPropagate, kCMAttachmentMode_ShouldNotPropagate] {
            if let attachments = CMCopyDictionaryOfAttachments(allocator: nil, target: source, attachmentMode: mode) {
                CMSetAttachments(result, attachments: attachments, attachmentMode: mode)
            }
        }
        return result
    }
    private func failure(_ reason: String) -> RecorderError {
        .unavailable("Video buffer copy failed: \(reason). Original recording retained.")
    }
}

/// FIFO for transient encoder backpressure; the pixel pool separately bounds bytes.
struct PendingVideoQueue<Element> {
    let capacity: Int
    private(set) var elements: [Element] = []
    var count: Int { elements.count }
    mutating func enqueue(_ element: Element) throws {
        guard count < capacity else { throw RecorderError.unavailable("视频待写队列已满，编码器或磁盘持续写入过慢；原片已保留") }
        elements.append(element)
    }
    mutating func drain(ready: () -> Bool, write: (Element) throws -> Void) throws {
        while !elements.isEmpty && ready() {
            try write(elements[0])
            elements.removeFirst()
        }
    }
    mutating func removeAll() { elements.removeAll() }
}
