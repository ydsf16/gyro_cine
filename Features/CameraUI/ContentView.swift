import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import AVKit
import Photos

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.layerForPreview.session = session
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) { view.updateRotation() }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var layerForPreview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        layerForPreview.videoGravity = .resizeAspectFill
    }
    override func layoutSubviews() { super.layoutSubviews(); updateRotation() }
    func updateRotation() {
        // Preview rotation only; the MOV buffers and intrinsic coordinates stay native.
        let orientation = window?.windowScene?.interfaceOrientation
        let angle: CGFloat = orientation == .landscapeLeft ? 180 : orientation == .landscapeRight ? 0 : 90
        if let connection = layerForPreview.connection, connection.videoRotationAngle != angle,
           connection.isVideoRotationAngleSupported(angle) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            connection.videoRotationAngle = angle
            CATransaction.commit()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct ContentView: View {
    @ObservedObject var model: RecorderViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false
    @State private var showingLibrary = false
    @State private var selectedControl: CameraControl?
    private var recording: Bool { model.state == .recording }
    private var busy: Bool { recording || model.state == .finalizing || model.state == .configuring }
    private let blue = RecorderTheme.accent

    var body: some View {
        ZStack {
            // A single edge-to-edge preview survives rotation and panel changes.
            // Aspect fill crops the preview only; recorded buffers stay unchanged.
            CameraPreview(session: model.previewSession)
                .ignoresSafeArea()
                .accessibilityIdentifier("cameraViewfinder")
            GeometryReader { geometry in
                let landscape = geometry.size.width > geometry.size.height
                Group {
                    if landscape {
                        HStack(spacing: 0) {
                            viewfinder(landscape: true)
                            actionRail(landscape: true).frame(width: 88)
                        }
                    } else {
                        VStack(spacing: 0) {
                            viewfinder(landscape: false).padding(.horizontal, 16)
                            if let selection = selectedControl {
                                CameraControlView(model: model, selection: selection, portrait: true) { selectedControl = nil }
                                    .frame(height: CameraControlView.portraitHeight(for: selection))
                                    .padding(.horizontal, 16)
                            } else {
                                HStack(spacing: 18) {
                                    ForEach(model.lenses) { lens in lensButton(lens) }
                                }.frame(maxWidth: .infinity).frame(height: 64)
                                    .padding(.horizontal, 32)
                                    .accessibilityIdentifier("portraitLensBar")
                            }
                            actionRail(landscape: false).frame(height: 94)
                                .padding(.horizontal, 16).padding(.bottom, 8)
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .transaction { transaction in transaction.animation = nil }
                .foregroundStyle(.white)
            }
        }.background(.black).statusBarHidden()
            .sheet(isPresented: $showingSettings) { SettingsView(model: model) }
            .sheet(isPresented: $showingLibrary) { RecordingLibraryView(model: model) }
            .task { model.prepare() }
            .onChange(of: model.audioEnabled) { _, _ in if !busy { model.reconfigure() } }
            .onChange(of: model.codecMode) { _, _ in if !busy { model.reconfigure() } }
            .onChange(of: model.colorSpace) { _, _ in if !busy { model.reconfigure() } }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active && (recording || model.state == .configuring) { model.stop() }
            }
            .onChange(of: model.state) { _, state in
                if state == .finalizing { selectedControl = nil }
            }
    }

    private var portraitHUD: some View {
        VStack(spacing: 6) {
            HStack {
                Color.clear.frame(width: 44, height: 44)
                Spacer()
                timecode.font(.system(size: 25, weight: .medium, design: .monospaced))
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }.padding(.horizontal, 10)
            HStack(spacing: 1) {
                ForEach(CameraControl.allCases) { selection in
                    hudParameter(selection, compact: true)
                }
            }

        }.padding(.top, 10).padding(.bottom, 8)
    }

    private var landscapeHUD: some View {
        HStack(alignment: .top, spacing: 2) {
            hudParameter(.resolution); hudParameter(.fps)
            timecode.font(.system(size: 24, weight: .regular, design: .monospaced))
                .minimumScaleFactor(0.7).lineLimit(1).frame(maxWidth: .infinity).padding(.top, 14)
                .accessibilityIdentifier("recordingTimecode")
            hudParameter(.shutter); hudParameter(.whiteBalance)
        }.padding(.horizontal, 8).padding(.top, 6)
    }

    private var timecode: some View {
        Text(String(format: "%02d:%02d:%02d", model.elapsedSeconds / 3600,
                    (model.elapsedSeconds / 60) % 60, model.elapsedSeconds % 60))
            .foregroundStyle(recording ? .red : .white).monospacedDigit()
    }

    private func value(for selection: CameraControl) -> String {
        switch selection {
        case .resolution:
            guard let mode = model.selectedMode else { return "—" }
            return mode.resolutionBadge
        case .fps: return model.selectedMode.map { "\($0.fps)Hz" } ?? "—"
        case .shutter: return model.shutter == .auto ? "Auto" : "1/" + String(model.shutter.rawValue)
        case .whiteBalance: return model.controls.automaticWhiteBalance ? "Auto" : String(Int(model.controls.temperature)) + "K"
        }
    }

    private func hudParameter(_ selection: CameraControl, compact: Bool = false) -> some View {
        let isSensor = selection != .resolution && selection != .fps
        let enabled = isSensor ? model.canAdjustSensorControls && !(recording && model.selectedCodec.isRAW && selection == .whiteBalance) : !busy
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { selectedControl = selectedControl == selection ? nil : selection }
        } label: {
            VStack(alignment: .center, spacing: 3) {
                Image(systemName: selection == .resolution ? "rectangle.dashed" : selection == .fps ? "film.stack" : selection == .shutter ? "camera.aperture" : "sun.max")
                    .font(.system(size: 12, weight: .medium))
                Text(value(for: selection)).font(.system(size: compact ? 15 : 18, weight: .medium))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
            }.frame(maxWidth: .infinity, minHeight: 42).padding(.horizontal, compact ? 3 : 5).padding(.vertical, 3)
                .background(selectedControl == selection ? blue.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.45)
            .accessibilityIdentifier("control_" + selection.id)
    }

    private func viewfinder(landscape: Bool) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.clear
                VStack(spacing: 0) {
                    if landscape { landscapeHUD } else { portraitHUD }
                    Spacer(minLength: 0)
                    if model.state == .finalizing {
                        Text("正在保存…").font(.caption).padding(8)
                    }
                }
                if landscape, let selection = selectedControl {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        CameraControlView(model: model, selection: selection) { selectedControl = nil }
                            .frame(width: landscape ? 164 : 148)
                    }.padding(.top, landscape ? 58 : 0).padding(.bottom, 0)
                        .transition(.opacity).zIndex(2)
                } else if landscape {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            ForEach(model.lenses.reversed()) { lens in lensButton(lens) }
                        }.padding(6)
                    }.padding(.top, 78).padding(.bottom, 66).padding(.trailing, 8)
                }
                if let message = model.message, model.state == .failed {
                    VStack(spacing: 12) {
                        Text(message).font(.system(size: 12)).multilineTextAlignment(.center).lineLimit(5)
                        Button("重试相机") { model.retry() }.buttonStyle(.borderedProminent).tint(blue)
                    }.padding(16).frame(maxWidth: min(geometry.size.width - 30, 380))
                        .background(Color(white: 0.08).opacity(0.95), in: RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
    }

    private func lensButton(_ lens: CameraLens) -> some View {
        Button { model.selectLens(lens) } label: {
            Text(lens.label).font(.system(size: 17, weight: .semibold))
                .frame(width: 52, height: 52)
                .background(model.selectedLens?.id == lens.id ? blue.opacity(0.65) : .black.opacity(0.4), in: Circle())

        }.buttonStyle(.plain).disabled(!model.canSelectLens)
            .accessibilityLabel("\(lens.name) \(lens.label)").accessibilityIdentifier("lens_" + lens.deviceType)
    }

    @ViewBuilder private func actionRail(landscape: Bool) -> some View {
        if landscape {
            VStack(spacing: 8) {
                settingsButton
                Spacer(minLength: 0)
                recordButton
                Spacer(minLength: 0)
                railButton("素材", icon: "play.rectangle", id: "libraryButton", disabled: busy) { showingLibrary = true }
            }.padding(.vertical, 10)
        } else {
            HStack {
                railButton("素材", icon: "play.rectangle", id: "libraryButton", disabled: busy) { showingLibrary = true }
                Spacer()
                recordButton
                Spacer()
                settingsButton
            }.padding(.horizontal, 12)
        }
    }

    private func railButton(_ label: String, icon: String, id: String = "", selected: Bool = false, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 26, weight: .light))
                Text(label).font(.system(size: 10, weight: .medium))
            }.foregroundStyle(selected ? blue : .white).frame(width: 66, height: 54)
                .background(selected ? blue.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).disabled(disabled).accessibilityIdentifier(id).accessibilityLabel(label)
    }

    private var settingsButton: some View {
        Button { showingSettings = true } label: {
            Image(systemName: "gearshape").font(.system(size: 23)).frame(width: 44, height: 44)
                .background(.black.opacity(0.3), in: Circle())
        }.disabled(busy).accessibilityLabel("设置").accessibilityIdentifier("settingsButton")
    }

    private var recordButton: some View {
        Button {
            selectedControl = nil
            recording ? model.stop() : model.start()
        } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 2).frame(width: 70, height: 70)
                if recording { RoundedRectangle(cornerRadius: 5).fill(.red).frame(width: 29, height: 29) }
                else { Circle().fill(Color(red: 0.65, green: 0.025, blue: 0.025)).frame(width: 49, height: 49) }
            }
        }.buttonStyle(.plain).disabled(!model.canToggle).opacity(model.canToggle ? 1 : 0.45)
            .accessibilityLabel(recording ? "停止录制" : "开始录制").accessibilityValue(model.state.rawValue).accessibilityIdentifier("recordToggle")
    }
}

