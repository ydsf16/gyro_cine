import SwiftUI
import AVFoundation

@main struct ProbeApp: App {
    @StateObject var probe = Probe()
    var body: some Scene {
        WindowGroup {
            VStack {
                Text("RAW Storage Probe").font(.title)
                Button("专用存储设置") { AVProVideoStorage.shared?.openSettings() }
                Button("运行 MovieFileOutput 对照") { probe.run(mode: "movie") }.disabled(probe.running)
                Button("录制 RAW 内录测试（5秒）") { probe.run(mode: "writer") }.disabled(probe.running)
                Text("独立实验：仅视频，不含音频和 IMU").font(.caption)
                ScrollView { Text(probe.status).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding().task {
                UIApplication.shared.isIdleTimerDisabled = true
                if ProcessInfo.processInfo.arguments.contains("--auto") { probe.run() }
            }
        }
    }
}

final class Probe: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    @Published var status = "Ready"
    @Published var running = false
    private let queue = DispatchQueue(label: "probe.camera")
    private var session: AVCaptureSession?
    private var movie: AVCaptureMovieFileOutput?
    private var writerProbe: WriterProbe?
    private var completion: (() -> Void)?
    private let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private let runID = UUID().uuidString
    func log(_ event: String, _ fields: [String: Any] = [:]) {
        let row: [String: Any] = ["event": event, "fields": fields, "time": Date().timeIntervalSince1970]
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
        let path = folder.appendingPathComponent("probe-\(runID).jsonl")
        if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: path) { try? handle.seekToEnd(); try? handle.write(contentsOf: data + Data([10])); try? handle.close() }
        DispatchQueue.main.async { self.status += "\n" + text }
    }
    func run(mode: String? = nil) {
        guard !running else { return }; running = true
        AVCaptureDevice.requestAccess(for: .video) { allowed in
            self.queue.async {
                guard allowed else { self.log("permission_denied"); DispatchQueue.main.async { self.running = false }; return }
                self.log("environment", ["os": ProcessInfo.processInfo.operatingSystemVersionString,
                    "sdk": Bundle.main.object(forInfoDictionaryKey: "DTSDKName") ?? "",
                    "storageSupported": AVProVideoStorage.isSupported,
                    "remaining": AVProVideoStorage.shared?.remainingCapacity ?? -1])
                if mode == "writer" || (mode == nil && ProcessInfo.processInfo.arguments.contains("--writer")) {
                    let probe = WriterProbe(log: self.log) { DispatchQueue.main.async { self.running = false } }
                    self.writerProbe = probe; probe.run()
                } else if mode == nil && ProcessInfo.processInfo.arguments.contains("--movie-wb") { self.testMovieWB() } else { self.testMovie() }
            }
        }
    }
    private func testMovieWB() {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        let session = AVCaptureSession(); let output = AVCaptureMovieFileOutput()
        self.session = session; self.movie = output
        if output.isDeferredStartSupported { output.isDeferredStartEnabled = false }
        do {
            session.beginConfiguration(); session.sessionPreset = .inputPriority
            session.addInput(try AVCaptureDeviceInput(device: camera)); session.addOutput(output)
            for format in camera.formats {
                let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard size.width == 4224 && size.height == 2240,
                      format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) else { continue }
                try camera.lockForConfiguration(); camera.activeFormat = format
                camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                camera.unlockForConfiguration()
                if output.availableVideoCodecTypes.contains(AVVideoCodecType(rawValue: "aprn")) { break }
            }
            output.setOutputSettings([AVVideoCodecKey: "aprn"], for: output.connection(with: .video)!)
            session.commitConfiguration(); session.startRunning()
            log("movie_before_effective_wb", ["support": output.isProVideoStorageSupported])
            try camera.lockForConfiguration()
            camera.setWhiteBalanceModeLocked(with: camera.deviceWhiteBalanceGains) { time in
                self.queue.async {
                    self.log("movie_after_effective_wb", ["support": output.isProVideoStorageSupported,
                        "mode": camera.whiteBalanceMode.rawValue, "effectiveTime": time.seconds])
                    if output.isProVideoStorageSupported {
                        output.usesProVideoStorage = true
                        output.startRecording(to: self.folder.appendingPathComponent("UITEST_movie_\(UUID().uuidString).mov"), recordingDelegate: self)
                    } else { session.stopRunning(); DispatchQueue.main.async { self.running = false } }
                }
            }
            camera.unlockForConfiguration()
        } catch { log("movie_wb_error", ["error": String(describing: error)]) }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo url: URL, from connections: [AVCaptureConnection]) {
        log("movie_started", ["file": url.lastPathComponent])
        queue.asyncAfter(deadline: .now() + 5) { self.movie?.stopRecording() }
    }
    private func testMovie() {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        // Fresh session/input/output. No preview, IMU, data output, audio, observers, or exposure control.
        let session = AVCaptureSession(); let output = AVCaptureMovieFileOutput()
        self.session = session; self.movie = output
        if output.isDeferredStartSupported { output.isDeferredStartEnabled = false }
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            session.beginConfiguration(); session.sessionPreset = .inputPriority
            session.addInput(input); session.addOutput(output)
            try camera.lockForConfiguration()
            if camera.isWhiteBalanceModeSupported(.locked) { camera.whiteBalanceMode = .locked }
            camera.unlockForConfiguration()
            session.commitConfiguration()
            for (index, format) in camera.formats.enumerated() where format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                session.beginConfiguration()
                try camera.lockForConfiguration(); camera.activeFormat = format
                camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                camera.unlockForConfiguration(); session.commitConfiguration()
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let codecs = output.availableVideoCodecTypes
                guard codecs.contains(AVVideoCodecType(rawValue: "aprn")) else { continue }
                guard let connection = output.connection(with: .video) else { continue }
                for codec in ["aprn", "aprh"] where codecs.contains(AVVideoCodecType(rawValue: codec)) {
                    output.setOutputSettings([AVVideoCodecKey: codec], for: connection)
                    session.startRunning()
                    log("fresh_movie_support", ["format": index, "width": dims.width, "height": dims.height,
                        "codec": codec, "support": output.isProVideoStorageSupported, "running": session.isRunning])
                    session.stopRunning()
                }
            }
            log("movie_probe_complete")
        } catch { log("movie_error", ["error": String(describing: error)]) }
        session.stopRunning(); self.session = nil; self.movie = nil
        DispatchQueue.main.async { self.running = false }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        log("movie_finished", ["file": url.lastPathComponent, "error": error.map(String.init(describing:)) ?? ""])
    }
}
