import AVFoundation
import SwiftUI

private struct Preview: UIViewRepresentable {
    let session: AVCaptureSession
    let onTap: (CGPoint) -> Void
    let onLongPress: (CGPoint) -> Void
    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onTap = onTap
        view.onLongPress = onLongPress
        return view
    }
    func updateUIView(_ view: PreviewUIView, context: Context) {
        view.onTap = onTap; view.onLongPress = onLongPress
    }
}

private final class PreviewUIView: UIView {
    var onTap: ((CGPoint) -> Void)?
    var onLongPress: ((CGPoint) -> Void)?
    private let focusFrame = UIView()
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.55
        tap.require(toFail: hold)
        addGestureRecognizer(tap); addGestureRecognizer(hold)
        focusFrame.frame.size = CGSize(width: 72, height: 72)
        focusFrame.layer.borderColor = UIColor.white.cgColor
        focusFrame.layer.borderWidth = 3
        focusFrame.alpha = 0
        focusFrame.isUserInteractionEnabled = false
        addSubview(focusFrame)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    @objc private func tapped(_ sender: UITapGestureRecognizer) {
        let location = sender.location(in: self)
        onTap?(previewLayer.captureDevicePointConverted(fromLayerPoint: location))
        showFocusFrame(at: location, locked: false)
    }
    @objc private func held(_ sender: UILongPressGestureRecognizer) {
        guard sender.state == .began else { return }
        let location = sender.location(in: self)
        onLongPress?(previewLayer.captureDevicePointConverted(fromLayerPoint: location))
        showFocusFrame(at: location, locked: true)
    }
    private func showFocusFrame(at location: CGPoint, locked: Bool) {
        focusFrame.center = location
        focusFrame.layer.borderColor = locked ? UIColor.systemOrange.cgColor : UIColor.white.cgColor
        focusFrame.alpha = 1
        UIView.animate(withDuration: 0.3, delay: locked ? 2.5 : 1.2, options: [.beginFromCurrentState]) { self.focusFrame.alpha = 0 }
    }
}

private enum Parameter: String, CaseIterable, Identifiable {
    case lens = "Lens", shutter = "Shutter", iso = "ISO", wb = "WB", focus = "Focus"
    var id: Self { self }
    func title(locale: Locale) -> String {
        switch self {
        case .lens: AppText.value("镜头", "Lens", locale: locale)
        case .shutter: AppText.value("快门", "Shutter", locale: locale)
        case .iso: "ISO"
        case .wb: AppText.value("白平衡", "WB", locale: locale)
        case .focus: AppText.value("对焦", "Focus", locale: locale)
        }
    }
}

private struct CompositionGrid: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                for fraction in [1.0 / 3, 2.0 / 3] {
                    path.move(to: CGPoint(x: width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: width * fraction, y: height))
                    path.move(to: CGPoint(x: 0, y: height * fraction))
                    path.addLine(to: CGPoint(x: width, y: height * fraction))
                }
            }
            .stroke(.white.opacity(0.48), style: StrokeStyle(lineWidth: 0.8))
            .shadow(color: .black.opacity(0.8), radius: 1)
        }
    }
}

private struct HorizonLevel: View {
    let pose: HorizonGuidePose

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Capsule().fill(.white.opacity(0.4))
                    .frame(width: 180, height: 1)
                    .rotationEffect(.radians(pose.reference))
                Capsule().fill(pose.aligned ? .green : .white)
                    .frame(width: 140, height: 2)
                    .rotationEffect(.radians(pose.angle))
                Circle().fill(pose.aligned ? .green : .white)
                    .frame(width: 6, height: 6)
            }
            .shadow(color: .black.opacity(0.85), radius: 2)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

