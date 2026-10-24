import AVFoundation
import AVKit
import SwiftUI
import MetalKit
import UniformTypeIdentifiers

private struct Preview: UIViewRepresentable {
    let session: AVCaptureSession
    let lut: LUTPreview
    let lutEnabled: Bool
    let captureEnabled: Bool
    let onCapture: () -> Void
    let captureLog: (String, [String: Any]) -> Void
    let onAttached: () -> Void
    let onTap: (CGPoint) -> Void
    let onLongPress: (CGPoint) -> Void
    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.installLUT(lut)
        view.onTap = onTap
        view.onLongPress = onLongPress
        view.configureCaptureControls(enabled: captureEnabled, action: onCapture, log: captureLog)
        onAttached()
        return view
    }
    func updateUIView(_ view: PreviewUIView, context: Context) {
        view.onTap = onTap; view.onLongPress = onLongPress
        view.configureCaptureControls(enabled: captureEnabled, action: onCapture, log: captureLog)
        lut.setDisplayActive(lutEnabled)
        view.lutView?.setRefreshActive(lutEnabled)
        if !lutEnabled { view.lutView?.alpha = 0 }
    }
}

private final class LUTRefreshTarget: NSObject {
    @objc func tick() {} // Request display cadence only; rendering is capture-driven off-main.
}

private final class LUTMetalView: UIView {
    private var refreshLink: CADisplayLink?
    private let refreshTarget = LUTRefreshTarget()
    private var refreshActive = false
    func setRefreshActive(_ active: Bool) {
        refreshActive = active
        if refreshLink == nil {
            let link = CADisplayLink(target: refreshTarget, selector: #selector(LUTRefreshTarget.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            refreshLink = link
        }
        refreshLink?.isPaused = !active || window == nil
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshLink?.isPaused = !refreshActive || window == nil
    }
    deinit { refreshLink?.invalidate() }

    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
}

private final class PreviewUIView: UIView {
    var onTap: ((CGPoint) -> Void)?
    var onLongPress: ((CGPoint) -> Void)?
    private var captureInteraction: AVCaptureEventInteraction?
    private var captureEnabled = false
    private var captureAction: (() -> Void)?
    private var captureLog: ((String, [String: Any]) -> Void)?

    func configureCaptureControls(enabled: Bool, action: @escaping () -> Void,
                                  log: @escaping (String, [String: Any]) -> Void) {
        captureAction = action; captureLog = log; captureEnabled = enabled
        if captureInteraction == nil {
            let interaction = AVCaptureEventInteraction { [weak self] event in
                guard let self else { return }
                self.captureLog?("hardware_capture_event", ["phase": String(describing: event.phase),
                    "enabled": self.captureEnabled, "inWindow": self.window != nil])
                if event.phase == .ended && self.captureEnabled { self.captureAction?() }
            }
            interaction.isEnabled = false
            addInteraction(interaction)
            captureInteraction = interaction
        }
        updateCaptureInteraction()
    }

    private func updateCaptureInteraction() {
        let enabled = captureEnabled && window != nil
        guard captureInteraction?.isEnabled != enabled else { return }
        captureInteraction?.isEnabled = enabled
        captureLog?("hardware_capture_enabled", ["enabled": enabled, "inWindow": window != nil,
            "sessionRunning": previewLayer.session?.isRunning ?? false])
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateCaptureInteraction()
    }

