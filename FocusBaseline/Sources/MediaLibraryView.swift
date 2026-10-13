import AVKit
import SwiftUI

struct MediaLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var selected: URL?
    var body: some View {
        NavigationStack {
            List(files, id: \.self) { url in
                HStack {
                    Button { selected = url } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(url.lastPathComponent).lineLimit(1)
                            Text((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                }
            }
            .overlay { if files.isEmpty { ContentUnavailableView("暂无素材", systemImage: "film") } }
            .navigationTitle("Media")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .sheet(item: $selected) { url in VideoPlayer(player: AVPlayer(url: url)).padding() }
            .onAppear { reload() }
        }
    }
    private func reload() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let enumerator = FileManager.default.enumerator(at: documents, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "mov" }
            .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast >
                      (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
