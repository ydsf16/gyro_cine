import AVFoundation
import AVKit
import Photos
import SwiftUI

struct MediaLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var files: [URL] = []
    @State private var selected: URL?
    @State private var pendingDelete: URL?
    @State private var message: String?

    private func t(_ chinese: String, _ english: String) -> String {
        AppText.value(chinese, english, locale: locale)
    }

    var body: some View {
        NavigationStack {
            List(files, id: \.self) { url in
                HStack(spacing: 12) {
                    Button { selected = url } label: {
                        HStack(spacing: 12) {
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
                    Button { saveToPhotos(url) } label: {
                        Image(systemName: "square.and.arrow.down")
                            .frame(width: 32, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t("存入相册", "Save to Photos"))
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 32, height: 40)
                    }
                    .accessibilityLabel(t("分享", "Share"))
                }
                .swipeActions(edge: .trailing) {
                    Button(t("删除", "Delete"), role: .destructive) { pendingDelete = url }
                }
            }
            .overlay { if files.isEmpty { ContentUnavailableView(t("暂无素材", "No recordings"), systemImage: "film") } }
            .navigationTitle(t("素材", "Media"))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(t("完成", "Done")) { dismiss() } } }
            .sheet(item: $selected) { url in
                VideoPlayer(player: AVPlayer(url: url)).padding()
            }
            .confirmationDialog(t("删除素材？", "Delete recording?"), isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            ), titleVisibility: .visible) {
                Button(t("删除文件", "Delete file"), role: .destructive) {
                    if let url = pendingDelete { delete(url) }
                    pendingDelete = nil
                }
            } message: { Text(pendingDelete?.lastPathComponent ?? "") }
            .alert(t("素材", "Media"), isPresented: Binding(
                get: { message != nil }, set: { if !$0 { message = nil } }
            )) { Button(t("确定", "OK")) { message = nil } } message: { Text(message ?? "") }
            .onAppear { reload() }
        }
    }

    private func fileSize(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func reload() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let enumerator = FileManager.default.enumerator(at: documents,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        files = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "mov" }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
    }

    private func delete(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            files.removeAll { $0 == url }
            if selected == url { selected = nil }
        } catch { message = "\(t("删除失败", "Could not delete"))：\(error.localizedDescription)" }
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

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
