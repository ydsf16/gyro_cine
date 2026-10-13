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
        let groups = Dictionary(grouping: compatibleFormats) { "\($0.width)×\($0.height)" }
        return groups.compactMap { key, formats in
            guard let first = formats.first else { return nil }
            return ResolutionOption(id: key, width: first.width, height: first.height, formats: formats)
        }.sorted { Int64($0.width) * Int64($0.height) > Int64($1.width) * Int64($1.height) }
    }
    private var currentFormat: FormatInfo? { camera.formats.first { $0.index == camera.selectedFormatIndex } }

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
                    NavigationLink {
                        optionList(codecOptions, selection: camera.selectedCodec) { codec in
                            camera.chooseCodec(codec)
                        } title: { codecName($0) }
                        .navigationTitle("视频编码")
                    } label: { row("视频编码", codecName(camera.selectedCodec)) }
                    .disabled(locked)
                    NavigationLink {
                        List {
                            ForEach(resolutions) { resolution in
                                Button {
                                    let preferred = resolution.formats.first { $0.index == camera.selectedFormatIndex }
                                        ?? resolution.formats.first { $0.supports(camera.fps) }
                                        ?? resolution.formats.first
                                    if let preferred { camera.chooseFormat(preferred.index) }
                                } label: {
                                    HStack {
                                        Text(resolution.label)
                                        Spacer()
                                        if resolution.id == currentFormat.map({ "\($0.width)×\($0.height)" }) {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                        .navigationTitle("分辨率")
                    } label: { row("分辨率", currentFormat.map { "\($0.width)×\($0.height)" } ?? "—") }
                    .disabled(locked)
                    NavigationLink {
                        optionList(camera.availableFPS, selection: camera.fps) { camera.chooseFPS($0) } title: { fpsLabel($0) }
                            .navigationTitle("帧率")
                    } label: { row("帧率", fpsLabel(camera.fps)) }
                    .disabled(locked)
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
        value.rounded() == value ? "\(Int(value)) fps" : String(format: "%.3f fps", value)
    }
    private func optionList<T: Hashable>(_ values: [T], selection: T?, action: @escaping (T) -> Void, title: @escaping (T) -> String) -> some View {
        List {
            ForEach(values, id: \.self) { value in
                Button { action(value) } label: {
                    HStack { Text(title(value)); Spacer(); if selection == value { Image(systemName: "checkmark") } }
                }
            }
        }
    }
}

private struct ResolutionOption: Identifiable {
    let id: String
    let width: Int32
    let height: Int32
    let formats: [FormatInfo]
    var label: String {
        let category: String
        if width >= 4000 && Double(height) / Double(width) > 0.65 { category = "Open Gate" }
        else if width >= 3800 { category = "4K" }
        else if width >= 1900 { category = "1080p" }
        else if width >= 1200 { category = "720p" }
        else { category = "视频" }
        return "\(category) · \(width)×\(height)"
    }
}
