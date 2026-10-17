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
    let metalDevice = MTLCreateSystemDefaultDevice()
    private lazy var commands = metalDevice?.makeCommandQueue()
    private lazy var context: CIContext? = metalDevice.map {
        CIContext(mtlDevice: $0, options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    }
    private var cubes: [PreviewColorTransform.Profile: Data] = [:] // capture queue
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
        lock.lock(); let wanted = enabled; let version = generation; lock.unlock()
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
        else { report("unsupported"); return }
        if profile != .rec709, cubes[profile] == nil { cubes[profile] = PreviewColorTransform.cube(profile) }
        lock.lock()
        if generation == version && enabled { latest = (buffer, profile, cubes[profile], now) }
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
            lock.lock(); let skips = gpuBusySkips; lock.unlock()
            log?("lut_preview_render", ["frames": rendered, "profile": profile.rawValue,
                "width": Int(size.width), "height": Int(size.height), "bufferSlots": 2,
                "renderFPS": Double(max(0, metricCount - 1)) / max(now - metricStart, 0.001),
                "cpuMeanMS": cpuTotal / Double(metricCount), "cpuMaxMS": cpuMax,
                "gpuMeanMS": gpuTotal / Double(metricCount), "gpuMaxMS": gpuMax,
                "gpuBusySkips": skips, "renderOnMain": Thread.isMainThread])
            metricStart = now; metricCount = 0; cpuTotal = 0; cpuMax = 0; gpuTotal = 0; gpuMax = 0
        }
    }
}
