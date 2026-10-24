import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var quickCapture = false
    @EnvironmentObject private var camera: CameraManager
    @ObservedObject private var proStore = ProStore.shared
    @ObservedObject private var recordingLocation = RecordingLocation.shared
    @AppStorage("recordLocation") private var recordLocation = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @AppStorage("storageLocation") private var storageLocation = "内部文件"
    @AppStorage("filenameType") private var filenameType = "BMC"
    @AppStorage("outputFormat") private var outputFormat = "SonyMov"
    @AppStorage("showCompositionGrid") private var showCompositionGrid = false
    @AppStorage("showHorizonLevel") private var showHorizonLevel = false
    @AppStorage("rulerHaptics") private var rulerHaptics = true
    @AppStorage("exposureType") private var exposureType = "speed"
    @State private var externalDevices: [AVExternalStorageDevice] = []
    @State private var showingSSDSpeed = false
    @State private var showingSSDNamingFolderPicker = false
    @State private var ssdNamingFolderName = UserDefaults.standard.string(forKey: "ssdNamingFolderName")
    @State private var showingPro = false
    @State private var message: String?
    @State private var pendingLensID: String?
    @State private var offerProVideoStorageSettings = false

    private var locked: Bool { camera.ssdSpeedTesting || camera.recording || camera.preparingRecording || camera.finalizing || camera.switchingLens || pendingLensID != nil }
    private var codecOptions: [VideoEncoding] {
        VideoEncoding.allCases.filter { camera.codecs.contains($0.codec) }
    }
    private var compatibleFormats: [FormatInfo] {
        camera.formats.filter {
            $0.compatibleCodecs.contains(camera.selectedCodec?.rawValue ?? "") &&
            !CaptureFrameRatePolicy.available(for: $0).isEmpty
        }
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
                if quickCapture {
                    Section(t("镜头", "Lens")) {
                        HStack {
                            ForEach(camera.lenses) { lens in
                                Button {
                                    guard !locked, lens.id != camera.selectedLensID else { return }
                                    pendingLensID = lens.id
                                    camera.chooseLens(lens.id) { pendingLensID = nil }
                                } label: {
                                    Text(lens.label).frame(maxWidth: .infinity).padding(.vertical, 8)
                                        .background(camera.selectedLensID == lens.id ? Color.blue : Color.secondary.opacity(0.12), in: Capsule())
                                        .foregroundStyle(camera.selectedLensID == lens.id ? .white : .primary)
                                }
                                .buttonStyle(.plain).disabled(locked)
                                .accessibilityIdentifier("quickLens.\(lens.label)")
                                .accessibilityValue(camera.selectedLensID == lens.id ? "selected" : "")
                            }
                        }
                        if camera.switchingLens || pendingLensID != nil {
                            ProgressView(t("切换中…", "Switching…"))
                        } else {
                            Text(t("选择即生效", "Changes apply immediately")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                videoSection
                if !quickCapture {
                    #if !TESTFLIGHT_FREE
                    Section {
                        Button { showingPro = true } label: {
                            HStack {
                                Label("GyroCine Pro", systemImage: "camera.aperture")
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                        }.tint(.primary).accessibilityIdentifier("proSettings")
                        Text(proStore.testFlightBypass
                             ? t("TestFlight 测试版：ProRes 长录制已开放。", "TestFlight: longer ProRes recordings enabled.")
                             : proStore.purchased
                             ? t("Pro 已解锁：ProRes 长录制已开放。", "Pro unlocked: longer ProRes recordings enabled.")
                             : t("ProRes / ProRes RAW 每段免费录制 2 分钟；Pro 一次性解锁长录制。其他功能免费。",
                                 "ProRes / ProRes RAW: 2 minutes free per clip. Pro unlocks longer recordings with a one-time purchase. All other features are free."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    #endif
                    storageSection
                    recordingSection
                    Section {
                        Toggle(t("烧录 LUT", "Burn LUT into video"), isOn: Binding(
                            get: { camera.lutBurnEnabled && !camera.selectedEncoding.isRAW },
                            set: camera.setLUTBurnEnabled))
                            .disabled(camera.selectedEncoding.isRAW || camera.lutControlsLocked)
                            .accessibilityIdentifier("settings.lutBurn")
                        NavigationLink(t("LUT 管理", "LUT Management")) { LUTManagementView() }
                            .accessibilityIdentifier("settings.lutManagement")
                    }.disabled(locked)
                    viewfinderSection
                    advancedSection
                    Section {
                        Link(t("帮助与支持", "Help & Support"), destination: URL(string: "https://tinygrapelab.com/gyro_cine/")!)
                        Link(t("问题反馈", "Send Feedback"), destination: URL(string: "https://my.feishu.cn/share/base/form/shrcnMISOxXt3zudB5W3uaFd5Zb")!)
                            .accessibilityIdentifier("settings.feedback")
                        Link(t("隐私政策", "Privacy Policy"), destination: URL(string: "https://tinygrapelab.com/gyro_cine/privacy.html")!)
                        Link("TinyGrapeLab", destination: URL(string: "https://tinygrapelab.com/")!)
                            .accessibilityIdentifier("settings.tinyGrapeLabWebsite")
                    }.tint(.primary)
                    Section {
                        VStack(spacing: 4) {
                            Text("GyroCine").font(.footnote.weight(.semibold))
                            Text(appVersion).font(.caption)
                            #if TESTFLIGHT_FREE
                            Text(t("TestFlight 测试版 · ProRes 长录制开放", "TestFlight build · longer ProRes recordings enabled"))
                                .font(.caption2)
                            #endif
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("appVersion")
                    }
                }
            }
            .navigationTitle(quickCapture ? t("拍摄配置", "Capture setup") : t("设置", "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(quickCapture ? t("关闭", "Close") : t("完成", "Done")) { dismiss() }.accessibilityIdentifier("captureSettingsClose") } }
            .alert(t("设置", "Settings"), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                if offerProVideoStorageSettings {
                    Button(t("打开专用存储设置", "Open Pro Video Storage Settings")) {
                        message = nil
                        offerProVideoStorageSettings = false
                        ProVideoStorageBridge.openSettings()
                    }
                }
                Button(t("确定", "OK")) { message = nil; offerProVideoStorageSettings = false }
            } message: { Text(AppText.message(message ?? "")) }
            .sheet(isPresented: $showingSSDSpeed) { SSDSpeedTestView() }
            .fileImporter(isPresented: $showingSSDNamingFolderPicker, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let folder):
                    do {
                        try camera.authorizeSSDNamingFolder(folder)
                        ssdNamingFolderName = folder.lastPathComponent
                    } catch { message = error.localizedDescription }
                case .failure(let error): message = error.localizedDescription
                }
            }
            .sheet(isPresented: $showingPro) { ProAccessView() }
            .onAppear {
                refreshExternalDevices()
                if outputFormat == "Sony MOV" { outputFormat = "SonyMov" }
                if outputFormat == "Gyroflow Project" { outputFormat = "GyroflowProto" }
            }
        }
    }

    private var videoSection: some View {
        Section(t("视频", "VIDEO")) {
            SettingsChoices(title: t("视频编码", "Codec")) {
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
            SettingsChoices(title: t("分辨率", "Resolution")) {
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
            SettingsChoices(title: t("帧率", "Frame rate")) {
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
            if let format = currentFormat {
                SettingsChoices(title: t("色彩空间", "Color space")) {
                    ForEach(RecordingColorSpace.selectableCases(for: camera.selectedEncoding).filter {
                        color in compatibleFormats.contains {
                            $0.width == format.width && $0.height == format.height && $0.supports(camera.fps) &&
                            color.isAvailable(for: $0.format, encoding: camera.selectedEncoding)
                        }
                    }) { colorSpace in
                        Button {
                            camera.chooseRecordingColorSpace(colorSpace)
                        } label: {
                            if camera.selectedRecordingColorSpace == colorSpace {
                                Label(colorSpace.title(locale: locale), systemImage: "checkmark")
                            } else {
                                Text(colorSpace.title(locale: locale))
                            }
                        }
                        .accessibilityIdentifier("colorSpaceOption.\(colorSpace.rawValue)")
                    }
                } label: {
                    row(t("色彩空间", "Color space"), camera.selectedRecordingColorSpace.title(locale: locale))
                }
                .tint(.primary).disabled(locked)
                .accessibilityIdentifier("colorSpaceMenu")
            }
            if camera.selectedEncoding == .hevc {
                SettingsChoices(title: t("码率档位", "Bitrate")) {
                    ForEach(HEVCBitratePreset.allCases) { preset in
                        Button {
                            camera.setHEVCBitratePreset(preset)
                        } label: {
                            if camera.hevcBitratePreset == preset {
                                Label(bitrateLabel(preset), systemImage: "checkmark")
                            } else {
                                Text(bitrateLabel(preset))
                            }
                        }
                        .accessibilityIdentifier("hevcBitrateOption.\(preset.rawValue)")
                    }
                } label: { row(t("码率档位", "Bitrate"), bitrateLabel(camera.hevcBitratePreset)) }
                    .tint(.primary).disabled(locked || currentFormat == nil)
                    .accessibilityIdentifier("hevcBitrateMenu")
            }
            SettingsChoices(title: t("曝光类型", "Exposure type")) {
                Button(t("速度", "Speed")) { chooseExposureType("speed") }
                    .accessibilityIdentifier("exposureType.speed")
                Button(t("角度", "Angle")) { chooseExposureType("angle") }
                    .accessibilityIdentifier("exposureType.angle")
            } label: {
                row(t("曝光类型", "Exposure type"), exposureType == "angle" ?
                    t("角度", "Angle") : t("速度", "Speed"))
            }
            .tint(.primary).disabled(locked)
            .accessibilityIdentifier("exposureTypeMenu")
            if let intrinsicFormatNotice {
                Text(intrinsicFormatNotice).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func bitrateLabel(_ preset: HEVCBitratePreset) -> String {
        let name = preset.title(locale: locale)
        guard let format = currentFormat,
              let bits = preset.targetBitsPerSecond(width: format.width, height: format.height, fps: camera.fps) else {
            return name
        }
        return "\(name) · ≈\(Int((Double(bits) / 1_000_000).rounded())) Mb/s"
    }
    private func chooseExposureType(_ type: String) {
        guard exposureType != type else { return }
        exposureType = type
        camera.activateExposureAutoMax(resetToDefault: true)
    }
    private var storageSection: some View {
        Section {
                    SettingsChoices(title: t("存储位置", "Storage")) {
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
                            storageLocation == "专用视频存储" ? t("专用视频存储", "Pro Video Storage") :
                            storageLocation == "外部 SSD" ? t("外部 SSD", "External SSD") : storageLocation)
                    }.tint(.primary)
                    .accessibilityIdentifier("storageLocationMenu")
                    .disabled(locked)
                    if storageLocation == "专用视频存储" {
                        Button { camera.requestStorageReplenishment() } label: {
                            Label(t("回收可用空间", "Reclaim available space"), systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }.disabled(locked).accessibilityIdentifier("reclaimStorage")
                        Button {
                            guard ProVideoStorageBridge.isSupported() else {
                                message = t("此设备或系统不支持专用视频存储。", "Pro Video Storage is unavailable on this device.")
                                return
                            }
                            ProVideoStorageBridge.openSettings()
                        } label: {
                            HStack {
                                Label(t("管理专用视频存储", "Manage Pro Video Storage"), systemImage: "internaldrive")
                                Spacer()
                                Image(systemName: "arrow.up.forward.app")
                            }
                        }
                        .accessibilityIdentifier("proVideoStorageSettings")
                        .disabled(locked)
                        Text(t("进入系统设置后，点“配置专业视频储存空间”调整容量。",
                               "In Settings, tap Configure Pro Video Storage to adjust capacity."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if storageLocation == "外部 SSD" {
                        SettingsChoices(title: t("目标 SSD", "Destination SSD")) {
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
                        Button { showingSSDSpeed = true } label: {
                            HStack {
                                Label(t("SSD 测速", "SSD speed test"), systemImage: "speedometer")
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.tint(.primary).disabled(locked).accessibilityIdentifier("ssdSpeedTest")
                        if filenameType == "BMC" {
                            Button { showingSSDNamingFolderPicker = true } label: {
                                HStack {
                                    Label(t("授权 SSD 文件夹改名", "Allow SSD folder renaming"), systemImage: "folder.badge.plus")
                                    Spacer()
                                    if let ssdNamingFolderName { Text(ssdNamingFolderName).foregroundStyle(.secondary) }
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }
                            .disabled(locked)
                            .accessibilityIdentifier("ssdNamingFolderPicker")
                            Text(t("请选择 SSD 的 DCIM 文件夹；授权后，BMC 文件名会在录像保存完成时生成。",
                                   "Select the SSD's DCIM folder. BMC naming runs after recording is saved."))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    SettingsChoices(title: t("文件名类型", "Filename type")) {
                        Button(t("简洁", "Simple")) { filenameType = "simple" }
                        Button("BMC") { filenameType = "BMC" }
                    } label: { row(t("文件名类型", "Filename type"), filenameType == "BMC" ? "BMC" : t("简洁", "Simple")) }
                    .tint(.primary).disabled(locked).accessibilityIdentifier("filenameTypePicker")
                    SettingsChoices(title: t("存储格式", "Output format")) {
                        Button("Gyroflow") { outputFormat = "SonyMov" }
                        Button("GyroflowNightly") { outputFormat = "GyroflowProto" }
                    } label: { row(t("存储格式", "Output format"), outputFormat == "SonyMov" ? "Gyroflow" : "GyroflowNightly") }.tint(.primary)
                    .accessibilityIdentifier("outputFormatMenu")
                    .disabled(locked)
        } header: { Text(t("存储", "STORAGE")) }
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
                    Toggle(t("记录位置", "Record location"), isOn: $recordLocation)
                        .accessibilityIdentifier("recordLocationToggle")
                        .disabled(locked)
                        .onChange(of: recordLocation) { _, enabled in
                            recordingLocation.refresh(requestPermission: enabled)
                        }
                    if recordLocation {
                        if recordingLocation.status == .denied {
                            Link(t("定位未授权，前往系统设置", "Location access denied. Open Settings"),
                                 destination: URL(string: UIApplication.openSettingsURLString)!)
                        } else {
                            Text(recordingLocation.status == .ready
                                 ? t("拍摄地点会随视频一起分享。", "The recording location will be shared with the video.")
                                 : t("正在获取位置；未获取到时视频不含位置。", "Acquiring location; videos omit location until available."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
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
                    Toggle(t("震动反馈", "Haptic feedback"), isOn: $rulerHaptics)
                        .accessibilityIdentifier("rulerHapticsToggle")
                        .onChange(of: rulerHaptics) { _, enabled in camera.setRulerHaptics(enabled) }
        } header: { Text(t("高级", "ADVANCED")) }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(t("版本", "Version")) \(version) (\(build))"
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.primary)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
        }.frame(minHeight: 44).contentShape(Rectangle())
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


/// Native menus keep selection on this page; the whole row is the hit target.
private struct SettingsChoices<Options: View, Row: View>: View {
    let title: String
    @ViewBuilder var options: () -> Options
    @ViewBuilder var label: () -> Row
    var body: some View {
        Menu { options() } label: {
            HStack(spacing: 10) {
                label()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuOrder(.fixed)
    }
}


struct LUTManagementView: View {
    @EnvironmentObject private var camera: CameraManager
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var deleting: ImportedPreviewLUT?
    private func t(_ zh: String, _ en: String) -> String { AppText.value(zh, en, locale: locale) }
    var body: some View {
        Form {
            Section {
                Button { importing = true } label: {
                    Label(t("导入 LUT", "Import LUT"), systemImage: "square.and.arrow.down")
                }.accessibilityIdentifier("lut.import").disabled(camera.importingLUT)
            }
            Section(t("内置 LUT", "Built-in LUTs")) {
                ForEach(PreviewLook.allCases) { look in
                    Toggle(look.title, isOn: Binding(
                        get: { !camera.disabledLUTIDs.contains(look.rawValue) },
                        set: { camera.setLUTVisible(look, enabled: $0) }))
                        .accessibilityIdentifier("lut.visible.builtin.\(look.rawValue)")
                }
            }
            Section(t("导入的 LUT", "Imported LUTs")) {
                ForEach(camera.importedLUTs) { item in
                    Toggle(item.name, isOn: Binding(
                        get: { !camera.disabledLUTIDs.contains(item.selectionID) },
                        set: { camera.setLUTVisible(item, enabled: $0) }))
                        .accessibilityIdentifier("lut.visible.\(item.name)")
                        .swipeActions { Button(role: .destructive) { deleting = item } label: { Label(t("删除", "Delete"), systemImage: "trash") } }
                }
            }
        }.disabled(camera.lutControlsLocked)
            .navigationTitle(t("LUT 管理", "LUT Management"))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(t("完成", "Done")) { dismiss() }.accessibilityIdentifier("lut.managementDone") } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data]) { result in
                switch result {
                case .success(let url): camera.importPreviewLUT(url)
                case .failure(let error): camera.reportLUTImportError(error)
                }
            }
            .confirmationDialog(t("删除 LUT？", "Delete LUT?"), isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button(t("删除", "Delete"), role: .destructive) {
                    if let item = deleting { camera.deleteImportedLUT(item) }; deleting = nil
                }
            }
    }
}