struct CameraView: View {
    @EnvironmentObject private var camera: CameraManager
    @Environment(\.locale) private var locale
    @AppStorage("showCompositionGrid") private var showCompositionGrid = false
    @AppStorage("showHorizonLevel") private var showHorizonLevel = false
    @AppStorage("storageLocation") private var storageLocation = "内部文件"
    @AppStorage("exposureType") private var exposureType = "speed"
    @State private var selected: Parameter?
    @State private var panelDismissID = UUID()
    @State private var showingSettings = false
    @State private var showingMedia = false
    @State private var shutterValue = 1.0 / 120.0
    @State private var shutterMaxValue = 1.0 / 200.0
    @State private var shutterAngleValue = 180.0
    @State private var shutterAngleMaxValue = 180.0
    @State private var isoValue = 400.0
    @State private var wbValue = 5600.0
    @State private var focusValue = 0.5
    @State private var lastControlSend = Date.distantPast
    private let accent = Color(red: 0.08, green: 0.62, blue: 1)
    private let shutterStops: [Double] = [4000, 2000, 1000, 500, 250, 200, 120, 60, 30, 15, 10]
        .map { 1.0 / $0 }

    private var shutterRulerRange: ClosedRange<Double> {
        let lower = max(camera.exposureRange.lowerBound, 1.0 / 4000)
        let upper = min(camera.exposureRange.upperBound, 1.0 / 10, 1.0 / max(camera.fps, 1))
        return lower <= upper ? lower...upper : camera.exposureRange
    }

    private var shutterAngleRange: ClosedRange<Double> {
        let minimum = max(1, 360 * camera.exposureRange.lowerBound * camera.fps)
        let maximum = min(360, 360 * camera.exposureRange.upperBound * camera.fps)
        return minimum <= maximum ? minimum...maximum : 1...360
    }

    var body: some View {
        ZStack {
            Preview(session: camera.session, onTap: camera.tapFocus, onLongPress: camera.lockFocus)
                .ignoresSafeArea()
            if showCompositionGrid {
                CompositionGrid().ignoresSafeArea().allowsHitTesting(false)
            }
            if showHorizonLevel {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    if let gravity = camera.previewGravity(),
                       let pose = HorizonGuidePose(gravity: gravity) {
                        HorizonLevel(pose: pose).ignoresSafeArea().allowsHitTesting(false)
                    }
                }
            }
            if selected != nil {
                Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                    .onTapGesture { closePanel() }
            }
            VStack(spacing: 0) {
                topHUD
                Spacer(minLength: 0)
                if let selected {
                    parameterPanel(selected)
                        .padding(.horizontal, 14).padding(.bottom, 14)
                        .simultaneousGesture(DragGesture(minimumDistance: 12)
                            .onChanged { _ in panelDismissID = UUID() }
                            .onEnded { gesture in
                                if gesture.translation.height > 35 &&
                                    gesture.translation.height > abs(gesture.translation.width) {
                                    closePanel()
                                }
                            })
                }
                bottomBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSettings) { SettingsView().environmentObject(camera) }
        .sheet(isPresented: $showingMedia) { MediaLibraryView() }
        .alert("GyroCine", isPresented: Binding(get: { camera.errorText != nil }, set: { if !$0 { camera.clearError() } })) {
            if camera.storageSetupRequired {
                Button(t("设置存储", "Set up storage")) {
                    camera.clearError()
                    showingSettings = true
                }
            }
            Button("确定") { camera.clearError() }
        } message: { Text(camera.errorText ?? "") }
        .onChange(of: camera.exposureSeconds) { _, value in if camera.exposureAuto { shutterValue = value } }
        .onChange(of: camera.shutterMaxSeconds) { _, value in shutterMaxValue = value }
        .onChange(of: camera.iso) { _, value in if camera.exposureAuto { isoValue = Double(value) } }
        .onChange(of: camera.whiteBalanceKelvin) { _, value in if camera.whiteBalanceAuto { wbValue = Double(value) } }
        .onChange(of: camera.lensPosition) { _, value in if camera.focusChoice != .manual { focusValue = Double(value) } }
        .onChange(of: camera.selectedLensID) { _, _ in
            if selected == .lens { dismissPanelAfterAdjustment() }
        }
    }

    private func t(_ chinese: String, _ english: String) -> String {
        AppText.value(chinese, english, locale: locale)
    }

    private func closePanel() {
        panelDismissID = UUID()
        withAnimation(.easeInOut(duration: 0.22)) { selected = nil }
    }

