import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var camera: CameraManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("storageLocation") private var storageLocation = "内部文件"
    @AppStorage("outputFormat") private var outputFormat = "Sony MOV"
    @AppStorage("debugEnabled") private var debugEnabled = false
    @State private var pickingFolder = false
    @State private var folderName = "未选择"
    @State private var message: String?

    private var locked: Bool { camera.recording || camera.finalizing }
    private var codecOptions: [AVVideoCodecType] {
        [AVVideoCodecType(rawValue: "hvc1"), AVVideoCodecType(rawValue: "aprn"), AVVideoCodecType(rawValue: "aprh")]
            .filter { camera.codecs.contains($0) }
    }
    private var compatibleFormats: [FormatInfo] {
        camera.formats.filter { $0.compatibleCodecs.contains(camera.selectedCodec?.rawValue ?? "") }
    }
    private var resolutions: [ResolutionOption] {
        ResolutionCategory.allCases.compactMap { category in
            let formats = compatibleFormats.filter { ResolutionCategory.of($0) == category }
            return formats.isEmpty ? nil : ResolutionOption(category: category, formats: formats)
        }
    }
    private var currentFormat: FormatInfo? { camera.formats.first { $0.index == camera.selectedFormatIndex } }
    private var selectedResolution: ResolutionCategory? { currentFormat.flatMap(ResolutionCategory.of) }
    private var resolutionValue: String {
        guard let currentFormat else { return "—" }
        let dimensions = "\(currentFormat.width)×\(currentFormat.height)"
        guard let selectedResolution else { return dimensions }
        return selectedResolution == .openGate ? "Open Gate · \(dimensions)" : selectedResolution.title
    }

    var body: some View {
        NavigationStack {
            Form {
                videoSection
                storageSection
                recordingSection
                advancedSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } } }
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    guard url.startAccessingSecurityScopedResource() else { message = "无法访问所选文件夹"; return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    do {
                        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                        UserDefaults.standard.set(bookmark, forKey: "externalFolderBookmark")
                        UserDefaults.standard.set(url.lastPathComponent, forKey: "externalFolderName")
                        folderName = url.lastPathComponent
                    } catch { message = "保存文件夹授权失败：\(error.localizedDescription)" }
                case .failure(let error): message = error.localizedDescription
                }
            }
            .alert("Settings", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("确定") { message = nil }
            } message: { Text(message ?? "") }
            .onAppear { folderName = UserDefaults.standard.string(forKey: "externalFolderName") ?? "未选择" }
        }
        .preferredColorScheme(.light)
    }

    private var videoSection: some View {
        Section("VIDEO") {
            Menu {
                ForEach(codecOptions, id: \.rawValue) { codec in
                    Button {
                        camera.chooseCodec(codec)
                    } label: {
                        if camera.selectedCodec == codec { Label(codecName(codec), systemImage: "checkmark") }
                        else { Text(codecName(codec)) }
                    }
                }
            } label: { row("视频编码", codecName(camera.selectedCodec)) }
                .tint(.primary).disabled(locked || codecOptions.isEmpty)
            Menu {
                ForEach(resolutions) { resolution in
                    Button {
                        if let format = resolution.preferredFormat(at: camera.fps) { camera.chooseFormat(format.index) }
                    } label: {
                        if selectedResolution == resolution.category { Label(resolution.label, systemImage: "checkmark") }
                        else { Text(resolution.label) }
                    }
                }
            } label: { row("分辨率", resolutionValue) }
                .tint(.primary).disabled(locked || resolutions.isEmpty)
            Menu {
                ForEach(camera.availableFPS.sorted(), id: \.self) { fps in
                    Button {
                        camera.chooseFPS(fps)
                    } label: {
                        if abs(camera.fps - fps) < 0.001 { Label(fpsLabel(fps), systemImage: "checkmark") }
                        else { Text(fpsLabel(fps)) }
                    }
                }
            } label: { row("帧率", fpsLabel(camera.fps)) }
                .tint(.primary).disabled(locked || camera.availableFPS.isEmpty)
        }
    }
    private var storageSection: some View {
        Section {
                    Menu {
                        Button("内部文件") { storageLocation = "内部文件" }
                        Button("外部 SSD · 待接入") { message = "外部 SSD 写入尚未接入录制核心。" }
                    } label: { row("存储位置", storageLocation) }.tint(.primary)
                    .disabled(locked)
                    if storageLocation == "外部 SSD" {
                        Button { pickingFolder = true } label: { row("目标文件夹", folderName) }
                            .disabled(locked)
                    }
                    Menu {
                        Button("Sony MOV") { outputFormat = "Sony MOV" }
                        Button("Gyroflow Project") { outputFormat = "Gyroflow Project" }
                    } label: { row("存储格式", outputFormat) }.tint(.primary)
                    .disabled(locked)
        } header: { Text("STORAGE") } footer: {
                    Text("当前重写版只保存测试 MOV。SSD、内嵌 IMU 和正式 Sony MOV / Gyroflow Project 输出尚未接入。")
        }
    }
    private var recordingSection: some View {
        Section("RECORDING") {
                    lockedRow("记录 IMU", "待接入")
                    lockedRow("录制声音", camera.audioAvailable ? "始终开启" : "无权限")
        }
    }
    private var advancedSection: some View {
        Section {
                    Toggle("Debug", isOn: $debugEnabled)
        } header: { Text("ADVANCED") } footer: {
            Text("诊断文件保留规则将在正式录制流程接入时生效。")
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
    private func codecName(_ codec: AVVideoCodecType?) -> String {
        switch codec?.rawValue {
        case "hvc1": "HEVC"
        case "aprn": "ProRes RAW"
        case "aprh": "ProRes RAW HQ"
        default: codec?.rawValue ?? "—"
        }
    }
    private func fpsLabel(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.001 { return "\(Int(value.rounded())) fps" }
        return String(format: value == 23.976 ? "%.3f fps" : "%.2f fps", value)
    }
}

private enum ResolutionCategory: String, CaseIterable, Identifiable {
    case fourK, fullHD, hd, openGate
    var id: Self { self }
    var title: String {
        switch self { case .fourK: "4K"; case .fullHD: "1080p"; case .hd: "720p"; case .openGate: "Open Gate" }
    }
    static func of(_ format: FormatInfo) -> Self? {
        let ratio = Double(format.width) / Double(format.height)
        if format.width >= 3000 && ratio < 1.65 { return .openGate }
        if format.width >= 3800 && ratio >= 1.65 { return .fourK }
        if format.width == 1920 && format.height == 1080 { return .fullHD }
        if format.width == 1280 && format.height == 720 { return .hd }
        return nil
    }
}

private struct ResolutionOption: Identifiable {
    let category: ResolutionCategory
    let formats: [FormatInfo]
    var id: ResolutionCategory { category }
    var label: String {
        guard category == .openGate, let largest = formats.max(by: { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }) else { return category.title }
        return "Open Gate · \(largest.width)×\(largest.height)"
    }
    func preferredFormat(at fps: Double) -> FormatInfo? {
        let supported = formats.filter { $0.supports(fps) }
        let candidates = supported.isEmpty ? formats : supported
        if category == .fourK {
            return candidates.min { first, second in
                let firstDistance = abs(Int(first.width) - 3840) + abs(Int(first.height) - 2160)
                let secondDistance = abs(Int(second.width) - 3840) + abs(Int(second.height) - 2160)
                return firstDistance < secondDistance
            }
        }
        return candidates.max { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
    }
}
