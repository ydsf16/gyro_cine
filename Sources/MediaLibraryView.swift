import AVFoundation
import AVKit
import Photos
import SwiftUI

struct MediaLibraryView: View {
    @EnvironmentObject private var camera: CameraManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var files: [URL] = []
    @State private var scopedExternalFiles: [URL] = []
    @State private var showingInformation = false
    @State private var selected: URL?
    @State private var pendingDelete: [URL] = []
    @State private var selecting = false
    @State private var selection = Set<URL>()
    @State private var deleting = false
    @State private var message: String?

    private func t(_ chinese: String, _ english: String) -> String {
        AppText.value(chinese, english, locale: locale)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 22) {
                    ForEach(files, id: \.self) { url in
                        Button {
                            if selecting { toggle(url) } else { selected = url }
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                MovieThumbnail(url: url)
                                    .overlay(alignment: .topLeading) {
                                        if selecting {
                                            Image(systemName: selection.contains(url) ? "checkmark.circle.fill" : "circle")
                                                .font(.title2).foregroundStyle(selection.contains(url) ? .blue : .white)
                                                .background(.black.opacity(0.6), in: Circle()).padding(8)
                                        }
                                    }
                                Text(url.deletingPathExtension().lastPathComponent)
                                    .font(.subheadline).lineLimit(1)
                                Text(fileSize(url)).font(.caption).foregroundStyle(.secondary)
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("mediaRow.\(url.lastPathComponent)")
                        .highPriorityGesture(LongPressGesture(minimumDuration: 0.55).onEnded { _ in
                            selecting = true; selection.insert(url)
                        })
                    }
                }.padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .accessibilityIdentifier("mediaGrid")
            .overlay { if files.isEmpty { ContentUnavailableView(t("暂无素材", "No recordings"), systemImage: "film") } }
            .navigationTitle(t("素材", "Media"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selecting ? t("取消", "Cancel") : t("选择", "Select")) {
                        selecting.toggle(); selection.removeAll()
                    }.accessibilityIdentifier("mediaSelect")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if selecting {
                        Button(selection.count == files.count ? t("取消全选", "Deselect all") : t("全选", "Select all")) {
                            selection = selection.count == files.count ? [] : Set(files)
                        }.accessibilityIdentifier("mediaSelectAll")
                    } else { Button { dismiss() } label: { Text(t("完成", "Done")).frame(minWidth: 60, minHeight: 44).contentShape(Rectangle()) }.accessibilityIdentifier("mediaDone") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    VStack(spacing: 12) {
                        Text(t("已选 \(selection.count) 项", "\(selection.count) selected")).font(.subheadline)
                        HStack(spacing: 24) {
                            ShareLink(items: files.filter { selection.contains($0) }) {
                                mediaActionLabel(t("分享", "Share"), icon: "square.and.arrow.up")
                            }.accessibilityIdentifier("mediaShareSelected")
                            Button { saveToPhotos(files.filter { selection.contains($0) }) } label: {
                                mediaActionLabel(t("保存相册", "Save to Photos"), icon: "square.and.arrow.down")
                            }.accessibilityIdentifier("mediaSaveSelected")
                            Button(role: .destructive) { pendingDelete = files.filter { selection.contains($0) } } label: {
                                mediaActionLabel(t("删除", "Delete"), icon: "trash")
                            }.accessibilityIdentifier("mediaDeleteSelected")
                        }
                        .disabled(selection.isEmpty || deleting || camera.finalizing || camera.recording)
                    }.padding().background(.regularMaterial)
                }
            }
            .disabled(deleting)
            .sheet(item: $selected) { url in
                NavigationStack {
                    StableMoviePlayer(url: url)
                        .id(url)
                        .task {
                            #if DEBUG
                            if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--media-info-file=") }) {
                                try? await Task.sleep(for: .milliseconds(700))
                                showingInformation = true
                            }
                            #endif
                        }
                        .overlay(alignment: .topTrailing) { IMUBadge(url: url).padding(20).allowsHitTesting(false) }
                        .sheet(isPresented: $showingInformation) { MovieInformationView(url: url) }
                        .navigationTitle(url.deletingPathExtension().lastPathComponent)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) { Button { selected = nil } label: { Text(t("完成", "Done")).frame(minWidth: 60, minHeight: 44).contentShape(Rectangle()) }.accessibilityIdentifier("mediaPlayerDone") }
                            ToolbarItemGroup(placement: .bottomBar) {
                                Button { showingInformation = true } label: { Image(systemName: "info.circle") }
                                    .accessibilityLabel(t("视频信息", "Video information"))
                                    .accessibilityIdentifier("mediaInfo")
                                Spacer()
                                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                                Spacer()
                                Button { selected = nil; saveToPhotos([url]) } label: { Image(systemName: "square.and.arrow.down") }
                                    .accessibilityLabel(t("存入相册", "Save to Photos"))
                                    .accessibilityIdentifier("mediaSave.\(url.lastPathComponent)")
                                Spacer()
                                Button(role: .destructive) { selected = nil; pendingDelete = [url] } label: { Image(systemName: "trash") }
                                    .disabled(camera.recording || camera.finalizing)
                            }
                        }
                }
            }
            .confirmationDialog(t("删除素材？", "Delete recording?"), isPresented: Binding(
                get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }
            ), titleVisibility: .visible) {
                Button(t("删除文件", "Delete file"), role: .destructive) {
                    delete(pendingDelete)
                    pendingDelete = []
                }
            } message: { Text(t("将删除 \(pendingDelete.count) 个视频及其关联数据。", "Delete \(pendingDelete.count) videos and associated data.")) }
            .alert(t("素材", "Media"), isPresented: Binding(
                get: { message != nil }, set: { if !$0 { message = nil } }
            )) { Button(t("确定", "OK")) { message = nil } } message: { Text(AppText.message(message ?? "")) }
            .onAppear {
                reload()
                #if DEBUG
                if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--media-info-file=") }),
                   let file = files.first(where: { $0.lastPathComponent == String(argument.dropFirst("--media-info-file=".count)) }) {
                    selected = file
                }
                #endif
            }
            .onChange(of: camera.externalStorageConnected) { _, _ in reload() }
            .onChange(of: camera.finalizing) { _, saving in if !saving { reload() } }
            .refreshable { reload() }
            .onDisappear {
                scopedExternalFiles.forEach { $0.stopAccessingSecurityScopedResource() }
                scopedExternalFiles = []
            }
        }
    }

    private func mediaActionLabel(_ title: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title3)
            Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
    }

    private func fileSize(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func reload() {
        scopedExternalFiles.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedExternalFiles = []
        let internalFiles = [RecordingStoragePaths.movieDirectory, RecordingStoragePaths.legacyDirectory]
            .flatMap { directory in
                (try? FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            }.filter { $0.pathExtension.lowercased() == "mov" }
        var bookmarks = UserDefaults.standard.array(forKey: "externalMediaBookmarks") as? [Data] ?? []
        // Failed/incomplete finalization must not hide an existing SSD recording.
        let jobs = (try? FileManager.default.contentsOfDirectory(at: RecordingStoragePaths.diagnosticDirectory,
            includingPropertiesForKeys: nil)) ?? []
        for file in jobs where file.lastPathComponent.hasSuffix(".pending-imu.json") || file.lastPathComponent.hasSuffix(".failed-imu.json") {
            if let data = try? Data(contentsOf: file),
               let job = try? JSONDecoder().decode(PendingIMUJob.self, from: data),
               let bookmark = job.externalMovieBookmark, !bookmarks.contains(bookmark) {
                bookmarks.append(bookmark)
            }
        }
        for bookmark in bookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
                                     bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else { continue }
            if scopedExternalFiles.contains(url) { url.stopAccessingSecurityScopedResource() }
            else { scopedExternalFiles.append(url) }
        }
        files = (internalFiles + scopedExternalFiles.filter { FileManager.default.fileExists(atPath: $0.path) })
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        camera.logger.event("media_library_loaded", ["count": files.count,
            "externalCount": scopedExternalFiles.filter { FileManager.default.fileExists(atPath: $0.path) }.count,
            "files": files.map(\.lastPathComponent)])
    }

    private func toggle(_ url: URL) {
        if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
    }

    private func delete(_ urls: [URL]) {
        deleting = true
        camera.deleteMedia(urls) { error in
            deleting = false
            reload()
            selection.formIntersection(Set(files))
            if selection.isEmpty { selecting = false }
            if let error { message = "\(t("删除失败", "Could not delete"))：\(error)" }
        }
    }

    private func saveToPhotos(_ urls: [URL]) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { message = t("请在系统设置中允许存入相册。", "Allow Photos access in Settings.") }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                for url in urls { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
            } completionHandler: { saved, error in
                DispatchQueue.main.async {
                    message = saved ? t("已存入相册", "Saved to Photos") :
                        "\(t("存入相册失败", "Could not save to Photos"))：\(error?.localizedDescription ?? t("此格式可能不受相册支持", "This format may not be supported"))"
                }
            }
        }
    }
}