    private func dismissPanelAfterAdjustment() {
        let id = UUID()
        panelDismissID = id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard panelDismissID == id else { return }
            withAnimation(.easeInOut(duration: 0.22)) { selected = nil }
        }
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
                    .font(.system(size: 24, weight: .semibold))
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(camera.recording ? .red : .white)
                }
                Spacer(minLength: 3)
                statusBadge(storageLocation == "外部 SSD" ? "SSD" :
                            storageLocation == "专用视频存储" ? "PVS" : t("本机", "LOCAL"),
                            healthy: storageLocation == "外部 SSD" ? camera.externalStorageConnected :
                                storageLocation == "专用视频存储" ?
                                    (ProVideoStorageBridge.isSupported() && ProVideoStorageBridge.remainingCapacity() > 0) : true)
                statusBadge("IMU", healthy: camera.imuAvailable)
            }
            Text(specification)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1).minimumScaleFactor(0.75)
            HStack(spacing: 0) {
                ForEach(Parameter.allCases) { parameter in
                    Button {
                        panelDismissID = UUID()
                        if selected == parameter {
                            closePanel()
                        } else {
                            if parameter == .shutter {
                                shutterValue = camera.exposureSeconds
                                shutterMaxValue = camera.shutterMaxSeconds
                                shutterAngleValue = camera.shutterAngle
                                shutterAngleMaxValue = min(max(camera.shutterMaxSeconds * camera.fps * 360, 1), 360)
                            }
                            withAnimation(.easeInOut(duration: 0.22)) { selected = parameter }
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Text(parameter.title(locale: locale).uppercased()).font(.system(size: 10, weight: .medium))
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
                    .accessibilityIdentifier("parameter.\(parameter.rawValue)")
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 7)
        .background(LinearGradient(colors: [.black.opacity(0.58), .black.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom))
    }

    private func statusBadge(_ text: String, healthy: Bool) -> some View {
        Text(text + (healthy ? " ✓" : " !"))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(healthy ? .green : .red)
            .padding(.horizontal, 5).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(healthy ? .green : .red, lineWidth: 0.8))
    }

    private var specification: String {
        let codec = camera.selectedEncoding.title
        let format = camera.selectedFormatIndex.flatMap { index in camera.formats.first(where: { $0.index == index }) }
        let resolution = format.map { "\($0.width)×\($0.height)" } ?? "—"
        return "\(codec) · \(resolution) · \(String(format: "%.1f", camera.fps))fps"
    }

    private func value(for parameter: Parameter) -> String {
        switch parameter {
        case .lens: camera.lenses.first(where: { $0.id == camera.selectedLensID })?.label ?? "—"
        case .shutter:
            exposureType == "angle" ? shutterAngleLabel(camera.exposureSeconds) : shutterLabel(camera.exposureSeconds)
        case .iso: String(Int(camera.iso.rounded()))
        case .wb: "\(Int(camera.whiteBalanceKelvin.rounded()))K"
        case .focus:
            switch camera.focusChoice {
            case .continuous: "AF-C"
            case .single, .tap: "AF-S"
            case .locked: t("锁定", "LOCK")
            case .manual: String(format: "%.2f", camera.lensPosition)
            }
        }
    }
    private func isAuto(_ parameter: Parameter) -> Bool {
        switch parameter {
        case .lens: false
        case .shutter: camera.shutterMode == .auto || camera.shutterMode == .autoMax
        case .iso: camera.exposureAuto
        case .wb: camera.whiteBalanceAuto
        case .focus: camera.focusChoice == .continuous || camera.focusChoice == .single || camera.focusChoice == .tap
        }
    }

    private func parameterPanel(_ parameter: Parameter) -> some View {
        VStack(spacing: 5) {
            Capsule().fill(.white.opacity(0.35)).frame(width: 44, height: 4)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(parameter.title(locale: locale)).font(.system(size: 17, weight: .semibold))
                    Text(parameter == .shutter && camera.shutterMode == .autoMax
                         ? "\(t("最长", "Max")) \(exposureType == "angle" ? shutterAngleLabel(camera.shutterMaxSeconds) : shutterLabel(camera.shutterMaxSeconds)) · \(t("实际", "Actual")) \(value(for: parameter))"
                         : parameter == .shutter && exposureType == "angle"
                         ? "\(value(for: parameter)) · \(shutterLabel(camera.exposureSeconds))"
                         : value(for: parameter))
                        .font(.system(size: 14)).foregroundStyle(.white.opacity(0.8))
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
                                    .frame(maxWidth: .infinity).frame(height: 40)
                                    .background(camera.selectedLensID == lens.id ? accent : .white.opacity(0.08), in: Circle())
                            }
                            .accessibilityIdentifier("lens.\(lens.label)")
                            .disabled(camera.recording || camera.preparingRecording || camera.finalizing || camera.switchingLens)
                        }
                    }
                case .shutter:
                    if exposureType == "angle" {
                        movingRuler(value: camera.shutterMode == .autoMax ? $shutterAngleMaxValue : $shutterAngleValue,
                                    range: shutterAngleRange,
                                    majorValues: [11.25, 22.5, 45, 90, 180, 270, 360],
                                    format: { "\(Int($0.rounded()))°" }) {
                            if camera.shutterMode == .autoMax {
                                camera.setExposureAutoMax(seconds: $0 / (360 * max(camera.fps, 1)))
                            } else { camera.setShutterAngle($0) }
                        }
                        .disabled(camera.shutterMode == .auto)
                    } else {
                        movingRuler(value: camera.shutterMode == .autoMax ? $shutterMaxValue : $shutterValue,
                                    range: shutterRulerRange, mapping: .logarithmic,
                                    majorValues: shutterStops + [shutterRulerRange.lowerBound, shutterRulerRange.upperBound],
                                    format: shutterLabel) { value in
                            if camera.shutterMode == .autoMax { camera.setExposureAutoMax(seconds: value) }
                            else { camera.setManualExposure(seconds: value) }
                        }
                        .disabled(camera.shutterMode == .auto)
                    }
                case .iso:
                    movingRuler(value: $isoValue, range: camera.isoRange, mapping: .logarithmic,
                                majorValues: [50, 100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600] +
                                    [camera.isoRange.lowerBound, camera.isoRange.upperBound],
                                format: { String(Int($0.rounded())) }) { camera.setManualExposure(iso: $0) }
                        .disabled(camera.exposureAuto)
                case .wb:
                    movingRuler(value: $wbValue, range: 2000...10000,
                                majorValues: [2000, 3200, 4300, 5600, 6500, 8000, 10000],
                                format: { "\(Int($0.rounded()))" }) { camera.setWhiteBalance(kelvin: Float($0)) }
                        .disabled(camera.whiteBalanceAuto)
                case .focus:
                    movingRuler(value: $focusValue, range: 0...1, majorValues: [0, 0.25, 0.5, 0.75, 1],
                                format: { String(format: "%.2f", $0) }) { camera.setManualPosition(Float($0)) }
                        .disabled(camera.focusChoice != .manual)
                }
            }
            .frame(height: 50)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .frame(height: 126)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.1)))
    }

    private func modePicker(_ parameter: Parameter) -> some View {
        if parameter == .shutter {
            return AnyView(HStack(spacing: 0) {
                shutterButton("A-Max", mode: .autoMax) {
                    camera.activateExposureAutoMax()
                }
                shutterButton("A", mode: .auto) { camera.setExposureAuto(true) }
                shutterButton("M", mode: .manual) {
                    shutterValue = camera.exposureSeconds
                    if exposureType == "angle" {
                        shutterAngleValue = camera.shutterAngle
                        camera.setShutterAngle(shutterAngleValue)
                    } else { camera.setExposureAuto(false) }
                }
            }.background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9)))
        }
        if parameter == .focus {
            return AnyView(HStack(spacing: 0) {
                focusButton("AF-C", choice: .continuous)
                focusButton("MF", choice: .manual)
                focusButton(t("锁定", "LOCK"), choice: .locked)
            }.background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9)))
        }
        return AnyView(HStack(spacing: 0) {
            ForEach([true, false], id: \.self) { auto in
                Button(auto ? "A" : "M") {
                    switch parameter {
                    case .iso:
                        if !auto && camera.exposureAuto { shutterValue = camera.exposureSeconds; isoValue = Double(camera.iso) }
                        camera.setExposureAuto(auto)
                    case .wb:
                        if !auto { wbValue = Double(camera.whiteBalanceKelvin) }
                        camera.setWhiteBalanceAuto(auto)
                    case .lens, .shutter, .focus: break
                    }
                    dismissPanelAfterAdjustment()
                }
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .frame(width: 42, height: 31)
                .background(isAuto(parameter) == auto ? accent : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9)))
    }

    private func shutterButton(_ title: String, mode: ShutterMode, action: @escaping () -> Void) -> some View {
        Button(title) { action(); dismissPanelAfterAdjustment() }
            .font(.system(size: 12, weight: .semibold)).buttonStyle(.plain)
            .frame(width: title == "A-Max" ? 55 : title == "180°" ? 48 : 34, height: 31)
            .background((mode == .manual && camera.shutterMode == .angle) || camera.shutterMode == mode ? accent : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
    }
    private func focusButton(_ title: String, choice: FocusChoice) -> some View {
        Button(title) {
            camera.chooseFocus(choice, manualPosition: choice == .manual ? Float(focusValue) : nil)
            dismissPanelAfterAdjustment()
        }
            .font(.system(size: 11, weight: .semibold)).buttonStyle(.plain)
            .frame(width: title == "LOCK" ? 50 : 42, height: 31)
            .background(camera.focusChoice == choice ? accent : .clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private func movingRuler(value: Binding<Double>, range: ClosedRange<Double>,
                             mapping: RulerMapping = .linear, majorValues: [Double] = [],
                             format: @escaping (Double) -> String,
                             onChange: @escaping (Double) -> Void) -> some View {
        MovingRuler(value: value, range: range, mapping: mapping,
                    majorValues: majorValues, format: format) { selectedValue, finished in
            if finished || Date().timeIntervalSince(lastControlSend) > 0.06 {
                lastControlSend = Date()
                onChange(selectedValue)
            }
            if finished { dismissPanelAfterAdjustment() }
        }.accessibilityIdentifier("parameterRuler")
    }
    private func shutterLabel(_ seconds: Double) -> String {
        seconds > 0 ? "1/\(Int((1 / seconds).rounded()))" : "—"
    }
    private func shutterAngleLabel(_ seconds: Double) -> String {
        seconds > 0 ? "\(Int((seconds * camera.fps * 360).rounded()))°" : "—"
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            ZStack {
                if camera.finalizing {
                    HStack(spacing: 7) { ProgressView().tint(.white); Text(t("正在保存…", "Saving…")) }
                        .foregroundStyle(.white)
                }
            }
            .font(.caption).frame(height: 20)
            HStack(alignment: .center) {
                Button { showingMedia = true } label: {
                    VStack(spacing: 5) { Image(systemName: "photo.on.rectangle").font(.system(size: 25)); Text(t("素材", "Media")).font(.caption) }
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("mediaOpen")
                Button { camera.toggleRecording() } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 68, height: 68)
                        RoundedRectangle(cornerRadius: camera.recording ? 5 : 32)
                            .fill(.red).frame(width: camera.recording ? 29 : 46, height: camera.recording ? 29 : 46)
                    }
                }
                .disabled(!camera.cameraReady || camera.preparingRecording || camera.finalizing || camera.switchingLens)
                .accessibilityLabel(camera.finalizing ? t("正在保存", "Finalizing") : camera.recording ? t("停止录制", "Stop recording") : t("开始录制", "Record"))
                .accessibilityIdentifier("recordToggle")
                .frame(maxWidth: .infinity)
                Button { showingSettings = true } label: {
                    VStack(spacing: 5) { Image(systemName: "gearshape").font(.system(size: 25)); Text(t("设置", "Settings")).font(.caption) }
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("settingsOpen")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .frame(height: 78)
        }
        .padding(.horizontal, 14)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.22), .black.opacity(0.48)], startPoint: .top, endPoint: .bottom))

    }
}