    private let focusFrame = UIView()
    var lutView: LUTMetalView?
    private var lutRenderer: LUTPreview?
    func installLUT(_ renderer: LUTPreview) {
        guard let device = renderer.metalDevice else { return }
        let view = LUTMetalView(frame: bounds)
        lutRenderer = renderer
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.metalLayer.device = device
        view.metalLayer.framebufferOnly = false
        view.metalLayer.pixelFormat = .bgra8Unorm
        view.metalLayer.allowsNextDrawableTimeout = true
        view.metalLayer.maximumDrawableCount = 3
        view.alpha = 0
        view.isUserInteractionEnabled = false
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
        insertSubview(view, belowSubview: focusFrame)
        lutView = view
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = min(window?.screen.scale ?? 2, 1920 / max(1, max(bounds.width, bounds.height)))
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        if lutView?.metalLayer.drawableSize != size { lutView?.metalLayer.drawableSize = size }
        if let lutView { lutRenderer?.attach(view: lutView, size: size) }
    }
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
    case lens = "Lens", shutter = "Shutter", iso = "ISO", ev = "EV", wb = "WB", focus = "Focus", lut = "LUT"
    var id: Self { self }
    func title(locale: Locale) -> String {
        switch self {
        case .lut: "LUT"
        case .lens: AppText.value("镜头", "Lens", locale: locale)
        case .shutter: AppText.value("快门", "Shutter", locale: locale)
        case .iso: "ISO"
        case .ev: AppText.value("补偿", "EV", locale: locale)
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
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("showCompositionGrid") private var showCompositionGrid = false
    @AppStorage("showHorizonLevel") private var showHorizonLevel = false
    @AppStorage("storageLocation") private var storageLocation = "内部文件"
    @AppStorage("rulerHaptics") private var rulerHaptics = true
    @AppStorage("exposureType") private var exposureType = "speed"
    @State private var selected: Parameter?
    @State private var showingCaptureSetup = false
    @State private var showingSlate = false
    @State private var lutCard: String?
    @State private var showingLUTCredits = false
    @State private var panelDismissID = UUID()
    @State private var showingSettings = false
    @State private var showingMedia = false
    @State private var showingSpeedDiagnostic = false
    @State private var showingWBPresets = false
    @State private var shutterValue = 1.0 / 120.0
    @State private var shutterMaxValue = 1.0 / 200.0
    @State private var shutterAngleValue = 180.0
    @State private var shutterAngleMaxValue = 180.0
    @State private var evValue = 0.0
    @State private var isoValue = 400.0
    @State private var wbValue = 5600.0
    @State private var focusValue = 0.5
    @State private var focusNotice: String?
    @State private var focusNoticeID = UUID()
    @State private var lastControlSend = Date.distantPast
    @State private var lastCaptureShortcut = -Double.infinity
    private let accent = Color(red: 0.08, green: 0.62, blue: 1)
    private let shutterStops: [Double] = [4000, 2000, 1000, 500, 250, 200, 120, 60, 30, 15, 10]
        .map { 1.0 / $0 }

    private var captureControlsEnabled: Bool {
        scenePhase == .active && camera.cameraReady && !camera.preparingRecording &&
        !camera.finalizing && !camera.ssdSpeedTesting && !camera.switchingLens && camera.errorText == nil &&
        !showingSettings && !showingCaptureSetup && !showingSlate && !showingMedia &&
        !showingWBPresets && !showingLUTCredits
    }

    private func captureShortcut() {
        let now = ProcessInfo.processInfo.systemUptime
        let accepted = captureControlsEnabled && now - lastCaptureShortcut > 0.35
        camera.logger.event("capture_shortcut_request", ["accepted": accepted,
            "ready": camera.cameraReady, "recording": camera.recording,
            "preparing": camera.preparingRecording, "finalizing": camera.finalizing,
            "sceneActive": scenePhase == .active])
        guard accepted else { return }
        lastCaptureShortcut = now
        camera.toggleRecording()
    }

    private var shutterRulerRange: ClosedRange<Double> {
        let lower = max(camera.exposureRange.lowerBound, 1.0 / 8000)
        let upper = min(camera.exposureRange.upperBound, 1.0 / max(camera.fps, 1))
        return lower <= upper ? lower...upper : camera.exposureRange
    }

    private var shutterAngleRange: ClosedRange<Double> {
        let minimum = max(1, 360 * max(camera.exposureRange.lowerBound, 1.0 / 8000) * camera.fps)
        let maximum = min(360, 360 * camera.exposureRange.upperBound * camera.fps)
        return minimum <= maximum ? minimum...maximum : 1...360
    }

    var body: some View {
        ZStack {
            Preview(session: camera.session, lut: camera.lutPreview, lutEnabled: camera.lutEnabled && camera.lutSupported,
                    captureEnabled: captureControlsEnabled, onCapture: captureShortcut,
                    captureLog: camera.logger.event, onAttached: camera.startCapture, onTap: camera.tapFocus, onLongPress: camera.lockFocus)
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
            if let focusNotice {
                VStack {
                    Text(focusNotice)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("focusNotice")
                        .padding(.horizontal, 15).padding(.vertical, 9)
                        .background(.black.opacity(0.8), in: Capsule())
                        .padding(.top, 125)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        // Keep viewfinder controls dark without imposing a window-wide appearance on sheets.
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showingSettings) { SettingsView().environmentObject(camera) }
        .sheet(isPresented: $camera.showingProLimit) { ProAccessView(limitReached: true) }
        .sheet(isPresented: $showingCaptureSetup) {
            SettingsView(quickCapture: true).environmentObject(camera)
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingSlate) { RecordingSlateView().environmentObject(camera) }
        .sheet(isPresented: $showingMedia) { MediaLibraryView() }
        .sheet(isPresented: $showingSpeedDiagnostic) { SSDSpeedTestView() }
        .onChange(of: camera.ssdSpeedTesting) { _, active in
            #if DEBUG
            if active && ProcessInfo.processInfo.arguments.contains("--ssd-speed-probe") {
                camera.clearError(); showingSpeedDiagnostic = true
            }
            #endif
        }
        .onChange(of: camera.cameraReady) { _, ready in
            #if DEBUG
            if ready && ProcessInfo.processInfo.arguments.contains("--show-media-diagnostic") { showingMedia = true }
            #endif
        }
        .sheet(isPresented: $showingLUTCredits) {
            NavigationStack {
                Form {
                    Section("slay LUTs") {
                        Text("Amber · Fade · Neon · Film · Portrait")
                        Text(t("作者：slay。授权：CC BY 4.0。原始 LUT 未修改；预览时与 GyroCine 的 Rec.709 转换合成。", "By slay. CC BY 4.0. Original LUT files are unchanged; composed with GyroCine's Rec.709 transform for preview."))
                        Link("slaycamera.com", destination: URL(string: "https://www.slaycamera.com")!)
                        Link(t("原始 LUT 与来源", "Original LUTs and source"), destination: URL(string: "https://github.com/slaycamera/luts")!)
                        Link("CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                    }
                }.navigationTitle(t("LUT 来源", "LUT credits"))
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(t("完成", "Done")) { showingLUTCredits = false } } }
            }
        }
        .sheet(isPresented: $showingWBPresets) { whiteBalancePresets }
        .onChange(of: camera.selectedLUTID) { _, value in lutCard = value }
        .alert("GyroCine", isPresented: Binding(get: { camera.errorText != nil }, set: { if !$0 { camera.clearError() } })) {
            if camera.storageSetupRequired {
                Button(t("设置存储", "Set up storage")) {
                    camera.clearError()
                    showingSettings = true
                }
            }
            Button(t("确定", "OK")) { camera.clearError() }
        } message: { Text(AppText.message(camera.errorText ?? "")) }
        .onChange(of: scenePhase) { _, phase in camera.lutPreview.setForeground(phase == .active) }
        .onChange(of: camera.exposureSeconds) { _, value in if camera.exposureAuto { shutterValue = value } }
        .onChange(of: camera.shutterMaxSeconds) { _, value in shutterMaxValue = value }
        .onChange(of: camera.iso) { _, value in if camera.exposureAuto { isoValue = Double(value) } }
        .onChange(of: camera.whiteBalanceKelvin) { _, value in if camera.whiteBalanceAuto { wbValue = Double(value) } }
        .onChange(of: camera.lensPosition) { _, value in if camera.focusChoice != .manual { focusValue = Double(value) } }
        .onChange(of: camera.focusChoice) { _, choice in
            switch choice {
            case .locked: showFocusNotice(t("对焦已锁定 · 轻点画面恢复自动", "Focus locked · Tap to return to auto"))
            case .continuous, .single, .tap: showFocusNotice(t("自动对焦已开启", "Autofocus on"))
            case .manual: break
            }
        }
        .onChange(of: camera.selectedLensID) { _, _ in
            if selected == .lens { dismissPanelAfterAdjustment() }
        }
    }

    private func t(_ chinese: String, _ english: String) -> String {
        AppText.value(chinese, english, locale: locale)
    }

    private func showFocusNotice(_ message: String) {
        let id = UUID()
        focusNoticeID = id
        focusNotice = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if focusNoticeID == id { focusNotice = nil }
        }
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
                                    (camera.checkedStorageLocation == storageLocation
                                        ? (camera.availableStorageBytes ?? 0) > 0 : nil) : true)
                statusBadge(camera.telemetryEmbeddable ? "IMU" : "!IMU",
                            healthy: camera.imuAvailable && camera.telemetryEmbeddable)
            }
            if camera.focusChoice == .locked {
                Label(t("对焦锁定", "FOCUS LOCK"), systemImage: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())
                    .accessibilityIdentifier("focusLockIndicator")
            }
            if camera.checkedStorageLocation == storageLocation,
               let bytes = camera.availableStorageBytes, bytes >= 0,
               let seconds = camera.estimatedRecordingSeconds, seconds.isFinite {
                Text(String(format: seconds < 60
                            ? t("剩余 %.1f GB · 约 %d 秒", "Free %.1f GB · ~%d sec")
                            : t("剩余 %.1f GB · 约 %d 分 %02d 秒", "Free %.1f GB · ~%d min %02d sec"),
                            Double(bytes) / 1_000_000_000, Int(seconds < 60 ? seconds : seconds / 60), Int(seconds) % 60))
                    .font(.system(size: 11)).foregroundStyle(seconds < 60 ? .red : .white.opacity(0.7))
                    .accessibilityIdentifier("storageRemaining")
            } else {
                Text(t("剩余 — GB · 约 — 分钟", "Free — GB · ~— min"))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                    .accessibilityIdentifier("storageRemaining")
            }
            HStack(spacing: 4) {
                Color.clear.frame(width: 40, height: 40).accessibilityHidden(true)
                Spacer(minLength: 0)
            Button {
                closePanel()
                showingCaptureSetup = true
            } label: {
                HStack(spacing: 6) {
                    Text(specification + (camera.lutEnabled && camera.lutSupported && ["active", "rec709"].contains(camera.lutStatus) ? " · LUT \(camera.selectedImportedLUT != nil ? t("自定", "Custom") : (camera.lutLook == .rec709 ? "709" : camera.lutLook.rawValue.capitalized))" : ""))
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.black.opacity(0.22), in: Capsule())
            }
            .disabled(camera.recording || camera.preparingRecording || camera.finalizing)
            .accessibilityIdentifier("captureSetupOpen")
                .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            Button { closePanel(); showingSlate = true } label: {
                Image(systemName: "movieclapper").frame(width: 40, height: 40)
            }.accessibilityLabel(t("场记", "Slate")).accessibilityIdentifier("slateOpen")
                .disabled(camera.recording || camera.preparingRecording || camera.finalizing)
            }
            HStack(spacing: 0) {
                ForEach(Parameter.allCases) { parameter in
                    Button {
                        panelDismissID = UUID()
                        if selected == parameter {
                            closePanel()
                        } else {
                            if parameter == .ev { evValue = camera.exposureBias }
                            if parameter == .iso { isoValue = Double(camera.iso) }
                            if parameter == .wb { wbValue = Double(camera.whiteBalanceKelvin) }
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
                                Text(value(for: parameter)).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                                if isAuto(parameter) {
                                    Text(parameter == .shutter && camera.shutterMode == .autoMax ? "AM" : "A")
                                        .font(.system(size: 9, weight: .bold)).foregroundStyle(accent)
                                }
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

    @ViewBuilder private func statusBadge(_ text: String, healthy: Bool?) -> some View {
        let color: Color = healthy.map { $0 ? .green : .red } ?? .gray
        let badge = Text(text + (healthy.map { $0 ? " ✓" : " !" } ?? " …"))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(color, lineWidth: 0.8))
            .accessibilityLabel(healthy == nil ? text + " · " + t("检测中", "Checking") : text)
        #if DEBUG
        badge
            .accessibilityValue(healthy.map { $0 ? "connected" : "disconnected" } ?? "checking")
            .accessibilityIdentifier("status.\(text)")
        #else
        badge
        #endif
    }

    private var specification: String {
        let codec = camera.selectedEncoding.title
        let format = camera.selectedFormatIndex.flatMap { index in camera.formats.first(where: { $0.index == index }) }
        let resolution = format.map { "\($0.width)×\($0.height)" } ?? "—"
        return "\(codec) · \(resolution) · \(String(format: "%.1f", camera.fps))fps"
    }

    private func value(for parameter: Parameter) -> String {
        switch parameter {
        case .lut:
            !camera.lutEnabled || !camera.lutSupported ? t("关", "Off") :
                (["active", "rec709"].contains(camera.lutStatus) ? (camera.selectedImportedLUT != nil ? t("自定", "Custom") : (camera.lutLook == .rec709 ? "709" : camera.lutLook.rawValue.capitalized)) : "…")
        case .lens: camera.lenses.first(where: { $0.id == camera.selectedLensID })?.label ?? "—"
        case .shutter:
            exposureType == "angle" ? shutterAngleLabel(camera.exposureSeconds) : shutterLabel(camera.exposureSeconds)
        case .iso: String(Int(camera.iso.rounded()))
        case .ev: String(format: "%+.1f", camera.exposureBias)
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
        case .lens, .ev, .lut: false
        case .shutter: camera.shutterMode == .auto || camera.shutterMode == .autoMax
        case .iso: camera.exposureAuto
        case .wb: camera.whiteBalanceAuto
        case .focus: camera.focusChoice == .continuous || camera.focusChoice == .single || camera.focusChoice == .tap
        }
    }

    private var whiteBalancePresets: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(Array(zip(["日光", "阴影", "多云", "钨丝灯", "荧光灯", "闪光灯"],
                                      [5600, 7000, 6500, 3200, 4000, 5500])), id: \.0) { name, kelvin in
                        Button {
                            wbValue = Double(kelvin)
                            camera.setWhiteBalance(kelvin: Float(kelvin))
                            showingWBPresets = false
                            dismissPanelAfterAdjustment()
                        } label: {
                            VStack(spacing: 8) {
                                Text(t(name, ["日光": "Daylight", "阴影": "Shade", "多云": "Cloudy", "钨丝灯": "Tungsten", "荧光灯": "Fluorescent", "闪光灯": "Flash"][name] ?? name))
                                    .font(.headline)
                                Text("\(kelvin)K").font(.subheadline).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 76)
                            .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(0.45)))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("wb.preset.\(kelvin)")
                    }
                }
                .padding(16)
            }
            .navigationTitle(t("白平衡预设", "White balance presets"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(t("关闭", "Close")) { showingWBPresets = false }
                }
            }
        }
        .presentationDetents([.height(380), .large])
        .presentationDragIndicator(.visible)
    }

