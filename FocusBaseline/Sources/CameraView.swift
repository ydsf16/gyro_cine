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
    private let focusFrame = UIView()
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        focusFrame.frame.size = CGSize(width: 68, height: 68)
        focusFrame.layer.borderColor = UIColor.white.cgColor
        focusFrame.layer.borderWidth = 1.5
        focusFrame.alpha = 0
        focusFrame.isUserInteractionEnabled = false
        addSubview(focusFrame)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    @objc private func tapped(_ sender: UITapGestureRecognizer) {
        let location = sender.location(in: self)
        onTap?(previewLayer.captureDevicePointConverted(fromLayerPoint: location))
        focusFrame.center = location
        focusFrame.alpha = 1
        UIView.animate(withDuration: 0.3, delay: 1.2, options: [.beginFromCurrentState]) { self.focusFrame.alpha = 0 }
    }
}

private enum Parameter: String, CaseIterable, Identifiable {
    case lens = "Lens", shutter = "Shutter", iso = "ISO", wb = "WB", focus = "Focus"
    var id: Self { self }
}

struct CameraView: View {
    @EnvironmentObject private var camera: CameraManager
    @State private var selected: Parameter?
    @State private var showingSettings = false
    @State private var showingMedia = false
    @State private var shutterValue = 1.0 / 120.0
    @State private var isoValue = 400.0
    @State private var wbValue = 5600.0
    @State private var focusValue = 0.5
    @State private var lastControlSend = Date.distantPast
    private let accent = Color(red: 0.08, green: 0.62, blue: 1)

    var body: some View {
        ZStack {
            Preview(session: camera.session, onTap: camera.tapFocus)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                topHUD
                Spacer(minLength: 0)
                if let selected { parameterPanel(selected).padding(.horizontal, 14).padding(.bottom, 14) }
                bottomBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSettings) { SettingsView().environmentObject(camera) }
        .sheet(isPresented: $showingMedia) { MediaLibraryView() }
        .alert("GyroCine", isPresented: Binding(get: { camera.errorText != nil }, set: { if !$0 { camera.clearError() } })) {
            Button("确定") { camera.clearError() }
        } message: { Text(camera.errorText ?? "") }
        .onAppear {
            shutterValue = camera.exposureSeconds
            isoValue = Double(camera.iso)
            wbValue = Double(camera.whiteBalanceKelvin)
            focusValue = Double(camera.lensPosition)
        }
        .onChange(of: camera.exposureSeconds) { _, value in if camera.exposureAuto { shutterValue = value } }
        .onChange(of: camera.iso) { _, value in if camera.exposureAuto { isoValue = Double(value) } }
        .onChange(of: camera.whiteBalanceKelvin) { _, value in if camera.whiteBalanceAuto { wbValue = Double(value) } }
        .onChange(of: camera.lensPosition) { _, value in if camera.focusChoice != .manual { focusValue = Double(value) } }
    }

