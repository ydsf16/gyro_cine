import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var camera: CameraManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @AppStorage("storageLocation") private var storageLocation = "内部文件"
    @AppStorage("outputFormat") private var outputFormat = "SonyMov"
    @AppStorage("debugEnabled") private var debugEnabled = false
    @State private var pickingFolder = false
    @State private var folderName = "未选择"
    @State private var message: String?

    private var locked: Bool { camera.recording || camera.finalizing }
    private var codecOptions: [VideoEncoding] {
        VideoEncoding.allCases.filter { camera.codecs.contains($0.codec) }
    }
    private var compatibleFormats: [FormatInfo] {
        camera.formats.filter { $0.compatibleCodecs.contains(camera.selectedCodec?.rawValue ?? "") }
    }
    private var resolutions: [ResolutionOption] {
        let openGate = compatibleFormats
            .filter { $0.width >= 3000 && Double($0.width) / Double($0.height) < 1.65 }
            .max { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
        let choices: [(String, Int32, Int32)] =
            (openGate.map { [("Open Gate", $0.width, $0.height)] } ?? []) +
            [("4K", 3840, 2160), ("1080p", 1920, 1440), ("1080p", 1920, 1080)]
        return choices.compactMap { title, width, height in
            let formats = compatibleFormats.filter { $0.width == width && $0.height == height }
            return formats.isEmpty ? nil : ResolutionOption(title: title, width: width, height: height, formats: formats)
        }
    }
    private var currentFormat: FormatInfo? { camera.formats.first { $0.index == camera.selectedFormatIndex } }
    private var currentResolution: String { currentFormat.map { "\($0.width)×\($0.height)" } ?? "—" }
    private func t(_ chinese: String, _ english: String) -> String {
        AppText.value(chinese, english, locale: locale)
    }

    var body: some View {
        NavigationStack {
            Form {
                videoSection
                storageSection
                recordingSection
                advancedSection
            }
            .navigationTitle(t("设置", "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(t("完成", "Done")) { dismiss() } } }
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    guard url.startAccessingSecurityScopedResource() else { message = t("无法访问所选文件夹", "Cannot access the selected folder"); return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    do {
                        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                        UserDefaults.standard.set(bookmark, forKey: "externalFolderBookmark")
                        UserDefaults.standard.set(url.lastPathComponent, forKey: "externalFolderName")
                        folderName = url.lastPathComponent
                    } catch { message = "\(t("保存文件夹授权失败", "Could not save folder access"))：\(error.localizedDescription)" }
                case .failure(let error): message = error.localizedDescription
                }
            }
            .alert(t("设置", "Settings"), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button(t("确定", "OK")) { message = nil }
            } message: { Text(message ?? "") }
            .onAppear {
                folderName = UserDefaults.standard.string(forKey: "externalFolderName") ?? t("未选择", "Not selected")
                if outputFormat == "Sony MOV" { outputFormat = "SonyMov" }
                if outputFormat == "Gyroflow Project" { outputFormat = "GyroflowProto" }
            }
        }
        .preferredColorScheme(.light)
    }

    private var videoSection: some View {
        Section(t("视频", "VIDEO")) {
            Menu {
                ForEach(codecOptions) { encoding in
                    Button {
                        camera.chooseEncoding(encoding)
                    } label: {
                        if camera.selectedEncoding == encoding { Label(encoding.title, systemImage: "checkmark") }
                        else { Text(encoding.title) }
                    }
                }
            } label: { row(t("视频编码", "Codec"), camera.selectedEncoding.title) }
                .tint(.primary).disabled(locked || codecOptions.isEmpty)
            Menu {
                ForEach(resolutions) { resolution in
                    Button {
                        let preferred = resolution.formats.first { $0.index == camera.selectedFormatIndex }
                            ?? resolution.formats.first { $0.supports(camera.fps) && $0.format.autoFocusSystem != .none }
                            ?? resolution.formats.first { $0.supports(camera.fps) }
                            ?? resolution.formats.first { $0.format.autoFocusSystem != .none }
                            ?? resolution.formats.first
                        if let preferred { camera.chooseFormat(preferred.index) }
                    } label: {
                        if resolution.id == currentResolution { Label(resolution.label, systemImage: "checkmark") }
                        else { Text(resolution.label) }
                    }
                }
            } label: { row(t("分辨率", "Resolution"), resolutions.first(where: { $0.id == currentResolution })?.label ?? currentResolution) }
                .tint(.primary).disabled(locked || resolutions.isEmpty)
            Menu {
                ForEach(camera.availableFPS, id: \.self) { rate in
                    Button {
                        camera.chooseFPS(rate)
                    } label: {
                        if abs(camera.fps - rate) < 0.001 { Label(fpsLabel(rate), systemImage: "checkmark") }
                        else { Text(fpsLabel(rate)) }
                    }
                }
            } label: { row(t("帧率", "Frame rate"), fpsLabel(camera.fps)) }
                .tint(.primary).disabled(locked || camera.availableFPS.isEmpty)
        }
    }
    private var storageSection: some View {
        Section {
                    Menu {
                        Button(t("内部文件", "On My iPhone")) { storageLocation = "内部文件" }
                        Button(t("外部 SSD · 待接入", "External SSD · Coming soon")) {
                            message = t("外部 SSD 写入尚未接入录制核心。", "External SSD recording is not connected yet.")
                        }
                    } label: { row(t("存储位置", "Storage"), storageLocation == "内部文件" ? t("内部文件", "On My iPhone") : storageLocation) }.tint(.primary)
                    .disabled(locked)
                    if storageLocation == "外部 SSD" {
                        Button { pickingFolder = true } label: { row(t("目标文件夹", "Destination folder"), folderName) }
                            .disabled(locked)
                    }
                    Menu {
                        Button("Sony MOV") { outputFormat = "SonyMov" }
                        Button(t("Gyroflow 项目", "Gyroflow Project")) { outputFormat = "GyroflowProto" }
                    } label: { row(t("存储格式", "Output format"), outputFormat == "SonyMov" ? "Sony MOV" : t("Gyroflow 项目", "Gyroflow Project")) }.tint(.primary)
                    .disabled(locked)
        } header: { Text(t("存储", "STORAGE")) } footer: {
                    Text(t("当前重写版只保存测试 MOV。SSD、内嵌 IMU、Sony MOV 和 Gyroflow 项目输出尚未接入。",
                           "This rebuild currently saves test MOV files. SSD, embedded IMU, Sony MOV and Gyroflow Project output are not connected yet."))
        }
    }
    private var recordingSection: some View {
        Section(t("录制", "RECORDING")) {
                    lockedRow(t("记录 IMU", "Record IMU"), t("待接入", "Coming soon"))
                    lockedRow(t("录制声音", "Record audio"), camera.audioAvailable ? t("始终开启", "Always on") : t("无权限", "No permission"))
        }
    }
    private var advancedSection: some View {
        Section {
                    Toggle(t("调试", "Debug"), isOn: $debugEnabled)
        } header: { Text(t("高级", "ADVANCED")) } footer: {
            Text(t("诊断文件保留规则将在正式录制流程接入时生效。",
                   "Diagnostic retention will take effect when the full recording flow is connected."))
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.primary)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
        }
    }
    private func lockedRow(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).foregroundStyle(.secondary)
            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func fpsLabel(_ value: Double) -> String {
        // Keep broadcast rates distinct from their neighbouring integer rates.
        return String(format: "%.1f fps", floor(value * 10) / 10)
    }
}

private struct ResolutionOption: Identifiable {
    let title: String
    let width: Int32
    let height: Int32
    let formats: [FormatInfo]
    var id: String { "\(width)×\(height)" }
    var label: String { "\(title) · \(width)×\(height)" }
}