struct SettingsView: View {
    @ObservedObject var model: RecorderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var storageError: String?
    @State private var storageErrorTitle = "录制位置不可用"
    @State private var showCodecOptions = false
    @State private var showStorageOptions = false
    @State private var showingSSDFolderPicker = false
    @State private var showOutputOptions = false
    var body: some View {
        NavigationStack {
            Form {
                Section("录制") {
                    Button { showCodecOptions = true } label: {
                        LabeledContent("视频编码", value: model.selectedCodec.label)
                    }.disabled(!model.canSelectLens).accessibilityIdentifier("codecPicker")
                        .popover(isPresented: $showCodecOptions, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(model.codecOptions) { codec in
                                    dropdownRow(codec.label, selected: model.selectedCodec == codec) {
                                        if codec.isRAW && model.storageLocation != .ssd {
                                            storageErrorTitle = "请先选择 SSD"
                                            storageError = "请先将录制位置设为 SSD，再选择 ProRes RAW。"
                                        } else { model.codecMode = codec; showCodecOptions = false }
                                    }.disabled(!model.canSelectCodec(codec))
                                }
                            }.padding(8).frame(minWidth: 260)
                                .presentationCompactAdaptation(.popover)
                                .alert(storageErrorTitle, isPresented: Binding(
                                    get: { storageError != nil && showCodecOptions },
                                    set: { if !$0 { storageError = nil } })) {
                                        Button("好", role: .cancel) { storageError = nil }
                                    } message: { Text(storageError ?? "") }
                        }
                    if model.selectedCodec.isRAW {
                        LabeledContent("色彩空间", value: "传感器 RAW")
                        if model.storageLocation != .ssd {
                            Text("ProRes RAW / RAW HQ 需要将录制位置设为 SSD。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Text(model.externalStorageStatus)
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        LabeledContent("色彩空间", value: "SDR / Rec.709")
                    }
                    Toggle("录制音频", isOn: $model.audioEnabled)
                        .disabled(model.state == .recording || model.state == .finalizing || model.state == .configuring)
                    Button { showStorageOptions = true } label: {
                        LabeledContent("录制位置", value: model.storageLocation.label)
                    }.accessibilityIdentifier("storageLocationPicker")
                        .disabled(model.state == .recording || model.state == .finalizing || model.state == .configuring)
                        .popover(isPresented: $showStorageOptions, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 0) {
                                dropdownRow("文件", selected: model.storageLocation == .files) {
                                    model.useFilesStorage(); showStorageOptions = false
                                }
                                dropdownRow("SSD", selected: model.storageLocation == .ssd) {
                                    Task { @MainActor in
                                        do {
                                            let reused = try await model.useSSDStorage()
                                            showStorageOptions = false
                                            if !reused { showingSSDFolderPicker = true }
                                        }
                                        catch {
                                            storageErrorTitle = (error as? SSDStorageError)?.title ?? "录制位置不可用"
                                            storageError = error.localizedDescription
                                        }
                                    }
                                }
                            }.padding(8).frame(minWidth: 220).presentationCompactAdaptation(.popover)
                                .alert(storageErrorTitle, isPresented: Binding(
                                    get: { storageError != nil && showStorageOptions },
                                    set: { if !$0 { storageError = nil } })) {
                                        Button("好", role: .cancel) { storageError = nil }
                                    } message: { Text(storageError ?? "") }
                        }
                    Text(model.storageLocation == .files
                         ? "文件 App → 我的 iPhone → GyroCine；每段录制创建独立文件夹。"
                         : "SSD → DCIM → GyroCine_日期时间。首次授权请选择 SSD 根目录或 DCIM；不存在时自动创建。")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.storageLocation == .ssd {
                        Text(model.externalStorageStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Button { showOutputOptions = true } label: {
                        LabeledContent("保存格式", value: model.outputMode.label)
                    }.accessibilityIdentifier("outputModePicker")
                        .disabled(model.state == .recording || model.state == .finalizing || model.state == .configuring)
                        .popover(isPresented: $showOutputOptions, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(RecordingOutputMode.allCases) { mode in
                                    dropdownRow(mode.label, selected: model.outputMode == mode) {
                                        model.outputMode = mode; showOutputOptions = false
                                    }
                                }
                            }.padding(8).frame(minWidth: 330).presentationCompactAdaptation(.popover)
                        }
                    Text(model.outputMode.detail).font(.caption).foregroundStyle(.secondary)
                    Toggle("保留调试文件", isOn: $model.debugFilesEnabled)
                        .disabled(model.state == .recording || model.state == .finalizing || model.state == .configuring)
                    Text("默认关闭。MOV 内嵌模式成功后，录制文件夹只保留 GyroCine_日期时间.mov；失败时保留诊断数据。")
                        .font(.caption).foregroundStyle(.secondary)
                }.listRowBackground(RecorderTheme.surface)
            }.scrollContentBackground(.hidden).background(RecorderTheme.background)
                .fileImporter(isPresented: $showingSSDFolderPicker, allowedContentTypes: [.folder]) { result in
                    if case .success(let url) = result {
                        do { try model.chooseSSDFolder(url) }
                        catch {
                            storageErrorTitle = (error as? SSDStorageError)?.title ?? "录制位置不可用"
                            storageError = error.localizedDescription
                        }
                    } else if case .failure(let error) = result {
                        storageErrorTitle = "无法选择 SSD 文件夹"
                        storageError = error.localizedDescription
                    }
                }
                .alert(storageErrorTitle, isPresented: Binding(
                    get: { storageError != nil && !showStorageOptions && !showCodecOptions },
                    set: { if !$0 { storageError = nil } })) {
                        Button("好", role: .cancel) { storageError = nil }
                    } message: { Text(storageError ?? "") }
                .navigationTitle("录制设置").navigationBarTitleDisplayMode(.inline)
                .task {
                    while !Task.isCancelled {
                        model.refreshExternalStorage()
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private func dropdownRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 12)
                if selected { Image(systemName: "checkmark").foregroundStyle(RecorderTheme.accent) }
            }.padding(.horizontal, 14).frame(height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct RecordingShare: Identifiable {
    let id = UUID()
    let files: [URL]
}

private struct RecordingActivityView: UIViewControllerRepresentable {
    let files: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: files, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct RecordingLibraryView: View {
    @State private var sharing: RecordingShare?
    @State private var previewFolder: URL?
    @State private var notice: String?
    @State private var importing = false
    @ObservedObject var model: RecorderViewModel
    @Environment(\.dismiss) private var dismiss
    private func saveToPhotos(_ folder: URL) {
        guard !importing else { return }
        importing = true
        Task { @MainActor in
            defer { importing = false }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { notice = "请在系统设置中允许添加照片。"; return }
            let url = folder.recordingFile("mov")
            guard UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(url.path) else {
                notice = "系统图库不支持此视频格式，原文件已保留，可通过分享导出。"; return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
                notice = "已保存视频到图库，运动数据仍保留在录制文件夹中。"
            } catch { notice = "保存失败：" + error.localizedDescription }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if model.recordings.isEmpty {
                    ContentUnavailableView("暂无素材", systemImage: "video", description: Text("录制后将保存视频和运动数据。"))
                        .listRowBackground(Color.clear)
                }
                ForEach(model.recordings, id: \.path) { folder in
                    HStack(spacing: 12) {
                        Button { previewFolder = folder } label: { RecordingThumbnail(url: folder.recordingFile("mov")) }
                            .buttonStyle(.plain).accessibilityLabel("预览视频")
                        VStack(alignment: .leading, spacing: 5) {
                            Text(folder.lastPathComponent).font(.subheadline).lineLimit(1)
                            RecordingDetails(folder: folder)
                        }
                        Spacer()
                        Button { saveToPhotos(folder) } label: { Image(systemName: "square.and.arrow.down").frame(width: 44, height: 44) }
                            .buttonStyle(.borderless)
                            .disabled(importing).accessibilityLabel("保存到图库")
                            .accessibilityIdentifier("recordingActions_" + folder.lastPathComponent)
                        let files = [folder.recordingFile("mov"), folder.recordingFile("gcsv"),
                                     folder.appendingPathComponent("lens_profile.json"), folder.recordingFile("gyroflow")]
                        if files.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                            Button { sharing = RecordingShare(files: [folder]) } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("分享 Gyroflow 录制文件夹")
                        } else {
                            Button { sharing = RecordingShare(files: [folder]) } label: { Image(systemName: "square.and.arrow.up") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("分享录制文件夹")
                        }
                    }.padding(.vertical, 5).listRowBackground(RecorderTheme.surface)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("删除", role: .destructive) {
                                do { try FileManager.default.removeItem(at: folder); model.refreshRecordings() }
                                catch { notice = error.localizedDescription }
                            }
                        }
                }
                Text("文件 App → 我的 iPhone → GyroCine → 对应录制文件夹")
                    .font(.footnote).foregroundStyle(.secondary).listRowBackground(Color.clear)
            }.scrollContentBackground(.hidden).background(RecorderTheme.background)
                .sheet(item: $sharing) { RecordingActivityView(files: $0.files) }
                .fullScreenCover(isPresented: Binding(get: { previewFolder != nil }, set: { if !$0 { previewFolder = nil } })) {
                    if let folder = previewFolder { RecordingPlayer(url: folder.recordingFile("mov")) }
                }
                .alert("素材", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                    Button("好") { notice = nil }
                } message: { Text(notice ?? "") }
                .overlay { if importing { ProgressView("正在保存到图库…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
                .navigationTitle("素材").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

private struct RecordingThumbnail: View {
    let url: URL
    @State private var thumbnail: UIImage?
    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
            if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
            Image(systemName: "play.circle.fill").foregroundStyle(.white)
        }.frame(width: 76, height: 52).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
            .task(id: url) {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 240, height: 160)
                if let result = try? await generator.image(at: .zero) { thumbnail = UIImage(cgImage: result.image) }
            }
    }
}

private struct RecordingDetails: View {
    let folder: URL
    @State private var description = "读取视频信息…"
    @State private var raw = false
    var body: some View {
        HStack(spacing: 5) {
            if raw { Text("RAW").font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 2)
                .background(RecorderTheme.accent, in: RoundedRectangle(cornerRadius: 3)) }
            Text(description).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .task(id: folder) {
            let result = await Task.detached(priority: .utility) { () -> (String, Bool) in
                let asset = AVURLAsset(url: folder.recordingFile("mov"))
                guard let track = asset.tracks(withMediaType: .video).first,
                      let description = track.formatDescriptions.first else { return ("视频信息不可用", false) }
                let format = description as! CMFormatDescription
                let fourCC = CMFormatDescriptionGetMediaSubType(format)
                let code = String(bytes: (0..<4).map { UInt8(truncatingIfNeeded: fourCC >> (24 - $0 * 8)) }, encoding: .ascii) ?? "----"
                let name = ["aprn": "ProRes RAW", "aprh": "ProRes RAW HQ", "apcn": "ProRes 422", "apch": "ProRes 422 HQ", "hvc1": "HEVC", "hev1": "HEVC", "avc1": "H.264"][code] ?? code
                let nativeSize = track.naturalSize
                let matrix = track.preferredTransform
                let rotation = (Int((atan2(matrix.b, matrix.a) * 180 / .pi).rounded()) + 360) % 360
                let size = (rotation == 90 || rotation == 270)
                    ? CGSize(width: nativeSize.height, height: nativeSize.width) : nativeSize
                let fps = track.nominalFrameRate
                let profile: String
                if code == "aprn" || code == "aprh" { profile = "Sensor RAW" }
                else if let data = try? Data(contentsOf: folder.appendingPathComponent("diagnostics.json")),
                        let diagnostics = try? JSONDecoder().decode(RecordingDiagnostics.self, from: data),
                        let recorded = diagnostics.recordedColorSpace { profile = recorded }
                else {
                    let transfer = String(describing: CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction))
                    profile = transfer.contains("HLG") ? "HLG" : transfer.contains("AppleLog") ? "Apple Log" : "Rec.709 / 未标记"
                }
                return ("\(Int(size.width))×\(Int(size.height)) · \(String(format: "%.1f", fps)) fps · \(name) · \(profile)", code == "aprn" || code == "aprh")
            }.value
            description = result.0; raw = result.1
        }
    }
}

private struct RecordingPlayer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer
    @State private var error: String?
    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                NativeRecordingPlayer(player: player).frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea()
                if let error { Text(error).foregroundStyle(.white).padding() }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("closeVideoPreview") } }
            .task {
                player.play()
                while !Task.isCancelled {
                    if player.currentItem?.status == .failed { error = player.currentItem?.error?.localizedDescription ?? "无法播放此视频"; break }
                    try? await Task.sleep(for: .seconds(1))
                }
            }.onDisappear { player.pause() }
        }
    }
}

private struct NativeRecordingPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
