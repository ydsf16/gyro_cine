import AVFoundation
import SwiftUI

private struct Preview: UIViewRepresentable {
    let session: AVCaptureSession
    let onTap: (CGPoint) -> Void
    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onTap = onTap
        return view
    }
    func updateUIView(_ view: PreviewUIView, context: Context) { view.onTap = onTap }
}

private final class PreviewUIView: UIView {
    var onTap: ((CGPoint) -> Void)?
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    @objc private func tapped(_ sender: UITapGestureRecognizer) {
        let point = previewLayer.captureDevicePointConverted(fromLayerPoint: sender.location(in: self))
        onTap?(point)
    }
}

struct CameraView: View {
    @EnvironmentObject private var camera: CameraManager
    @State private var showingSettings = false
    @State private var manualPosition: Double = 0.5
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Preview(session: camera.session, onTap: camera.tapFocus)
                HStack {
                    Text(camera.status).font(.caption2).padding(6).background(.black.opacity(0.55))
                    Spacer()
                    Button("Settings") { showingSettings = true }.buttonStyle(.borderedProminent)
                }.padding(8)
            }.frame(maxHeight: .infinity)
            VStack(spacing: 7) {
                diagnostics
                HStack {
                    Button("MARK") { camera.mark() }.buttonStyle(.bordered)
                    Spacer()
                    Button(camera.recording ? "Stop" : "Record") { camera.toggleRecording() }
                        .buttonStyle(.borderedProminent).tint(camera.recording ? .red : .green)
                    Spacer()
                    Picker("Focus", selection: Binding(get: { camera.focusChoice }, set: { camera.chooseFocus($0) })) {
                        ForEach(FocusChoice.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu)
                }
                if camera.focusChoice == .manual {
                    HStack {
                        Text("Manual \(manualPosition, specifier: "%.2f")")
                        Slider(value: $manualPosition, in: 0...1)
                            .onChange(of: manualPosition) { _, value in camera.setManualPosition(Float(value)) }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            .background(.black)
        }
        .background(.black).foregroundStyle(.white)
        .sheet(isPresented: $showingSettings) { SettingsView().environmentObject(camera) }
        .alert("Camera error", isPresented: Binding(get: { camera.errorText != nil }, set: { if !$0 { camera.clearError() } })) {
            Button("OK") { camera.clearError() }
        } message: { Text(camera.errorText ?? "") }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(camera.selectedCodec?.rawValue ?? "—")  Format [\(camera.selectedFormatIndex.map(String.init) ?? "—")]  \(camera.fps, specifier: "%.3f") fps")
            Text("Focus: \(camera.focusChoice.rawValue) (actual: \(camera.actualFocusMode))")
            Text("Adjusting: \(camera.adjusting ? "yes" : "no")   Lens: \(camera.lensPosition, specifier: "%.3f")")
            Text("Recording: \(camera.recording ? "yes" : "no")")
            if camera.focusChoice == .tap { Text("Tap preview to choose focus point") }
        }.font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
    }
}
