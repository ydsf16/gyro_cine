import AVFoundation
import SwiftUI

/// Immutable per-recording slate; metadata is set before either recorder starts.
struct RecordingSlate: Codable, Equatable {
    var production = ""
    var camera = "A"
    var director = ""
    var cinematographer = ""
    var reel = 1
    var scene = 1
    var take = 1
    var notes: String? = nil
    var autoTake = true
    var environment = ""
    var timeOfDay = ""

    static func load(_ defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "recordingSlate"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "recordingSlate") }
    }
    var cameraID: String {
        let letters = camera.uppercased().filter { $0.isASCII && $0.isLetter }
        return String(letters.prefix(3)).isEmpty ? "A" : String(letters.prefix(3))
    }
    func filename(date: Date, clip: Int, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMddHHmm"
        return String(format: "%@%03d_%@_C%03d.mov", cameraID, max(1, reel), formatter.string(from: date), max(1, clip))
    }
    func reserveURL(in directory: URL, date: Date = Date(), defaults: UserDefaults = .standard) -> URL {
        var clip = max(1, defaults.integer(forKey: "slate.nextClip"))
        var url = directory.appendingPathComponent(filename(date: date, clip: clip))
        while FileManager.default.fileExists(atPath: url.path) {
            clip += 1
            url = directory.appendingPathComponent(filename(date: date, clip: clip))
        }
        defaults.set(clip + 1, forKey: "slate.nextClip")
        return url
    }
    func advanceTake(_ defaults: UserDefaults = .standard) {
        // Never overwrite edits made since this recording's snapshot.
        guard autoTake, Self.load(defaults) == self else { return }
        var next = self
        next.take = min(take + 1, 999999)
        next.save(defaults)
    }
    var metadata: [AVMetadataItem] {
        let fields = ["com.apple.quicktime.title": production,
                      "com.apple.quicktime.director": director,
                      "com.apple.quicktime.description": notes ?? "",
                      "com.apple.quicktime.camera.identifier": cameraID,
                      "com.apple.quicktime.reel": String(reel),
                      "com.apple.quicktime.scene": String(scene),
                      "com.apple.quicktime.take": String(take),
                      "com.apple.proapps.cameraName": cameraID,
                      "com.apple.proapps.reel": String(reel),
                      "com.apple.proapps.scene": String(scene),
                      "com.apple.proapps.shot": String(take),
                      "com.apple.proapps.logNote": notes ?? "",
                      "com.tinygrape.gyrocine.cinematographer": cinematographer,
                      "com.tinygrape.gyrocine.environment": environment,
                      "com.tinygrape.gyrocine.timeOfDay": timeOfDay,
                      "com.tinygrape.gyrocine.slate": String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? ""]
        return fields.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }.map { key, value in
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = key as NSString
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
    }
}

