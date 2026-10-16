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
    @AppStorage("showCompositionGrid") private var showCompositionGrid = false
    @AppStorage("showHorizonLevel") private var showHorizonLevel = false
    @AppStorage("exposureType") private var exposureType = "speed"
    @State private var externalDevices: [AVExternalStorageDevice] = []
    @State private var message: String?
    @State private var offerProVideoStorageSettings = false

    private var locked: Bool { camera.recording || camera.preparingRecording || camera.finalizing }
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
        let wideRAW = compatibleFormats.filter {
            $0.width >= 3840 && Double($0.width) / Double($0.height) >= 1.65
        }
        let raw4K = wideRAW.max { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
        let isRAW = camera.selectedEncoding == .proResRAW || camera.selectedEncoding == .proResRAWHQ
        let choices: [(String, Int32, Int32)] =
            (openGate.map { [("Open Gate", $0.width, $0.height)] } ?? []) +
            (isRAW ? (raw4K.map { [("4K", $0.width, $0.height)] } ?? []) : [("4K", 3840, 2160)]) +
            [("1080p", 1920, 1440), ("1080p", 1920, 1080)]
        return choices.compactMap { title, width, height in
            let formats = compatibleFormats.filter { $0.width == width && $0.height == height }
            return formats.isEmpty ? nil : ResolutionOption(title: title, width: width, height: height, formats: formats)
        }
    }
    private var currentFormat: FormatInfo? { camera.formats.first { $0.index == camera.selectedFormatIndex } }
    private var currentResolution: String { currentFormat.map { "\($0.width)×\($0.height)" } ?? "—" }
    private var intrinsicFormatNotice: String? {
        guard let current = currentFormat else { return nil }
        if !current.supportsIntrinsics {
            return t("当前格式不提供真实相机内参 K；可录制视频和声音，但无法嵌入 Gyroflow IMU。素材会标记 !IMU。",
                     "This format does not provide measured camera K. Video and audio can be recorded, but Gyroflow IMU cannot be embedded; the clip will be marked !IMU.")
        }
        let widest = compatibleFormats.filter {
            $0.width == current.width && $0.height == current.height && $0.supports(camera.fps)
        }.map { Double($0.format.videoFieldOfView) }.max() ?? Double(current.format.videoFieldOfView)
        if widest - Double(current.format.videoFieldOfView) > 5 {
            return t("当前格式采用裁切视角以记录真实 K（视角约 \(Int(current.format.videoFieldOfView.rounded()))°）。",
                     "This format uses a cropped view to record measured K (about \(Int(current.format.videoFieldOfView.rounded()))°).")
        }
        return nil
    }
    private func t(_ chinese: String, _ english: String) -> String {
        AppText.value(chinese, english, locale: locale)
    }

    var body: some View {
        NavigationStack {
            Form {
                videoSection
                storageSection
                recordingSection
                viewfinderSection
                advancedSection
            }
            .navigationTitle(t("设置", "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(t("完成", "Done")) { dismiss() } } }
            .alert(t("设置", "Settings"), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                if offerProVideoStorageSettings {
                    Button(t("打开专用存储设置", "Open Pro Video Storage Settings")) {
                        message = nil
                        offerProVideoStorageSettings = false
                        ProVideoStorageBridge.openSettings()
                    }
                }
                Button(t("确定", "OK")) { message = nil; offerProVideoStorageSettings = false }
            } message: { Text(message ?? "") }
            .onAppear {
                refreshExternalDevices()
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
                .accessibilityIdentifier("codecMenu")
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
                .accessibilityIdentifier("resolutionMenu")
            Menu {
                ForEach(camera.availableFPS, id: \.self) { rate in
                    Button {
                        camera.chooseFPS(rate)
                    } label: {
                        if abs(camera.fps - rate) < 0.001 { Label(fpsLabel(rate), systemImage: "checkmark") }
                        else { Text(fpsLabel(rate)) }
                    }.accessibilityIdentifier("fpsOption.\(fpsLabel(rate))")
                }
            } label: { row(t("帧率", "Frame rate"), fpsLabel(camera.fps)) }
                .tint(.primary).disabled(locked || camera.availableFPS.isEmpty)
                .accessibilityIdentifier("fpsMenu")
            Menu {
                Button(t("快门速度", "Shutter speed")) { chooseExposureType("speed") }
                    .accessibilityIdentifier("exposureType.speed")
                Button(t("快门角度", "Shutter angle")) { chooseExposureType("angle") }
                    .accessibilityIdentifier("exposureType.angle")
            } label: {
                row(t("曝光类型", "Exposure type"), exposureType == "angle" ?
                    t("快门角度", "Shutter angle") : t("快门速度", "Shutter speed"))
            }
            .tint(.primary).disabled(locked)
            .accessibilityIdentifier("exposureTypeMenu")
            if let intrinsicFormatNotice {
                Text(intrinsicFormatNotice).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
    private func chooseExposureType(_ type: String) {
        guard exposureType != type else { return }
        exposureType = type
        camera.activateExposureAutoMax(resetToDefault: true)
    }
    private var storageSection: some View {
        Section {
                    Menu {
                        Button(t("内部文件", "On My iPhone")) {
                            offerProVideoStorageSettings = false
                            storageLocation = "内部文件"
                        }
                        Button(t("专用视频存储", "Pro Video Storage")) {
                            selectProVideoStorage()
                        }
                        Button(t("外部 SSD", "External SSD")) {
                            selectExternalStorage()
                        }
                    } label: {
                        row(t("存储位置", "Storage"), storageLocation == "内部文件" ? t("内部文件", "On My iPhone") :
                            storageLocation == "专用视频存储" ? t("专用视频存储", "Pro Video Storage") : storageLocation)
                    }.tint(.primary)
                    .disabled(locked)
                    if storageLocation == "外部 SSD" {
                        Menu {
                            ForEach(externalDevices, id: \.uuid) { device in
                                Button(device.displayName ?? t("外部存储", "External storage")) {
                                    if let id = device.uuid?.uuidString {
                                        UserDefaults.standard.set(id, forKey: "externalDeviceID")
                                        camera.refreshExternalStorage()
                                    }
                                }
                            }
                            Button(t("重新检测", "Refresh")) { refreshExternalDevices() }
                        } label: {
                            row(t("目标 SSD", "Destination SSD"), selectedExternalName)
                        }
                            .disabled(locked)
                    }
                    Menu {
                        Button("Sony MOV") { outputFormat = "SonyMov" }
                        Button("Gyroflow Proto MOV") { outputFormat = "GyroflowProto" }
                    } label: { row(t("存储格式", "Output format"), outputFormat == "SonyMov" ? "Sony MOV" : "Gyroflow Proto MOV") }.tint(.primary)
                    .accessibilityIdentifier("outputFormatMenu")
                    .disabled(locked)
        } header: { Text(t("存储", "STORAGE")) } footer: {
                    Text(t("本机与专用存储的视频均保存在 GyroCine/Media，诊断数据保存在 GyroCine/Log；SSD 视频由系统写入 DCIM/100APPLE。",
                           "Local and Pro Video Storage videos are in GyroCine/Media, diagnostics in GyroCine/Log; SSD videos are in DCIM/100APPLE."))
        }
    }
    private var selectedExternalName: String {
        let id = UserDefaults.standard.string(forKey: "externalDeviceID")
        return externalDevices.first(where: { $0.uuid?.uuidString == id })?.displayName
            ?? t("未连接", "Not connected")
    }
    private func refreshExternalDevices() {
        externalDevices = AVExternalStorageDeviceDiscoverySession.shared?.externalStorageDevices.filter(\.isConnected) ?? []
    }
    private func selectProVideoStorage() {
        offerProVideoStorageSettings = false
        guard ProVideoStorageBridge.isSupported() else {
            message = t("此设备或 iOS 版本不支持专用视频存储。请使用外部 SSD。",
                        "This device or iOS version does not support Pro Video Storage. Use an external SSD.")
            return
        }
        storageLocation = "专用视频存储"
        if ProVideoStorageBridge.remainingCapacity() <= 0 {
            offerProVideoStorageSettings = true
            message = t("请在系统设置中分配专用视频存储空间后再录制。",
                        "Allocate Pro Video Storage in Settings before recording.")
        }
    }
    private func selectExternalStorage() {
        offerProVideoStorageSettings = false
        refreshExternalDevices()
        guard !externalDevices.isEmpty else {
            message = t("未检测到外部 SSD。请连接 SSD 后重试。", "No external SSD detected. Connect it and retry.")
            return
        }
        let activate = {
            storageLocation = "外部 SSD"
            if !externalDevices.contains(where: { $0.uuid?.uuidString == UserDefaults.standard.string(forKey: "externalDeviceID") }),
               let id = externalDevices.first?.uuid?.uuidString {
                UserDefaults.standard.set(id, forKey: "externalDeviceID")
            }
            camera.refreshExternalStorage()
        }
        switch AVExternalStorageDevice.authorizationStatus {
        case .authorized: activate()
        case .notDetermined:
            AVExternalStorageDevice.requestAccess { granted in
                DispatchQueue.main.async {
                    if granted { activate() }
                    else { message = t("需要外部存储授权。请在系统设置中允许访问。", "Allow external storage access in Settings.") }
                }
            }
        default: message = t("需要外部存储授权。请在系统设置中允许访问。", "Allow external storage access in Settings.")
        }
    }
    private var recordingSection: some View {
        Section(t("录制", "RECORDING")) {
                    lockedRow(t("记录 IMU", "Record IMU"), t("始终开启", "Always on"))
                    lockedRow(t("录制声音", "Record audio"), camera.audioAvailable ? t("始终开启", "Always on") : t("无权限", "No permission"))
        }
    }
    private var viewfinderSection: some View {
        Section(t("取景辅助", "VIEWFINDER")) {
            Toggle(t("九宫格辅助线", "Rule of thirds grid"), isOn: $showCompositionGrid)
                .accessibilityIdentifier("gridToggle")
            Toggle(t("水平辅助线", "Horizon level"), isOn: $showHorizonLevel)
                .accessibilityIdentifier("levelToggle")
        }
    }
    private var advancedSection: some View {
        Section {
                    Toggle(t("调试", "Debug"), isOn: $debugEnabled)
        } header: { Text(t("高级", "ADVANCED")) } footer: {
            Text(t("开启时保留原始 IMU 记录；封装失败时始终保留原始文件。",
                   "Retain raw IMU when enabled. Failed embeds always retain raw files."))
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.primary)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
        }.contentShape(Rectangle())
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