    private func parameterPanel(_ parameter: Parameter) -> some View {
        VStack(spacing: 5) {
            Capsule().fill(.white.opacity(0.35)).frame(width: 44, height: 4)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(parameter.title(locale: locale)).font(.system(size: 17, weight: .semibold))
                    Text(parameter == .shutter && exposureType == "angle"
                         ? "\(shutterAngleLabel(camera.exposureSeconds)) · \(shutterLabel(camera.exposureSeconds))" + (camera.shutterMode == .autoMax ? " · \(t("最长", "Max")) \(shutterLabel(camera.shutterMaxSeconds))" : "")
                         : parameter == .shutter && camera.shutterMode == .autoMax
                         ? "\(t("最长", "Max")) \(exposureType == "angle" ? shutterAngleLabel(camera.shutterMaxSeconds) : shutterLabel(camera.shutterMaxSeconds)) · \(t("实际", "Actual")) \(value(for: parameter))"
                         : parameter == .shutter && exposureType == "angle"
                         ? "\(value(for: parameter)) · \(shutterLabel(camera.exposureSeconds))"
                         : value(for: parameter))
                        .font(.system(size: 14)).foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                if parameter == .wb {
                    Button {
                        panelDismissID = UUID() // Keep the controls alive while choosing a preset.
                        showingWBPresets = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sun.max.fill").foregroundStyle(accent)
                            Text(t("预设", "Presets"))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .background(accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(accent.opacity(0.6), lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityLabel(t("白平衡预设", "White balance presets"))
                    .accessibilityHint(t("选择日光、阴影等六种预设", "Choose from six lighting presets"))
                    .accessibilityIdentifier("wb.presets")
                }
                if parameter != .lens && parameter != .ev && parameter != .lut { modePicker(parameter) }
            }
            Group {
                switch parameter {
                case .lut:
                    lutControls
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
                                    majorValues: [11.25, 22.5, 45, 90, 180, 270, 360], snapValues: ControlStops.angle,
                                    format: { "\(String(format: "%g", $0))°\n\(shutterLabel($0 / (360 * max(camera.fps, 1))))" }) {
                            if camera.shutterMode == .autoMax {
                                camera.setExposureAutoMax(seconds: $0 / (360 * max(camera.fps, 1)))
                            } else { camera.setShutterAngle($0) }
                        }
                        .disabled(camera.shutterMode == .auto)
                    } else {
                        movingRuler(value: camera.shutterMode == .autoMax ? $shutterMaxValue : $shutterValue,
                                    range: shutterRulerRange, mapping: .logarithmic,
                                    majorValues: shutterStops + [shutterRulerRange.lowerBound, shutterRulerRange.upperBound],
                                    snapValues: ControlStops.shutter,
                                    format: shutterLabel) { value in
                            if camera.shutterMode == .autoMax { camera.setExposureAutoMax(seconds: value) }
                            else { camera.setManualExposure(seconds: value) }
                        }
                        .disabled(camera.shutterMode == .auto)
                    }
                case .iso:
                    movingRuler(value: $isoValue, range: camera.isoRange, mapping: .logarithmic,
                                majorValues: [50, 100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600] +
                                    [camera.isoRange.lowerBound, camera.isoRange.upperBound], snapValues: ControlStops.iso,
                                format: { String(Int($0.rounded())) }) { camera.setManualExposure(iso: $0) }
                        .disabled(camera.exposureAuto)
                case .ev:
                    movingRuler(value: $evValue, range: camera.exposureBiasRange,
                                majorValues: Array(-6...6).map(Double.init),
                                snapValues: (-18...18).map { Double($0) / 3 },
                                format: { String(format: "%+.1f", $0) }) { camera.setExposureBias($0) }
                        .disabled(!camera.exposureAuto)
                        .overlay(alignment: .bottom) {
                            if !camera.exposureAuto { Text(t("自动曝光时可调", "Available with auto exposure")).font(.caption2) }
                        }
                case .wb:
                    movingRuler(value: $wbValue, range: 2500...10000,
                                majorValues: [2500, 3200, 4300, 5600, 6500, 8000, 10000],
                                format: { "\(Int($0.rounded()))" }) { camera.setWhiteBalance(kelvin: Float($0)) }
                        .disabled(camera.whiteBalanceAuto)
                case .focus:
                    movingRuler(value: $focusValue, range: 0...1, majorValues: [0, 0.25, 0.5, 0.75, 1],
                                format: { String(format: "%.2f", $0) }) { camera.setManualPosition(Float($0)) }
                        .disabled(camera.focusChoice != .manual)
                }
            }
            .frame(height: parameter == .lut ? 106 : 60)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .frame(height: parameter == .lut ? 172 : 136)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.1)))
    }

    private var lutControls: some View {
        VStack(spacing: 5) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(["off"] + camera.visibleBuiltinLUTs.map(\.rawValue) + camera.visibleImportedLUTs.map(\.selectionID), id: \.self) { id in
                        let look = PreviewLook(rawValue: id)
                        let imported = camera.importedLUTs.first { $0.selectionID == id }
                        let active = (camera.lutEnabled && camera.lutSupported ? camera.selectedLUTID : "off") == id
                        Button {
                            if let imported { camera.selectImportedLUT(imported) }
                            else if let look { camera.setLUTLook(look) }
                            else { camera.setLUTEnabled(false) }
                            withAnimation(.easeInOut(duration: 0.2)) { lutCard = id }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: id == "off" ? "circle.slash" : "square.stack.3d.up")
                                Text(imported?.name ?? look?.title ?? t("关闭", "Off")).lineLimit(1)
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 150, height: 34)
                            .foregroundStyle(active ? .white : .white.opacity(0.55))
                            .background(active ? accent.opacity(0.45) : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(active ? accent : .clear, lineWidth: 2))
                        }
                        .id(id).buttonStyle(.plain)
                        .disabled(camera.lutControlsLocked || (id != "off" && !camera.lutSupported))
                        .accessibilityIdentifier("lut.\(id)")

                    }
                }.scrollTargetLayout().padding(.horizontal, 2)
            }
            .accessibilityIdentifier("lut.carousel")
            .contentMargins(.horizontal, 90, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $lutCard, anchor: .center)
            .onAppear { lutCard = camera.lutEnabled && camera.lutSupported ? camera.selectedLUTID : "off" }
            .onChange(of: lutCard) { _, selected in
                guard let selected, camera.lutSupported, !camera.lutControlsLocked else { return }
                if let item = camera.importedLUTs.first(where: { $0.selectionID == selected }) { camera.selectImportedLUT(item) }
                else if let look = PreviewLook(rawValue: selected) { camera.setLUTLook(look) }
                else { camera.setLUTEnabled(false) }
            }
            Toggle(isOn: Binding(
                get: { camera.lutBurnEnabled && !camera.selectedEncoding.isRAW },
                set: camera.setLUTBurnEnabled)) {
                    HStack(spacing: 10) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(camera.lutBurnEnabled ? Color.orange : Color.white)
                        Text(camera.selectedEncoding.isRAW
                             ? t("RAW 不支持烧录", "Unavailable for RAW")
                             : t("烧录到视频", "Burn LUT into video"))
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .toggleStyle(.switch)
                .tint(.orange)
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(camera.lutBurnEnabled ? Color.orange.opacity(0.22) : Color.white.opacity(0.09),
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(camera.lutBurnEnabled ? Color.orange : Color.white.opacity(0.2), lineWidth: 1))
                .disabled(camera.selectedEncoding.isRAW || camera.lutControlsLocked)
                .accessibilityIdentifier("lut.burn")
            HStack {
                Text(lutDescription).accessibilityIdentifier("lut.status")
                Button { showingLUTCredits = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel(t("LUT 来源与授权", "LUT credits and license"))
            }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
        }
    }
    private var lutDescription: String {
        guard camera.lutSupported else {
            if ["aprn", "aprh"].contains(camera.selectedCodec?.rawValue ?? "") {
                return t("此配置暂不支持 LUT 预览", "LUT preview unavailable for this configuration")
            }
            return t("此配置暂不支持 LUT 预览", "LUT preview unavailable for this configuration")
        }
        if !camera.lutEnabled { return t("LUT 已关闭 · 不写入视频", "LUT off · Not recorded") }
        switch camera.lutStatus {
        case "active", "rec709": return "\(camera.selectedLUTTitle) · \(camera.lutBurnEnabled ? t("烧录开启", "Recorded to clip") : t("仅预览", "Preview only"))"
        case "unsupported", "unavailable": return t("当前预览不支持转换 · 已显示原画面", "Conversion unavailable · Original preview")
        default: return t("正在准备 LUT 预览…", "Preparing LUT preview…")
        }
    }

    private func modePicker(_ parameter: Parameter) -> some View {
        if parameter == .wb && (camera.selectedCodec?.rawValue == "aprn" || camera.selectedCodec?.rawValue == "aprh") {
            return AnyView(Label(t("锁定", "Locked"), systemImage: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).frame(height: 31)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityIdentifier("wb.rawLocked"))
        }
        if parameter == .wb && camera.selectedCodec?.rawValue != "aprn" && camera.selectedCodec?.rawValue != "aprh" {
            return AnyView(HStack(spacing: 0) {
                ForEach(WhiteBalanceChoice.allCases, id: \.self) { choice in
                    Button(choice == .autoLock ? "AL" : choice == .auto ? "A" : "M") {
                        camera.setWhiteBalanceChoice(choice)
                        dismissPanelAfterAdjustment()
                    }
                    .accessibilityIdentifier("wb.mode.\(choice.rawValue)")
                    .font(.system(size: 11, weight: .semibold)).buttonStyle(.plain)
                    .frame(width: choice == .autoLock ? 48 : 43, height: 31)
                    .background(camera.whiteBalanceChoice == choice ? accent : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
            }.background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9)))
        }
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
                        if auto || camera.exposureAuto { camera.setExposureAuto(auto) }
                    case .wb:
                        if !auto { wbValue = Double(camera.whiteBalanceKelvin) }
                        camera.setWhiteBalanceAuto(auto)
                    case .lens, .shutter, .focus, .ev, .lut: break
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
                             mapping: RulerMapping = .linear, majorValues: [Double] = [], snapValues: [Double] = [],
                             format: @escaping (Double) -> String,
                             onChange: @escaping (Double) -> Void) -> some View {
        MovingRuler(value: value, range: range, mapping: mapping,
                    majorValues: majorValues, snapValues: snapValues, haptics: rulerHaptics,
                    onInteractionBegan: { camera.setRulerHaptics(rulerHaptics) }, format: format) { selectedValue, finished in
            if finished || Date().timeIntervalSince(lastControlSend) > 0.06 {
                lastControlSend = Date()
                onChange(selectedValue)
            }
            if finished { dismissPanelAfterAdjustment() }
        }.accessibilityIdentifier("parameterRuler")
    }
    private func shutterLabel(_ seconds: Double) -> String {
        seconds >= 1 ? String(format: "%g s", seconds) : seconds > 0 ? "1/\(Int((1 / seconds).rounded()))" : "—"
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
                Button { captureShortcut() } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 68, height: 68)
                        RoundedRectangle(cornerRadius: camera.recording ? 5 : 32)
                            .fill(.red).frame(width: camera.recording ? 29 : 46, height: camera.recording ? 29 : 46)
                    }
                }
                .disabled(!captureControlsEnabled)
                .keyboardShortcut(.space, modifiers: [])
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
