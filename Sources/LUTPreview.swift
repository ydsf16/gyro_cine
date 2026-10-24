import AVFoundation
import CoreImage
import MetalKit

/// A bounded, preview-sized proxy. Recording never waits for its CPU/GPU work.
final class LUTPreview: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "GyroCine.LUTPreview", qos: .userInitiated)
    private let lock = NSLock()
    private let renderQueue = DispatchQueue(label: "GyroCine.LUTRender", qos: .userInitiated)
    private let gpuSlot = DispatchSemaphore(value: 1)
    private let sharedSlot = DispatchSemaphore(value: 1)
    private var usesSharedSource = false // lock protected
    let metalDevice = MTLCreateSystemDefaultDevice()
    private lazy var commands = metalDevice?.makeCommandQueue()
    private lazy var context: CIContext? = metalDevice.map {
        CIContext(mtlDevice: $0, options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    }
    private let preparationQueue = DispatchQueue(label: "GyroCine.LUTPrepare", qos: .userInitiated)
    private var technicalCubes: [PreviewColorTransform.Profile: Data] = [:] // preparation queue only
    private var cubes: [String: Data] = [:] // lock protected
    private var pendingCubes = Set<String>()
    private var failedCubes = Set<String>()
    private var look: PreviewLook = .rec709 // lock protected
    private var importedLook: ImportedPreviewLUT? // lock protected
    private var expectedColorSpace: RecordingColorSpace = .systemDefault // lock protected
    private var latest: (CVPixelBuffer, PreviewColorTransform.Profile, Data?, Double)?
    private var enabled = false
    private var rendered = 0 // render queue
    private weak var surface: CAMetalLayer? // lock protected
    private weak var surfaceView: UIView?
    private var surfaceSize = CGSize.zero
    private var displayActive = false
    private var foreground = true
    private var lastSubmittedTime = -Double.infinity
    private var lastSubmittedAt = 0.0
    private var rendering = false
    private var frameStride = 1 // capture queue
    private var watchdog: DispatchSourceTimer?
    private var metricGeneration = -1 // render queue
    private var metricStart = 0.0
    private var metricCount = 0
    private var cpuTotal = 0.0
    private var cpuMax = 0.0
    private var gpuTotal = 0.0
    private var gpuMax = 0.0
    private var gpuBusySkips = 0 // lock protected
    private var proxyDrops = 0 // capture queue
    private var count = 0
    private var generation = 0
    private var lastStatus = ""
    var log: ((String, [String: Any]) -> Void)?
    var statusChanged: ((String) -> Void)?
    override init() {
        super.init()
        output.automaticallyConfiguresOutputBufferDimensions = false
        output.deliversPreviewSizedOutputBuffers = true
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.checkStaleness() }
        timer.resume(); watchdog = timer
    }
    deinit { watchdog?.cancel() }
    /// Called on main for view/lifecycle changes only; never drives frame cadence.
    func attach(view: UIView, size: CGSize) {
        lock.lock(); surfaceView = view; surface = view.layer as? CAMetalLayer; surfaceSize = size; lock.unlock()
    }
    func setDisplayActive(_ value: Bool) {
        lock.lock()
        if displayActive != value { displayActive = value; latest = nil; generation += 1 }
        lock.unlock()
    }
    func setForeground(_ value: Bool) {
        lock.lock(); foreground = value; latest = nil; generation += 1; lock.unlock()
        report(value ? "preparing" : "off")
    }
    private func checkStaleness() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let stale = enabled && displayActive && foreground &&
            (now - (latest?.3 ?? 0) > 0.5 || (rendering && now - lastSubmittedAt > 0.25))
        lock.unlock()
        if stale { report("preparing") }
    }
    func setLook(_ value: PreviewLook) {
        lock.lock()
        let changed = look != value || importedLook != nil
        if changed { look = value; importedLook = nil; latest = nil; generation += 1 }
        lock.unlock()
        if changed { report("preparing") }
    }
    func setImportedLook(_ value: ImportedPreviewLUT) {
        lock.lock()
        let changed = importedLook != value
        if changed { importedLook = value; latest = nil; generation += 1 }
        lock.unlock()
        if changed { report("preparing") }
    }
    func setExpectedColorSpace(_ value: RecordingColorSpace) {
        lock.lock()
        if expectedColorSpace != value { expectedColorSpace = value; latest = nil; generation += 1 }
        lock.unlock()
    }
    private func preparedCube(profile: PreviewColorTransform.Profile, look: PreviewLook, imported: ImportedPreviewLUT?) -> Data? {
        let lookID = imported.map { $0.selectionID } ?? look.rawValue
        let key = "\(profile.rawValue):\(lookID)"
        lock.lock()
        if let cube = cubes[key] { lock.unlock(); return cube }
        if failedCubes.contains(key) { lock.unlock(); report("unavailable"); return nil }
        let start = pendingCubes.insert(key).inserted
        lock.unlock()
        if start {
            preparationQueue.async { [weak self] in
                guard let self else { return }
                do {
                    let technical = self.technicalCubes[profile] ?? PreviewColorTransform.cube(profile)
                    self.technicalCubes[profile] = technical
                    let cube = try imported.map { try PreviewLUTLibrary.cube($0, profile: profile) }
                        ?? look.load()?.compose(technical: technical) ?? technical
                    self.lock.lock()
                    if self.cubes.count >= 8 { self.cubes.removeAll(keepingCapacity: true) }
                    self.cubes[key] = cube; self.pendingCubes.remove(key); self.lock.unlock()
                    self.log?("lut_preview_prepared", ["profile": profile.rawValue, "look": lookID, "bytes": cube.count])
                } catch {
                    self.lock.lock(); self.failedCubes.insert(key); self.pendingCubes.remove(key); self.lock.unlock()
                    self.log?("lut_preview_load_error", ["look": look.rawValue, "error": String(describing: error)])
                }
            }
        }
        return nil
    }
    func setEnabled(_ value: Bool) {
        lock.lock(); enabled = value; latest = nil; generation += 1; lock.unlock()
        report(value ? "preparing" : "off")
    }
    func reset() {
        lock.lock(); latest = nil; generation += 1; lock.unlock()
        queue.async { self.count = 0 }
        report("preparing")
    }
    func configure(fps: Double) {
        reset()
        queue.async { self.frameStride = max(1, Int((fps / 60).rounded(.up))) }
        output.videoSettings = [:]
        if let c = output.connection(with: .video) {
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off }
        }
    }
    private func report(_ status: String) {
        let update = {
            self.lock.lock(); let view = self.surfaceView; self.lock.unlock()
            let alpha: CGFloat = ["active", "rec709"].contains(status) ? 1 : 0
            if view?.alpha != alpha { view?.alpha = alpha }
            guard self.lastStatus != status else { return }
            self.lastStatus = status
            self.statusChanged?(status)
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }
    func setSharedSource(_ value: Bool) {
        lock.lock(); usesSharedSource = value; latest = nil; generation += 1; lock.unlock()
    }
    /// One retained handoff at most. Metadata and recording never wait for preview work.
    func offerSharedSample(_ sample: CMSampleBuffer, connection: AVCaptureConnection) {
        lock.lock(); let wanted = usesSharedSource && enabled && foreground; lock.unlock()
        guard wanted, sharedSlot.wait(timeout: .now()) == .success else { return }
        queue.async { [self] in
            defer { sharedSlot.signal() }
            lock.lock(); let active = usesSharedSource; lock.unlock()
            if active { captureOutput(output, didOutput: sample, from: connection) }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        proxyDrops += 1
        if proxyDrops == 1 || proxyDrops % 30 == 0 {
            log?("lut_preview_drop", ["count": proxyDrops,
                "reason": String(describing: CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil))])
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        count += 1
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if count == 1 {
            log?("lut_preview_source", ["width": CVPixelBufferGetWidth(buffer), "height": CVPixelBufferGetHeight(buffer),
                "pixelFormat": CVPixelBufferGetPixelFormatType(buffer),
                "attachments": String(describing: CVBufferCopyAttachments(buffer, .shouldPropagate))])
        }
        lock.lock(); let wanted = enabled; let version = generation
        let selectedLook = look; let imported = importedLook; let expected = expectedColorSpace; lock.unlock()
        guard wanted, count % frameStride == 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let logTag = CVBufferCopyAttachment(buffer, kCVImageBufferLogTransferFunctionKey, nil) as? String
        let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String
        let primaries = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String
        let profile: PreviewColorTransform.Profile
        if logTag == kCVImageBufferLogTransferFunction_AppleLog as String { profile = .appleLog }
        else if #available(iOS 26, *), logTag == kCVImageBufferLogTransferFunction_AppleLog2 as String { profile = .appleLog2 }
        else if logTag == nil, transfer == kCVImageBufferTransferFunction_ITU_R_709_2 as String,
                primaries == kCVImageBufferColorPrimaries_ITU_R_709_2 as String { profile = .rec709 }
        else if logTag == nil, expected == .p3D65 { profile = .p3D65 }
        else if logTag == nil, expected == .rec2020HDR { profile = .rec2020HLG }
        else if logTag == nil, expected == .appleLog { profile = .appleLog }
        else if logTag == nil, expected == .appleLog2 { profile = .appleLog2 }
        else if logTag == nil, expected == .rec709 { profile = .rec709 }
        else { report("unsupported"); return }
        guard let cube = preparedCube(profile: profile, look: selectedLook, imported: imported) else { return }
        lock.lock()
        if generation == version && enabled { latest = (buffer, profile, cube, now) }
        lock.unlock()
        requestRender()
    }
    private func requestRender() {
        // Capture-driven scheduling avoids competing display-link and camera clocks.
        // At most one GPU submission exists; camera/recording never wait for it.
        lock.lock()
        guard enabled, displayActive, foreground, let frame = latest,
              let layer = surface, surfaceSize.width > 0, surfaceSize.height > 0,
              frame.3 != lastSubmittedTime else { lock.unlock(); return }
        let version = generation
        let size = surfaceSize
        let (buffer, profile, cube, time) = frame
        guard gpuSlot.wait(timeout: .now()) == .success else {
            gpuBusySkips += 1; lock.unlock(); return
        }
        lastSubmittedTime = time
        lastSubmittedAt = ProcessInfo.processInfo.systemUptime
        rendering = true
        lock.unlock()
        renderQueue.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                self.lock.lock(); let current = self.enabled && self.displayActive && self.foreground && self.generation == version; self.lock.unlock()
                guard current else { self.releaseSlot(); return }
                let start = ProcessInfo.processInfo.systemUptime
                guard let context = self.context, let command = self.commands?.makeCommandBuffer(),
                      let drawable = layer.nextDrawable() else { self.releaseSlot(); return }
                var image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
                if CVPixelBufferGetWidth(buffer) > CVPixelBufferGetHeight(buffer) { image = image.oriented(.right) }
                if let cube {
                    image = image.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": PreviewColorTransform.dimension, "inputCubeData": cube])
                }
                let scale = max(size.width / image.extent.width, size.height / image.extent.height)
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                image = image.transformed(by: CGAffineTransform(translationX: (size.width - image.extent.width) / 2,
                                                               y: (size.height - image.extent.height) / 2))
                context.render(image, to: drawable.texture, commandBuffer: command,
                    bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpace(name: CGColorSpace.itur_709)!)
                command.present(drawable)
                let cpuMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
                command.addCompletedHandler { [weak self, buffer] command in
                    _ = buffer // Retain ISP memory until GPU sampling completes.
                    guard let self else { return }
                    self.releaseSlot()
                    let failed = command.status == .error
                    if failed { self.log?("lut_preview_gpu_error", ["error": String(describing: command.error)]) }
                    let gpuMS = max(0, command.gpuEndTime - command.gpuStartTime) * 1000
                    self.renderQueue.async {
                        self.recordMetrics(cpuMS: cpuMS, gpuMS: gpuMS, version: version, profile: profile, size: size)
                    }
                    DispatchQueue.main.async {
                        self.lock.lock(); let current = self.enabled && self.displayActive && self.foreground && self.generation == version; self.lock.unlock()
                        guard current else { return }
                        self.report(failed ? "unavailable" : (profile == .rec709 ? "rec709" : "active"))
                    }
                }
                command.commit()
            }
        }
    }
    private func releaseSlot() {
        lock.lock(); rendering = false; lock.unlock()
        gpuSlot.signal()
    }
    private func recordMetrics(cpuMS: Double, gpuMS: Double, version: Int,
                               profile: PreviewColorTransform.Profile, size: CGSize) {
        let now = ProcessInfo.processInfo.systemUptime
        if metricGeneration != version {
            metricGeneration = version; metricStart = now; metricCount = 0
            cpuTotal = 0; cpuMax = 0; gpuTotal = 0; gpuMax = 0
        }
        rendered += 1; metricCount += 1
        cpuTotal += cpuMS; cpuMax = max(cpuMax, cpuMS)
        gpuTotal += gpuMS; gpuMax = max(gpuMax, gpuMS)
        if rendered == 1 || (metricCount >= 60 && now - metricStart >= 2) {
            lock.lock(); let skips = gpuBusySkips; let slots = usesSharedSource ? 3 : 2; lock.unlock()
            log?("lut_preview_render", ["frames": rendered, "profile": profile.rawValue,
                "width": Int(size.width), "height": Int(size.height), "bufferSlots": slots,
                "renderFPS": Double(max(0, metricCount - 1)) / max(now - metricStart, 0.001),
                "cpuMeanMS": cpuTotal / Double(metricCount), "cpuMaxMS": cpuMax,
                "gpuMeanMS": gpuTotal / Double(metricCount), "gpuMaxMS": gpuMax,
                "gpuBusySkips": skips, "renderOnMain": Thread.isMainThread])
            metricStart = now; metricCount = 0; cpuTotal = 0; cpuMax = 0; gpuTotal = 0; gpuMax = 0
        }
    }
}

