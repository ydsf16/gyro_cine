import XCTest
import AVFoundation
@testable import GyroCine

final class CaptureFrameCopierTests: XCTestCase {
    func testBackpressureRetainsOrderAndBound() throws {
        var queue = PendingVideoQueue<Int>(capacity: 3)
        try queue.enqueue(1); try queue.enqueue(2); try queue.enqueue(3)
        var written: [Int] = []
        try queue.drain(ready: { false }, write: { written.append($0) })
        XCTAssertEqual(queue.count, 3)
        XCTAssertThrowsError(try queue.enqueue(4))
        try queue.drain(ready: { written.count < 1 }, write: { written.append($0) })
        XCTAssertEqual(written, [1]); XCTAssertEqual(queue.count, 2)
        try queue.drain(ready: { true }, write: { written.append($0) })
        XCTAssertEqual(written, [1, 2, 3]); XCTAssertEqual(queue.count, 0)
        try queue.enqueue(4); try queue.enqueue(5)
        XCTAssertThrowsError(try queue.drain(ready: { true }) { frame in
            written.append(frame)
            throw NSError(domain: "evidence write", code: 1)
        })
        XCTAssertEqual(queue.count, 1)
        try queue.drain(ready: { true }, write: { written.append($0) })
        XCTAssertEqual(written, [1, 2, 3, 4, 5])
    }

    func testBiPlanarCopiesAndPoolLimit() throws {
        var image: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &image), kCVReturnSuccess)
        let source = try XCTUnwrap(image)
        CVPixelBufferLockBaseAddress(source, [])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(source, plane), Int32(40 + plane),
                CVPixelBufferGetBytesPerRowOfPlane(source, plane) * CVPixelBufferGetHeightOfPlane(source, plane))
        }
        CVPixelBufferUnlockBaseAddress(source, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: source,
            formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: source,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        let original = try XCTUnwrap(sample), copier = CaptureFrameCopier()
        var held: [CMSampleBuffer] = []
        for _ in 0..<48 { held.append(try copier.copy(original)) }
        XCTAssertThrowsError(try copier.copy(original))
        let frameBytes = (0..<2).reduce(0) { total, plane in
            total + CVPixelBufferGetBytesPerRowOfPlane(source, plane) * CVPixelBufferGetHeightOfPlane(source, plane)
        }
        let bounded = CaptureFrameCopier(maxFrames: 8,
            byteBudget: max(frameBytes, CVPixelBufferGetDataSize(source)) * 2)
        let first = try bounded.copy(original)
        let second = try bounded.copy(original)
        XCTAssertThrowsError(try bounded.copy(original))
        XCTAssertNotNil(CMSampleBufferGetImageBuffer(first))
        XCTAssertNotNil(CMSampleBufferGetImageBuffer(second))
        let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(held[0]))
        XCTAssertLessThan(CVPixelBufferGetDataSize(pixels), CVPixelBufferGetDataSize(source) * 2)
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        for plane in 0..<2 {
            let ptr = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixels, plane)).assumingMemoryBound(to: UInt8.self)
            for row in 0..<CVPixelBufferGetHeightOfPlane(pixels, plane) {
                for byte in 0..<64 { XCTAssertEqual(ptr[row * CVPixelBufferGetBytesPerRowOfPlane(pixels, plane) + byte], UInt8(40 + plane)) }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
    }

    func testCopyOwnsPixelsAndPreservesTimingAndAttachments() throws {
        var image: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 8, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &image), kCVReturnSuccess)
        let source = try XCTUnwrap(image)
        CVPixelBufferLockBaseAddress(source, [])
        memset(CVPixelBufferGetBaseAddress(source), 0x5A, CVPixelBufferGetBytesPerRow(source) * 8)
        CVPixelBufferUnlockBaseAddress(source, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: source,
            formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: 1234567, timescale: 60000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: source,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        let original = try XCTUnwrap(sample)
        CMSetAttachment(original, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
            value: Data([1, 2, 3]) as CFData, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        let copy = try CaptureFrameCopier().copy(original)
        let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(copy))
        XCTAssertFalse(source === pixels)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(copy), timing.presentationTimeStamp)
        XCTAssertEqual(CMSampleBufferGetDuration(copy), timing.duration)
        XCTAssertEqual(CMGetAttachment(copy, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
            attachmentModeOut: nil) as? Data, Data([1, 2, 3]))
        CVPixelBufferLockBaseAddress(source, [])
        memset(CVPixelBufferGetBaseAddress(source), 0, CVPixelBufferGetBytesPerRow(source) * 8)
        CVPixelBufferUnlockBaseAddress(source, [])
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        for row in 0..<8 {
            for byte in 0..<256 { XCTAssertEqual(base[row * CVPixelBufferGetBytesPerRow(pixels) + byte], 0x5A) }
        }
    }
}