struct RecordingSlateView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var camera: CameraManager
    @State private var slate = RecordingSlate.load()
    @AppStorage("filenameType") private var filenameType = "BMC"
    @AppStorage("storageLocation") private var storageLocation = "内部文件"
    private var locked: Bool { camera.recording || camera.preparingRecording || camera.finalizing }
    private func t(_ zh: String, _ en: String) -> String { Locale.preferredLanguages.first?.hasPrefix("zh") == true ? zh : en }
    var body: some View {
        NavigationStack {
            Form {
                Section(t("项目", "PROJECT")) {
                    field(t("制作名称", "Production"), text: $slate.production, id: "slateProduction")
                    field(t("机位编号", "Camera ID"), text: $slate.camera, id: "slateCamera").textInputAutocapitalization(.characters).autocorrectionDisabled()
                    field(t("导演", "Director"), text: $slate.director, id: "slateDirector")
                    field(t("摄影师", "Cinematographer"), text: $slate.cinematographer, id: "slateCinematographer")
                }
                Section(t("片段", "CLIP")) {
                    number(t("卷号", "Reel"), value: $slate.reel)
                    number(t("场景", "Scene"), value: $slate.scene)
                    number(t("镜次", "Take"), value: $slate.take)
                    Toggle(t("镜次自动递增", "Auto increment take"), isOn: $slate.autoTake)
                    Picker(t("拍摄环境", "Environment"), selection: $slate.environment) {
                        Text(t("未指定", "Unspecified")).tag("")
                        Text(t("棚内", "Interior")).tag("Interior")
                        Text(t("外景", "Exterior")).tag("Exterior")
                    }
                    Picker(t("拍摄时间", "Time of day"), selection: $slate.timeOfDay) {
                        Text(t("未指定", "Unspecified")).tag("")
                        Text(t("白天", "Day")).tag("Day")
                        Text(t("夜晚", "Night")).tag("Night")
                    }
                }
                Section(t("备注", "NOTES")) {
                    TextField(t("拍摄备注", "Recording notes"), text: Binding(get: { slate.notes ?? "" }, set: { slate.notes = $0 }), axis: .vertical)
                        .lineLimit(2...5).accessibilityIdentifier("slateNotes")
                }
                Section(t("下一条文件名", "NEXT FILENAME")) {
                    Text(filenameType == "BMC" && storageLocation != "外部 SSD"
                         ? slate.filename(date: Date(), clip: max(1, UserDefaults.standard.integer(forKey: "slate.nextClip")))
                         : "IMG_XXXX.mov")
                        .font(.footnote.monospaced()).textSelection(.enabled).accessibilityIdentifier("slateFilenamePreview")
                    if storageLocation == "外部 SSD" {
                        Text(t("SSD 素材由系统生成 IMG 文件名。", "The system assigns IMG filenames to SSD clips."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(t("日期、时间和片段号自动生成。场记信息保存在视频中。", "Date, time and clip number are generated automatically. Slate metadata is embedded in the movie."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(locked)
            .navigationTitle(t("场记", "Slate")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(t("完成", "Done")) { dismiss() }.accessibilityIdentifier("slateDone") } }
            .onChange(of: slate) { old, new in
                if old.scene != new.scene { slate.take = 1 }
                slate.reel = min(max(slate.reel, 1), 999999)
                slate.scene = min(max(slate.scene, 1), 999999)
                slate.take = min(max(slate.take, 1), 999999)
                slate.save()
            }
        }
    }
    private func field(_ title: String, text: Binding<String>, id: String) -> some View {
        LabeledContent(title) {
            TextField(t("未填写", "Optional"), text: text)
                .multilineTextAlignment(.trailing).accessibilityIdentifier(id)
        }
    }
    private func number(_ title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number.grouping(.never))
                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 65)
            Stepper(title, value: value, in: 1...999999).labelsHidden().fixedSize()
        }
    }
}


/// A start-of-recording snapshot, not a claim that automatic exposure stays constant.
enum RecordingMetadata {
    static let snapshotKey = "com.tinygrape.gyrocine.capture"

    static func items(_ fields: [String: String]) -> [AVMetadataItem] {
        fields.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }.map { key, value in
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = key as NSString
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
    }

    /// Keep system RAW metadata (including its color matrices) and replace only matching keys.
    static func merging(_ system: [AVMetadataItem], with custom: [AVMetadataItem]) -> [AVMetadataItem] {
        func identity(_ item: AVMetadataItem) -> String {
            "\(item.keySpace?.rawValue ?? "")/\(item.key as? String ?? item.identifier?.rawValue ?? "")"
        }
        let cameraKeys: Set<String> = ["com.apple.quicktime.make", "com.apple.quicktime.model"]
        let systemCameraKeys = Set(system.compactMap { $0.key as? String }).intersection(cameraKeys)
        let additions = custom.filter { !systemCameraKeys.contains($0.key as? String ?? "") }
        let replaced = Set(additions.map(identity))
        return system.filter { !replaced.contains(identity($0)) } + additions
    }

    static func capture(device: AVCaptureDevice, model: String, color: String, codec: String,
                        fps: Double, burnedLUT: Bool, clipName: String = "", date: Date = Date()) -> [AVMetadataItem] {
        let wb = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
        let duration = CMTimeGetSeconds(device.exposureDuration)
        let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let snapshot: [String: Any] = [
            "schema": 1, "scope": "recordingStart", "model": model,
            "lensName": device.localizedName, "lensType": device.deviceType.rawValue,
            "position": device.position == .front ? "front" : "back",
            "zoom": Double(device.videoZoomFactor), "aperture": Double(device.lensAperture),
            "iso": Double(device.iso), "exposureSeconds": duration.isFinite ? duration : 0,
            "whiteBalanceKelvin": Double(wb.temperature), "tint": Double(wb.tint),
            "colorSpace": color, "codec": codec, "fps": fps,
            "width": Int(size.width), "height": Int(size.height), "lutBurned": burnedLUT
        ]
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        var fields = ["com.apple.quicktime.make": "Apple", "com.apple.quicktime.model": model,
                      "com.apple.proapps.manufacturer": "Apple Inc.",
                      "com.apple.proapps.clipID": clipName,
                      "com.tinygrape.gyrocine.camera.lensType": device.localizedName,
                      "com.tinygrape.gyrocine.camera.iso": String(device.iso),
                      "com.tinygrape.gyrocine.camera.aperture": String(device.lensAperture),
                      "com.tinygrape.gyrocine.camera.shutterSeconds": duration.isFinite ? String(duration) : "",
                      "com.tinygrape.gyrocine.camera.whiteBalanceKelvin": String(wb.temperature),
                      "com.tinygrape.gyrocine.camera.whiteBalanceTint": String(wb.tint),
                      "com.tinygrape.gyrocine.sensorFPS": String(fps),
                      "com.tinygrape.gyrocine.colorSpace": color,
                      "com.apple.quicktime.software": "GyroCine \(version) (\(build))",
                      "com.apple.quicktime.creationdate": formatter.string(from: date)]
        if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { fields[snapshotKey] = text }
        return items(fields)
    }
}
