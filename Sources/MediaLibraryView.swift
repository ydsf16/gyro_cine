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
            List(files, id: \.self) { url in
                HStack(spacing: 12) {
                    Button {
                        if selecting { toggle(url) } else { selected = url }
                    } label: {
                        HStack(spacing: 12) {
                            if selecting {
                                Image(systemName: selection.contains(url) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selection.contains(url) ? Color.blue : Color.secondary)
                            }
                            MovieThumbnail(url: url)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(url.lastPathComponent).lineLimit(1)
                                    .font(.subheadline.weight(.semibold))
                                Text(fileSize(url)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mediaRow.\(url.lastPathComponent)")
                    .highPriorityGesture(LongPressGesture(minimumDuration: 0.55).onEnded { _ in
                        selecting = true; selection.insert(url)
                    })
                    if !selecting {
                        Button { saveToPhotos(url) } label: {
                            Image(systemName: "square.and.arrow.down")
                                .frame(width: 32, height: 40)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(t("存入相册", "Save to Photos"))
                        .accessibilityIdentifier("mediaSave.\(url.lastPathComponent)")
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                                .frame(width: 32, height: 40)
                        }
                        .accessibilityLabel(t("分享", "Share"))
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(t("删除", "Delete"), role: .destructive) { pendingDelete = [url] }
                }
            }
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
                    } else { Button(t("完成", "Done")) { dismiss() } }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    HStack {
                        Text(t("已选 \(selection.count) 项", "\(selection.count) selected")).font(.subheadline)
                        Spacer()
                        ShareLink(items: files.filter { selection.contains($0) }) {
                            Label(t("分享", "Share"), systemImage: "square.and.arrow.up")
                        }.accessibilityIdentifier("mediaShareSelected")
                        Button(role: .destructive) { pendingDelete = files.filter { selection.contains($0) } } label: {
                            Label(t("删除", "Delete"), systemImage: "trash")
                        }.accessibilityIdentifier("mediaDeleteSelected")
                    }.padding().background(.regularMaterial)
                        .disabled(selection.isEmpty || deleting || camera.finalizing || camera.recording)
                }
            }
            .disabled(deleting)
            .sheet(item: $selected) { url in
                VideoPlayer(player: AVPlayer(url: url)).padding()
                    .overlay(alignment: .topTrailing) { IMUBadge(url: url).padding(20) }
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
            )) { Button(t("确定", "OK")) { message = nil } } message: { Text(message ?? "") }
            .onAppear { reload() }
            .onDisappear {
                scopedExternalFiles.forEach { $0.stopAccessingSecurityScopedResource() }
                scopedExternalFiles = []
            }
        }
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
        let bookmarks = UserDefaults.standard.array(forKey: "externalMediaBookmarks") as? [Data] ?? []
        for bookmark in bookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
                                     bookmarkDataIsStale: &stale), !stale,
                  url.startAccessingSecurityScopedResource() else { continue }
            scopedExternalFiles.append(url)
        }
        files = (internalFiles + scopedExternalFiles.filter { FileManager.default.fileExists(atPath: $0.path) })
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
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

    private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { message = t("请在系统设置中允许存入相册。", "Allow Photos access in Settings.") }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
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

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.gray.opacity(0.25))
                        .overlay(Image(systemName: "film").foregroundStyle(.secondary))
                }
            }
            .frame(width: 82, height: 58)
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
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topTrailing) { IMUBadge(url: url).padding(3) }
        .task(id: url) {
            let result = await Task.detached(priority: .utility) { () -> (UIImage?, Bool) in
                let asset = AVURLAsset(url: url)
                let rawCodes: Set<FourCharCode> = [0x6170726e, 0x61707268]
                let raw = asset.tracks(withMediaType: .video).contains { track in
                    track.formatDescriptions.contains { description in
                        rawCodes.contains(CMFormatDescriptionGetMediaSubType(description as! CMFormatDescription))
                    }
                }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                let frame = try? generator.copyCGImage(at: .zero, actualTime: nil)
                return (frame.map(UIImage.init(cgImage:)), raw)
            }.value
            image = result.0
            isRaw = result.1
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