private struct MovieThumbnail: View {
    let url: URL
    @State private var image: UIImage?
    @State private var isRaw = false
    @State private var duration = "—"

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Rectangle().fill(.gray.opacity(0.25))
                        .overlay(Image(systemName: "film").foregroundStyle(.secondary))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .clipped()
            if isRaw {
                Text("RAW")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
                    .padding(3)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(alignment: .bottomTrailing) {
            Text(duration).font(.caption.monospacedDigit()).foregroundStyle(.white)
                .padding(5).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5)).padding(4)
        }
        .overlay(alignment: .topTrailing) { IMUBadge(url: url).padding(3) }
        .task(id: url) {
            let result = await MediaThumbnailLoader.shared.load(url)
            guard !Task.isCancelled else { return }
            image = result.0
            isRaw = result.1
            duration = result.2
        }
    }
}

/// Inspect the MOV itself; a sidecar or a pending job does not prove embedding.
private struct IMUBadge: View {
    let url: URL
    @State private var embedded: Bool?

    var body: some View {
        Group {
            if let embedded {
                Text(embedded ? "IMU" : "!IMU")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(embedded ? Color.green : Color.red)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 3))
                    .accessibilityLabel(embedded ? "IMU" : "!IMU")
                    .accessibilityIdentifier("imuBadge.\(url.lastPathComponent)")
            }
        }
        .task(id: url) {
            var previousSignature: String?
            while !Task.isCancelled {
                let lastSignature = previousSignature
                let result = await Task.detached(priority: .utility) { () -> (String, Bool?) in
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let incomplete = FileManager.default.fileExists(atPath: MOVTelemetryMuxer.recoveryURL(url).path)
                    let signature = "\(values?.fileSize ?? -1)-\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(incomplete)"
                    guard signature != lastSignature else { return (signature, nil) }
                    return (signature, !incomplete && MOVTelemetryMuxer.hasTelemetry(url))
                }.value
                guard !Task.isCancelled else { return }
                previousSignature = result.0
                if let value = result.1 { embedded = value }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

// The camera publishes live parameters frequently. Own the player for the sheet's
// lifetime so those updates cannot replace its item or reset playback.
private final class MoviePlaybackSession: ObservableObject {
    let player: AVPlayer
    init(url: URL) { player = AVPlayer(url: url) }
}

private struct StableMoviePlayer: View {
    @StateObject private var session: MoviePlaybackSession
    init(url: URL) {
        _session = StateObject(wrappedValue: MoviePlaybackSession(url: url))
    }
    var body: some View {
        VideoPlayer(player: session.player)
            .accessibilityIdentifier("mediaPlayer")
            .onDisappear { session.player.pause() }
    }
}


/// Serialize expensive RAW thumbnail decoding off the main actor. Cancel queued
/// requests when cards disappear so dismissing Media does not start more decoders.
private actor MediaThumbnailLoader {
    static let shared = MediaThumbnailLoader()
    func load(_ url: URL) -> (UIImage?, Bool, String) {
        guard !Task.isCancelled else { return (nil, false, "—") }
        let asset = AVURLAsset(url: url)
        let rawCodes: Set<FourCharCode> = [0x6170726e, 0x61707268]
        let raw = asset.tracks(withMediaType: .video).contains { track in
            track.formatDescriptions.contains { description in
                rawCodes.contains(CMFormatDescriptionGetMediaSubType(description as! CMFormatDescription))
            }
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        let frame = try? generator.copyCGImage(at: .zero, actualTime: nil)
        let seconds = CMTimeGetSeconds(asset.duration)
        let n = seconds.isFinite ? max(0, Int(seconds)) : 0
        let label = n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60) : String(format: "%02d:%02d", n / 60, n % 60)
        return (frame.map(UIImage.init(cgImage:)), raw, label)
    }
}

private struct MovieInformationView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var details: MovieInformation?
    @State private var failure: String?
    private func t(_ zh: String, _ en: String) -> String { AppText.value(zh, en, locale: locale) }
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                if let details {
                    Section(t("原始视频", "Original video")) {
                        row("文件名", "Filename", url.lastPathComponent)
                        row("编码", "Codec", details.codec)
                        row("分辨率", "Resolution", details.resolution)
                        row("帧率", "Frame rate", details.fps)
                        row("时长", "Duration", details.duration)
                        row("文件大小", "File size", details.size)
                        row("拍摄日期", "Recorded", details.date.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "—")
                        if let location = details.slate[RecordingLocation.metadataKey] {
                            row("拍摄位置", "Recording location", location)
                        }
                        row("色彩空间", "Color space", details.color)
                        row("音频", "Audio", details.audio)
                        row("IMU", "IMU", details.imu ? t("已嵌入", "Embedded") : t("未检测到", "Not detected"))
                    }
                    Section {
                        row("快门", "Shutter", details.shutter).id("settings")
                        row("光圈", "Aperture", details.aperture)
                        row("ISO", "ISO", details.iso)
                        row("白平衡", "White balance", details.whiteBalance)
                        row("色调", "Tint", details.tint)
                    } header: { Text(t("录制开始时的参数", "Settings at recording start")) }
                    footer: { Text(t("自动参数可能在录制过程中变化。旧素材未保存的字段显示为 —。", "Automatic settings may change during recording. Fields absent from older files appear as —.")) }
                    Section(t("相机与场记", "Camera and slate")) {
                        row("机型", "Camera", details.model).id("camera")
                        row("镜头", "Lens", lensLabel(details))
                        row("变焦倍率", "Zoom", details.zoom)
                        row("制作名称", "Production", details.slate["com.apple.quicktime.title"] ?? "—")
                        row("机位", "Camera ID", details.slate["com.apple.quicktime.camera.identifier"] ?? "—")
                        row("卷号", "Reel", details.slate["com.apple.quicktime.reel"] ?? "—")
                        row("场景", "Scene", details.slate["com.apple.quicktime.scene"] ?? "—")
                        row("镜次", "Take", details.slate["com.apple.quicktime.take"] ?? "—")
                        row("导演", "Director", details.slate["com.apple.quicktime.director"] ?? "—")
                        row("摄影师", "Cinematographer", details.slate["com.tinygrape.gyrocine.cinematographer"] ?? "—")
                        row("备注", "Notes", details.slate["com.apple.quicktime.description"] ?? "—")
                    }
                } else if failure != nil {
                    Text(t("无法读取视频信息", "Could not read video information"))
                } else { ProgressView() }
            }
            .accessibilityIdentifier("mediaInformation")
            .navigationTitle(t("视频信息", "Video information"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button(t("完成", "Done")) { dismiss() }.accessibilityIdentifier("mediaInformationDone")
            } }
            .task(id: url) {
                do {
                    details = try await MovieInformationLoader.shared.load(url)
                    #if DEBUG
                    if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--media-info-section=") }) {
                        try? await Task.sleep(for: .milliseconds(500))
                        proxy.scrollTo(String(argument.dropFirst("--media-info-section=".count)), anchor: .top)
                    }
                    #endif
                }
                catch { failure = error.localizedDescription }
            }
            }
        }
    }
    private func lensLabel(_ info: MovieInformation) -> String {
        let names: [String: String] = [
            AVCaptureDevice.DeviceType.builtInWideAngleCamera.rawValue: t("广角", "Wide"),
            AVCaptureDevice.DeviceType.builtInUltraWideCamera.rawValue: t("超广角", "Ultra Wide"),
            AVCaptureDevice.DeviceType.builtInTelephotoCamera.rawValue: t("长焦", "Telephoto")]
        guard let kind = names[info.lensType] else { return info.lens }
        return (info.position == "front" ? t("前置", "Front") : t("后置", "Back")) + " · " + kind
    }
    private func row(_ zh: String, _ en: String, _ value: String) -> some View {
        LabeledContent { Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }
            label: { Text(t(zh, en)) }
    }
}