    private var topHUD: some View {
        VStack(spacing: 13) {
            HStack(spacing: 8) {
                Text("GyroCine").font(.system(size: 15, weight: .bold)).fixedSize()
                Spacer(minLength: 3)
                TimelineView(.periodic(from: .now, by: 0.2)) { timeline in
                    let seconds = max(0, Int(timeline.date.timeIntervalSince(camera.recordingStartedAt ?? timeline.date)))
                    HStack(spacing: 5) {
                        Circle().fill(camera.recording ? .red : .white).frame(width: 8, height: 8)
                        Text(String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60))
                            .monospacedDigit()
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(camera.recording ? .red : .white)
                }
                Spacer(minLength: 3)
                statusBadge("SSD", healthy: false)
                statusBadge("IMU", healthy: false)
            }
            Text(specification)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1).minimumScaleFactor(0.75)
            HStack(spacing: 0) {
                ForEach(Parameter.allCases) { parameter in
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) { selected = selected == parameter ? nil : parameter }
                    } label: {
                        VStack(spacing: 3) {
                            Text(parameter.rawValue.uppercased()).font(.system(size: 10, weight: .medium))
                            HStack(spacing: 2) {
                                Text(value(for: parameter)).font(.system(size: 17, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                                if isAuto(parameter) { Text("A").font(.system(size: 9, weight: .bold)).foregroundStyle(accent) }
                            }
                            Rectangle().fill(selected == parameter ? accent : .clear).frame(height: 2)
                        }
                        .foregroundStyle(selected == parameter ? accent : .white)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 7)
        .background(LinearGradient(colors: [.black.opacity(0.9), .black.opacity(0.72), .black.opacity(0.02)], startPoint: .top, endPoint: .bottom))
    }

    private func statusBadge(_ text: String, healthy: Bool) -> some View {
        Text(text + (healthy ? " ✓" : " !"))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(healthy ? .green : .red)
            .padding(.horizontal, 5).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(healthy ? .green : .red, lineWidth: 0.8))
    }

    private var specification: String {
        let codec = switch camera.selectedCodec?.rawValue {
        case "hvc1": "HEVC"
        case "aprn": "ProRes RAW"
        case "aprh": "ProRes RAW HQ"
        default: camera.selectedCodec?.rawValue ?? "—"
        }
        let format = camera.selectedFormatIndex.flatMap { index in camera.formats.first(where: { $0.index == index }) }
        let resolution = format.map { "\($0.width)×\($0.height)" } ?? "—"
        return "\(codec) · \(resolution) · \(Int(camera.fps.rounded()))fps"
    }

    private func value(for parameter: Parameter) -> String {
        switch parameter {
        case .lens: camera.lenses.first(where: { $0.id == camera.selectedLensID })?.label ?? "—"
        case .shutter: camera.exposureSeconds > 0 ? "1/\(Int((1 / camera.exposureSeconds).rounded()))" : "—"
        case .iso: String(Int(camera.iso.rounded()))
        case .wb: "\(Int(camera.whiteBalanceKelvin.rounded()))K"
        case .focus: camera.focusChoice == .manual ? String(format: "%.2f", camera.lensPosition) : "AF"
        }
    }
    private func isAuto(_ parameter: Parameter) -> Bool {
        switch parameter {
        case .lens: false
        case .shutter, .iso: camera.exposureAuto
        case .wb: camera.whiteBalanceAuto
        case .focus: camera.focusChoice != .manual
        }
    }

    private func parameterPanel(_ parameter: Parameter) -> some View {
        VStack(spacing: 12) {
            Capsule().fill(.white.opacity(0.35)).frame(width: 44, height: 4)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(parameter.rawValue).font(.system(size: 17, weight: .semibold))
                    Text(value(for: parameter)).font(.system(size: 14)).foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                if parameter != .lens { modePicker(parameter) }
            }
            Group {
                switch parameter {
                case .lens:
                    HStack(spacing: 16) {
                        ForEach(camera.lenses) { lens in
                            Button { camera.chooseLens(lens.id) } label: {
                                Text(lens.label).font(.system(size: 17, weight: .semibold))
                                    .frame(maxWidth: .infinity).frame(height: 48)
                                    .background(camera.selectedLensID == lens.id ? accent : .white.opacity(0.08), in: Circle())
                            }
                            .disabled(camera.recording || camera.finalizing || camera.switchingLens)
                        }
                    }
                case .shutter:
                    movingRuler(value: $shutterValue, range: camera.exposureRange, mapping: .logarithmic, format: shutterLabel) { camera.setManualExposure(seconds: $0) }
                        .disabled(camera.exposureAuto)
                case .iso:
                    movingRuler(value: $isoValue, range: camera.isoRange, mapping: .logarithmic, format: { String(Int($0.rounded())) }) { camera.setManualExposure(iso: $0) }
                        .disabled(camera.exposureAuto)
                case .wb:
                    movingRuler(value: $wbValue, range: 2000...10000, format: { "\(Int($0.rounded()))" }) { camera.setWhiteBalance(kelvin: Float($0)) }
                        .disabled(camera.whiteBalanceAuto)
                case .focus:
                    movingRuler(value: $focusValue, range: 0...1, format: { String(format: "%.2f", $0) }) { camera.setManualPosition(Float($0)) }
                        .disabled(camera.focusChoice != .manual)
                }
            }
            .frame(height: 73)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .frame(height: 167)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.1)))
    }

    private func modePicker(_ parameter: Parameter) -> some View {
        HStack(spacing: 0) {
            ForEach([true, false], id: \.self) { auto in
                Button(parameter == .focus ? (auto ? "AF" : "MF") : (auto ? "A" : "M")) {
                    switch parameter {
                    case .shutter, .iso:
                        if !auto && camera.exposureAuto { shutterValue = camera.exposureSeconds; isoValue = Double(camera.iso) }
                        camera.setExposureAuto(auto)
                    case .wb:
                        if !auto { wbValue = Double(camera.whiteBalanceKelvin) }
                        camera.setWhiteBalanceAuto(auto)
                    case .focus: camera.chooseFocus(auto ? .continuous : .manual, manualPosition: Float(focusValue))
                    case .lens: break
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .frame(width: 42, height: 31)
                .background(isAuto(parameter) == auto ? accent : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
    }

    private func movingRuler(value: Binding<Double>, range: ClosedRange<Double>, mapping: RulerMapping = .linear, format: @escaping (Double) -> String,
                             onChange: @escaping (Double) -> Void) -> some View {
        MovingRuler(value: value, range: range, mapping: mapping, format: format) { selectedValue, finished in
            if finished || Date().timeIntervalSince(lastControlSend) > 0.06 {
                lastControlSend = Date()
                onChange(selectedValue)
            }
        }
    }
    private func shutterLabel(_ seconds: Double) -> String {
        seconds > 0 ? "1/\(Int((1 / seconds).rounded()))" : "—"
    }

    private var bottomBar: some View {
        HStack(alignment: .center) {
            Button { showingMedia = true } label: {
                VStack(spacing: 5) { Image(systemName: "photo.on.rectangle").font(.system(size: 25)); Text("Media").font(.caption) }
                    .frame(maxWidth: .infinity)
            }
            Button { camera.toggleRecording() } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                    RoundedRectangle(cornerRadius: camera.recording ? 5 : 32)
                        .fill(.red).frame(width: camera.recording ? 33 : 54, height: camera.recording ? 33 : 54)
                }
            }
            .disabled(!camera.cameraReady || camera.finalizing || camera.switchingLens)
            .accessibilityLabel(camera.finalizing ? "Finalizing" : camera.recording ? "Stop recording" : "Record")
            .frame(maxWidth: .infinity)
            Button { showingSettings = true } label: {
                VStack(spacing: 5) { Image(systemName: "gearshape").font(.system(size: 25)); Text("Settings").font(.caption) }
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .frame(height: 92)
        .padding(.horizontal, 14)
        .background(LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.65), .black.opacity(0.9)], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .top) {
            if camera.finalizing {
                HStack(spacing: 7) { ProgressView().tint(.white); Text("正在保存…") }
                    .font(.caption).foregroundStyle(.white)
            }
        }
    }
}