/// Preserve the existing metadata delegate and offer a bounded preview-only handoff afterward.
final class IntrinsicsPreviewFanout: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let recordingLock = NSLock()
    private var recordingWriter: RealtimeLUTWriter?
    func setRecordingWriter(_ writer: RealtimeLUTWriter?) {
        recordingLock.lock(); recordingWriter = writer; recordingLock.unlock()
    }
    let recorder: CameraIntrinsicsRecorder
    let preview: LUTPreview
    init(recorder: CameraIntrinsicsRecorder, preview: LUTPreview) {
        self.recorder = recorder; self.preview = preview
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        recordingLock.lock(); let writer = recordingWriter; recordingLock.unlock()
        writer?.offer(sample)
        recorder.captureOutput(output, didOutput: sample, from: connection)
        preview.offerSharedSample(sample, connection: connection)
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        recorder.captureOutput(output, didDrop: sample, from: connection)
    }
}

/// Recording owns a full-resolution GPU pipeline. No rendered preview frames enter it.
/// Admission is bounded across queued, rendering and encoder-backpressured frames.
final class RealtimeLUTWriter: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let audioOutput = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "GyroCine.LUTRecording", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "GyroCine.LUTAudio", qos: .userInitiated)
    private let admission = NSLock()
    private var accepting = true
    private var encoderReady = false // admission lock; startup is outside the recorded interval
    private var videoCount = 0, audioCount = 0, peak = 0
    private var stopped = false, completed = false, retry = false
    private var deadline = 0.0
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let appliesLUT: Bool
    private let context: CIContext
    private let filter: CIFilter
    private let fps: Double
    private let started: (CMTime) -> Void
    private let finished: (Error?, [String: Any]) -> Void
    private var audioInput: AVAssetWriterInput?
    private var firstPTS: CMTime?, lastPTS: CMTime?
    private var videoPending: [CMSampleBuffer] = [], audioPending: [CMSampleBuffer] = []
    private var frames = 0, audioPackets = 0
    private var maxGPUms = 0.0, totalGPUms = 0.0
    #if DEBUG
    private var injectedStall = false
    #endif
    private var reported = false
    private var stopTime: Double?
    private var cadence = RAWCadenceGuard()
    private let width: Int, height: Int

    init(url: URL, recipe: LUTBurnRecipe?, settings: [String: Any], width: Int, height: Int,
         fps: Double, orientation: RecordingOrientation, dedicated: Bool, metadata: [AVMetadataItem],
         started: @escaping (CMTime) -> Void,
         finished: @escaping (Error?, [String: Any]) -> Void) throws {
        guard !["aprn", "aprh"].contains(settings[AVVideoCodecKey] as? String ?? ""), let gpu = MTLCreateSystemDefaultDevice(),
              let filter = CIFilter(name: "CIColorCube") else {
            throw RecorderError.unavailable("LUT GPU recording unavailable")
        }
        self.width = width; self.height = height; self.fps = fps
        appliesLUT = recipe != nil
        self.started = started; self.finished = finished
        context = CIContext(mtlDevice: gpu, options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
        self.filter = filter
        filter.setValue(PreviewColorTransform.dimension, forKey: "inputCubeDimension")
        filter.setValue(recipe?.cube, forKey: "inputCubeData")
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieTimeScale = 60_000
        if dedicated {
            if #available(iOS 27.0, *), writer.isProVideoStorageSupported { writer.usesProVideoStorage = true }
            else { throw RecorderError.unavailable("LUT writer: dedicated storage unavailable") }
        }
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { throw RecorderError.unavailable("LUT encoder configuration unavailable") }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        input.mediaTimeScale = 60_000
        input.transform = orientation.movieTransform(width: width, height: height)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: recipe?.highBitDepth == true || (settings[AVVideoCodecKey] as? String ?? "").hasPrefix("ap") ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true])
        guard writer.canAdd(input) else { throw RecorderError.unavailable("LUT video input unavailable") }
        writer.add(input)
        let tag = AVMutableMetadataItem(); tag.keySpace = .quickTimeMetadata
        tag.key = LUTMovieBurner.marker as NSString; tag.value = recipe?.id as NSString?
        writer.metadata = metadata + (recipe == nil ? [] : [tag])
        super.init()
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.firstPTS == nil, !self.completed else { return }
            self.fail("LUT 录制启动超时：未收到可用的视频或音频")
        }
    }
    func offer(_ sample: CMSampleBuffer, audio: Bool = false) {
        admission.lock()
        guard accepting else { admission.unlock(); return }
        // Audio initializes the writer. A video admitted before readiness can sit
        // behind startWriting while later warmup frames are rejected, leaving
        // a gap after the first recorded frame. Admit only post-ready samples.
        if !audio && !encoderReady { admission.unlock(); return }
        guard audio ? audioCount < 32 : videoCount < 10 else {
            accepting = false; admission.unlock()
            queue.async { self.fail("LUT 实时处理或存储写入跟不上，缓冲已满，已停止录制并保留文件") }
            return
        }
        if audio { audioCount += 1 } else { videoCount += 1; peak = max(peak, videoCount) }
        queue.async {
            guard !self.completed else { self.release(audio); return }
            if audio { self.audioPending.append(sample) } else { self.videoPending.append(sample) }
            self.drain()
        }
        admission.unlock()
    }
    private func release(_ audio: Bool) {
        admission.lock(); if audio { audioCount -= 1 } else { videoCount -= 1 }; admission.unlock()
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { offer(sampleBuffer, audio: true) }
    func stop() {
        admission.lock(); accepting = false
        queue.async {
            guard !self.completed, !self.stopped else { return }
            self.stopped = true; self.stopTime = ProcessInfo.processInfo.systemUptime
            self.deadline = ProcessInfo.processInfo.systemUptime + 5
            self.drain()
        }
        admission.unlock()
    }
    func abort(_ message: String) { queue.async { self.fail(message) } }
    private func drain() {
        guard !completed else { return }
        do {
            if audioInput == nil, let audio = audioPending.first,
               let format = CMSampleBufferGetFormatDescription(audio),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: asbd.mSampleRate, AVNumberOfChannelsKey: asbd.mChannelsPerFrame,
                    AVEncoderBitRateKey: asbd.mChannelsPerFrame == 1 ? 128_000 : 320_000], sourceFormatHint: format)
                i.expectsMediaDataInRealTime = true
                guard writer.canAdd(i) else { throw RecorderError.unavailable("LUT audio input unavailable") }
                writer.add(i); audioInput = i
                guard writer.startWriting() else { throw writer.error ?? RecorderError.unavailable("LUT encoder failed to start") }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--writer-startup-delay-probe") {
                    Thread.sleep(forTimeInterval: 0.1) // Exercise admission during startup, before the recorded interval.
                }
                #endif
                // The next post-ready capture establishes time zero. No real
                // recorded timestamps are compressed or filled with synthetic frames.
                let warmup = videoPending.count; videoPending.removeAll()
                admission.lock(); videoCount -= warmup; encoderReady = true; admission.unlock()
            }
            if firstPTS == nil, audioInput != nil, let video = videoPending.first {
                let pts = video.presentationTimeStamp
                firstPTS = pts; writer.startSession(atSourceTime: pts); started(pts)
            }
            if let firstPTS {
                while input.isReadyForMoreMediaData, !videoPending.isEmpty {
                    let sample = videoPending.removeFirst(); defer { release(false) }
                    try autoreleasepool {
                        guard let pixels = CMSampleBufferGetImageBuffer(sample),
                              CVPixelBufferGetWidth(pixels) == width, CVPixelBufferGetHeight(pixels) == height else { throw RecorderError.unavailable("LUT recording frame dimensions changed") }
                        let pts = sample.presentationTimeStamp
                        guard lastPTS == nil || pts > lastPTS! else { throw RecorderError.unavailable("LUT 视频时间戳异常") }
                        if cadence.observe(pts.seconds, fps: fps) != nil { throw RecorderError.unavailable("LUT 录制持续丢帧，已停止；请降低录制规格") }
                        // Native ProRes keeps the capture buffer, attachments and original PTS.
                        // Only LUT baking renders through Core Image.
                        if !appliesLUT {
                            guard input.append(sample) else { throw writer.error ?? RecorderError.unavailable("ProRes video append failed") }
                            frames += 1; lastPTS = pts
                            return
                        }
                        guard let pool = adaptor.pixelBufferPool else { throw RecorderError.unavailable("LUT pixel pool unavailable") }
                        var buffer: CVPixelBuffer?
                        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
                            [kCVPixelBufferPoolAllocationThresholdKey as String: 10] as CFDictionary, &buffer) == kCVReturnSuccess,
                            let buffer else { throw RecorderError.unavailable("LUT 编码缓冲已满，请降低录制规格") }
                        #if DEBUG
                        if !injectedStall, frames > 120, ProcessInfo.processInfo.arguments.contains("--lut-stall-smoke") {
                            injectedStall = true; Thread.sleep(forTimeInterval: 0.3)
                        }
                        #endif
                        let begin = ProcessInfo.processInfo.systemUptime
                        filter.setValue(CIImage(cvPixelBuffer: pixels, options: [.colorSpace: NSNull()]), forKey: kCIInputImageKey)
                        guard let image = filter.outputImage else { throw RecorderError.unavailable("LUT GPU filter failed") }
                        context.render(image, to: buffer, bounds: image.extent, colorSpace: nil)
                        filter.setValue(nil, forKey: kCIInputImageKey)
                        let ms = (ProcessInfo.processInfo.systemUptime - begin) * 1000
                        maxGPUms = max(maxGPUms, ms); totalGPUms += ms
                        guard adaptor.append(buffer, withPresentationTime: pts) else { throw writer.error ?? RecorderError.unavailable("LUT video append failed") }
                        frames += 1; lastPTS = pts
                    }
                }
                if let audioInput {
                    while audioInput.isReadyForMoreMediaData, !audioPending.isEmpty {
                        let sample = audioPending.removeFirst(); defer { release(true) }
                        if sample.presentationTimeStamp < firstPTS { continue }
                        guard audioInput.append(sample) else { throw writer.error ?? RecorderError.unavailable("LUT audio append failed") }
                        audioPackets += 1
                    }
                }
            }
            if stopped && videoPending.isEmpty && audioPending.isEmpty {
                guard firstPTS != nil, let lastPTS else { fail("LUT 录制尚未开始"); return }
                writer.endSession(atSourceTime: CMTimeAdd(lastPTS, CMTime(seconds: 1 / fps, preferredTimescale: 60_000)))
                complete(nil)
            } else if !retry && (stopped || (!videoPending.isEmpty || !audioPending.isEmpty) && firstPTS != nil) {
                if stopped && ProcessInfo.processInfo.systemUptime > deadline { fail("LUT 录制缓冲排空超时"); return }
                retry = true
                queue.asyncAfter(deadline: .now() + 0.003) { [weak self] in
                    guard let self else { return }; self.retry = false; self.drain()
                }
            }
            if writer.status == .failed { throw writer.error ?? RecorderError.unavailable("LUT writer failed") }
        } catch { fail(error.localizedDescription) }
    }
    private func fail(_ message: String) { complete(RecorderError.unavailable(message)) }
    private func complete(_ error: Error?) {
        guard !completed else { return }; completed = true
        admission.lock(); accepting = false; let peak = peak; admission.unlock()
        videoPending.removeAll(); audioPending.removeAll()
        let report = { [self] in
            guard !reported else { return }; reported = true
            finished(error ?? writer.error, ["frames": frames, "audioPackets": audioPackets,
                "peakBuffered": peak, "maxGPUms": maxGPUms, "meanGPUms": totalGPUms / Double(max(1, frames)),
                "stopToWriterSeconds": stopTime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0,
                "error": (error ?? writer.error)?.localizedDescription ?? ""])
        }
        if writer.status == .writing {
            input.markAsFinished(); audioInput?.markAsFinished()
            writer.finishWriting { self.queue.async(execute: report) }
            queue.asyncAfter(deadline: .now() + 10) { [self] in
                guard !reported else { return }; reported = true
                writer.cancelWriting()
                finished(RecorderError.unavailable("LUT 视频保存超时，文件已保留"),
                    ["frames": frames, "error": "finishWriting timeout"])
            }
        } else { report() }
    }
}
