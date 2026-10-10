import SwiftUI
import AVFoundation

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.layerForPreview.session = session
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) { uiView.updatePortraitRotation() }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var layerForPreview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        layerForPreview.videoGravity = .resizeAspectFill
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        updatePortraitRotation()
    }
    func updatePortraitRotation() {
        // Rotate preview only. Recorded buffers and measured K stay in native coordinates.
        if let connection = layerForPreview.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct ContentView: View {
    @ObservedObject var model: RecorderViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false
    @State private var showingLibrary = false
    private var recording: Bool { model.state == .recording }
    private var busy: Bool { recording || model.state == .finalizing }

    var body: some View {
        ZStack {
            CameraPreview(session: model.previewSession).ignoresSafeArea()
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 170)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 300)
            }.ignoresSafeArea().allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack {
                    if recording {
                        HStack(spacing: 6) {
                            Circle().fill(.red).frame(width: 8, height: 8)
                            Text(String(format: "%02d:%02d", model.elapsedSeconds / 60, model.elapsedSeconds % 60))
                                .monospacedDigit().foregroundStyle(.red)
                        }.font(.headline)
                    } else {
                        Text("RawMotion").font(.headline).foregroundStyle(RecorderTheme.brandGradient)
                    }
                    Spacer()
                    Text("HEVC · 4K30").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).frame(height: 44)
                        .background(.black.opacity(0.35), in: Capsule())
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape").frame(width: 44, height: 44)
                            .background(.black.opacity(0.35), in: Circle())
                    }.disabled(busy).accessibilityLabel("设置").accessibilityIdentifier("settingsButton")
                }.padding(.leading, 22).padding(.trailing, 8)
                Spacer()
                VStack(spacing: 14) {
                    if let message = model.message {
                        Text(message).font(.caption).multilineTextAlignment(.center)
                            .padding(10).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if model.state == .failed { Button("重试相机") { model.retry() }.buttonStyle(.bordered) }
                    Text(model.state.rawValue.capitalized + " · " + model.thermalLabel)
                        .font(.caption).accessibilityIdentifier("recordingState")
                    Text("剩余 \(model.freeSpaceLabel) · IMU \(model.imuRateLabel)")
                        .font(.caption2).foregroundStyle(.white.opacity(0.8))
                    Text("1×").font(.subheadline.weight(.semibold)).foregroundStyle(.yellow)
                        .frame(width: 44, height: 44).background(.black.opacity(0.45), in: Circle())
                    Text(model.state == .finalizing ? "正在保存…" : "视频 + 原始 IMU")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.yellow)
                    HStack {
                        Button { showingLibrary = true } label: {
                            Image(systemName: "square.grid.2x2").font(.title2).frame(width: 54, height: 54)
                                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                        }.disabled(busy).accessibilityLabel("素材").accessibilityIdentifier("libraryButton")
                        Spacer()
                        Button { recording ? model.stop() : model.start() } label: {
                            ZStack {
                                Circle().strokeBorder(.white, lineWidth: 4).frame(width: 80, height: 80)
                                if recording {
                                    RoundedRectangle(cornerRadius: 8).fill(.red).frame(width: 34, height: 34)
                                } else { Circle().fill(.red).frame(width: 66, height: 66) }
                            }
                        }.disabled(!model.canToggle).opacity(model.canToggle ? 1 : 0.45)
                            .accessibilityLabel(recording ? "停止录制" : "开始录制")
                            .accessibilityIdentifier("recordToggle")
                        Spacer()
                        Color.clear.frame(width: 54, height: 54)
                    }.padding(.horizontal, 30)
                }.padding(.horizontal, 16).padding(.bottom, 20)
            }
        }.background(.black).foregroundStyle(.white)
            .sheet(isPresented: $showingSettings) { SettingsView(model: model) }
            .sheet(isPresented: $showingLibrary) { RecordingLibraryView(model: model) }
            .task { model.prepare() }
            .onChange(of: model.audioEnabled) { _, enabled in
                if !busy { model.coordinator.configure(audio: enabled) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active && recording { model.stop() }
            }
    }
}

struct SettingsView: View {
    @ObservedObject var model: RecorderViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("录制") {
                    LabeledContent("视频格式", value: "HEVC · 4K / 30 fps")
                    LabeledContent("镜头", value: "后置主摄 · 固定 1×")
                    Toggle("录制音频", isOn: $model.audioEnabled)
                        .disabled(model.state == .recording || model.state == .finalizing)
                    LabeledContent("原始 gyro + accel", value: "始终开启")
                    LabeledContent("Gyroflow 1.6.3", value: "MOV + GCSV + 镜头 + 工程")
                }.listRowBackground(RecorderTheme.surface)
                Section("设备能力") {
                    Text(model.capabilityLabel).font(.footnote)
                    LabeledContent("可用 4K30 格式", value: "\(model.modes.count)")
                    LabeledContent("温度状态", value: model.thermalLabel)
                    LabeledContent("剩余存储", value: model.freeSpaceLabel)
                }.listRowBackground(RecorderTheme.surface)
                Section {
                    Text("工程需离线同步，镜头畸变尚未校准。ProRes RAW 在 M1 验收后开放。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.listRowBackground(RecorderTheme.surface)
            }.scrollContentBackground(.hidden).background(RecorderTheme.background)
                .navigationTitle("录制设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct RecordingLibraryView: View {
    @ObservedObject var model: RecorderViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if model.recordings.isEmpty {
                    ContentUnavailableView("暂无素材", systemImage: "video", description: Text("录制后将保存视频和运动数据。"))
                        .listRowBackground(Color.clear)
                }
                ForEach(model.recordings, id: \.path) { folder in
                    HStack(spacing: 12) {
                        Image(systemName: "video.fill").foregroundStyle(RecorderTheme.accent)
                            .frame(width: 44, height: 44).background(RecorderTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(folder.lastPathComponent).font(.subheadline).lineLimit(1)
                            Text("MOV · GCSV · 镜头 · 工程").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        let files = ["clip.mov", "clip.gcsv", "lens_profile.json", "clip.gyroflow"]
                            .map { folder.appendingPathComponent($0) }
                        if files.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                            ShareLink(items: files) { Image(systemName: "square.and.arrow.up") }
                                .accessibilityLabel("导出 Gyroflow 四文件")
                        } else {
                            ShareLink(item: folder) { Image(systemName: "square.and.arrow.up") }
                                .accessibilityLabel("导出原始诊断文件夹")
                        }
                    }.padding(.vertical, 5).listRowBackground(RecorderTheme.surface)
                }
            }.scrollContentBackground(.hidden).background(RecorderTheme.background)
                .navigationTitle("素材").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
