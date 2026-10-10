import SwiftUI
import AVFoundation

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.layerForPreview.session = session
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var layerForPreview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        layerForPreview.videoGravity = .resizeAspectFill
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct ContentView: View {
    @ObservedObject var model: RecorderViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                CameraPreview(session: model.previewSession)
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text("\(model.state.rawValue.capitalized) · HEVC · 4K30 · \(model.thermalLabel)")
                    .font(.caption)
                    .accessibilityIdentifier("recordingState")
                Text("Free: \(model.freeSpaceLabel) · IMU: \(model.imuRateLabel)")
                    .font(.caption)
                if model.state == .recording {
                    Text(String(format: "%02d:%02d", model.elapsedSeconds / 60, model.elapsedSeconds % 60))
                        .monospacedDigit()
                }
                if let message = model.message { Text(message).foregroundStyle(.red).font(.caption) }
                Button(model.state == .recording ? "Stop" : "Record") {
                    model.state == .recording ? model.stop() : model.start()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!model.canToggle)
                .accessibilityIdentifier("recordToggle")
                if model.state == .failed {
                    Button("Retry camera") { model.retry() }
                }
                List(model.recordings, id: \.path) { folder in
                    HStack {
                        Text(folder.lastPathComponent)
                        Spacer()
                        ShareLink(item: folder) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
            .padding()
            .navigationTitle("RawMotion Recorder")
            .toolbar { Button("Settings") { showingSettings = true } }
            .sheet(isPresented: $showingSettings) { SettingsView(model: model) }
            .task { model.prepare() }
            .onChange(of: model.audioEnabled) { _, enabled in
                if model.state != .recording { model.coordinator.configure(audio: enabled) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active && model.state == .recording { model.stop() }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: RecorderViewModel
    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Video format", value: "HEVC")
                LabeledContent("Camera", value: "Back wide 1×")
                LabeledContent("Resolution / rate", value: "4K / 30 fps")
                Toggle("Audio", isOn: $model.audioEnabled).disabled(model.state == .recording)
                LabeledContent("Raw gyro + accel", value: "Always on")
                LabeledContent("Gyroflow sidecar", value: "Always on")
                LabeledContent("ProRes RAW / HQ", value: "M2 locked")
                Section("Device capability") {
                    Text(model.capabilityLabel)
                    Text("Available 4K30 formats: \(model.modes.count)")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