struct MovieInformation {
    var codec = "—", resolution = "—", fps = "—", duration = "—", size = "—", color = "—", audio = "—"
    var shutter = "—", aperture = "—", iso = "—", whiteBalance = "—", tint = "—"
    var model = "—", lens = "—", zoom = "—", lensType = "", position = ""
    var date: Date?
    var imu = false
    var slate: [String: String] = [:]
}

/// Parse only headers on a background actor; never decode video to show information.
actor MovieInformationLoader {
    static let shared = MovieInformationLoader()
    func load(_ url: URL) async throws -> MovieInformation {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        var result = MovieInformation()
        // AVFoundation may omit the Sony rtmd track from its public track list.
        // Use the same MOV-header inspection as the media grid badge.
        result.imu = MOVTelemetryMuxer.hasTelemetry(url)
        let metadata = try await asset.load(.metadata)
        for item in metadata {
            if let key = item.key as? String, let value = item.stringValue ?? item.numberValue?.stringValue { result.slate[key] = value }
        }
        let raw = result.slate[RecordingMetadata.snapshotKey]?.data(using: .utf8)
        let snapshot = raw.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func number(_ key: String, _ format: String) -> String {
            guard let value = snapshot[key] as? NSNumber, value.doubleValue.isFinite else { return "—" }
            return String(format: format, value.doubleValue)
        }
        result.model = result.slate["com.apple.quicktime.model"] ?? snapshot["model"] as? String ?? "—"
        result.lens = snapshot["lensName"] as? String ?? "—"
        result.lensType = snapshot["lensType"] as? String ?? ""
        result.position = snapshot["position"] as? String ?? ""
        if result.lens.isEmpty { result.lens = "—" }
        result.zoom = number("zoom", "%.2f×")
        result.aperture = number("aperture", "f/%.1f")
        result.iso = number("iso", "%.0f")
        result.whiteBalance = number("whiteBalanceKelvin", "%.0f K")
        result.tint = number("tint", "%.1f")
        if let seconds = snapshot["exposureSeconds"] as? Double, seconds > 0 {
            result.shutter = seconds < 1 ? String(format: "1/%.0f s", 1 / seconds) : String(format: "%.3f s", seconds)
        }
        if result.iso == "—" { result.iso = result.slate["org.smpte.rdd18.camera.isosensitivity"] ?? "—" }
        if result.whiteBalance == "—" { result.whiteBalance = result.slate["org.smpte.rdd18.camera.whitebalance"] ?? "—" }
        if result.shutter == "—", let text = result.slate["org.smpte.rdd18.camera.shutterspeed_time"],
           let seconds = Double(text), seconds.isFinite, seconds > 0 {
            result.shutter = seconds < 1 ? String(format: "1/%.0f s", 1 / seconds) : String(format: "%.3f s", seconds)
        }
        if let text = result.slate["com.apple.quicktime.creationdate"] { result.date = ISO8601DateFormatter().date(from: text) }
        if result.date == nil { result.date = try await asset.load(.creationDate)?.dateValue }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        if duration.isFinite { result.duration = String(format: "%.2f s", duration) }
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        result.size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        func fourCC(_ value: FourCharCode) -> String {
            String(bytes: [24,16,8,0].map { UInt8((value >> $0) & 255) }, encoding: .ascii) ?? "—"
        }
        for track in tracks {
            let descriptions = try await track.load(.formatDescriptions)
            for description in descriptions {
                let code = fourCC(CMFormatDescriptionGetMediaSubType(description))
                if ["rtmd", "gyrf"].contains(code) { result.imu = true }
                if track.mediaType == .video {
                    let names = ["hvc1":"H.265", "hev1":"H.265", "avc1":"H.264", "apch":"ProRes 422 HQ", "apcn":"ProRes 422", "apcs":"ProRes 422 LT", "apco":"ProRes 422 Proxy", "aprn":"ProRes RAW", "aprh":"ProRes RAW HQ"]
                    result.codec = names[code] ?? code
                    let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                    let transform = try await track.load(.preferredTransform)
                    let size = CGSize(width: Int(dimensions.width), height: Int(dimensions.height)).applying(transform)
                    result.resolution = "\(Int(abs(size.width))) × \(Int(abs(size.height)))"
                    result.fps = String(format: "%.3f fps", try await track.load(.nominalFrameRate))
                    let ext = (CMFormatDescriptionGetExtensions(description) as NSDictionary?) ?? [:]
                    let log = ext["LogTransferFunction"] as? String ?? ""
                    let primaries = ext[kCVImageBufferColorPrimariesKey] as? String ?? ""
                    let transfer = ext[kCVImageBufferTransferFunctionKey] as? String ?? ""
                    if ["aprn", "aprh"].contains(code) { result.color = "RAW" }
                    else if log.contains("apple-wide-gamut") { result.color = "Apple Log 2" }
                    else if log.contains("apple-log") { result.color = "Apple Log" }
                    else if transfer.contains("HLG") { result.color = "Rec.2020 · HDR (HLG)" }
                    else if primaries.contains("P3") { result.color = "P3 D65" }
                    else if primaries.contains("709") { result.color = "Rec.709" }
                    else { result.color = snapshot["colorSpace"] as? String ?? "—" }
                } else if track.mediaType == .audio, let audio = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                    result.audio = "\(code.trimmingCharacters(in: .whitespaces)) · \(Int(audio.mSampleRate)) Hz · \(audio.mChannelsPerFrame) ch"
                }
            }
        }
        return result
    }
}
