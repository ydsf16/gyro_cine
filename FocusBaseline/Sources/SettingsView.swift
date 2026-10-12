import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var camera: CameraManager
    @Environment(\.dismiss) private var dismiss
    @State private var shareURL: URL?
    var body: some View {
        NavigationStack {
            List {
                Section("1. Codec") {
                    ForEach(camera.codecs, id: \.rawValue) { codec in
                        Button { camera.chooseCodec(codec) } label: {
                            row(codec.rawValue, checked: camera.selectedCodec == codec)
                        }.disabled(camera.recording)
                    }
                }
                Section("2. Camera Format — all device formats") {
                    ForEach(camera.formats) { format in
                        let supported = format.compatibleCodecs.contains(camera.selectedCodec?.rawValue ?? "")
                        Button { camera.chooseFormat(format.index) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                row(format.label, checked: camera.selectedFormatIndex == format.index)
                                Text(supported ? "Compatible" : "Unavailable for selected codec")
                                    .font(.caption).foregroundStyle(supported ? .green : .secondary)
                            }
                        }.disabled(camera.recording || !supported)
                    }
                }
                Section("3. FPS") {
                    ForEach(camera.availableFPS, id: \.self) { fps in
                        Button { camera.chooseFPS(fps) } label: {
                            row(String(format: "%.3f fps", fps), checked: abs(camera.fps - fps) < 0.001)
                        }.disabled(camera.recording)
                    }
                }
                Section("4. Focus Mode") {
                    ForEach(FocusChoice.allCases) { choice in
                        Button { camera.chooseFocus(choice) } label: {
                            row(choice.rawValue, checked: camera.focusChoice == choice)
                        }
                    }
                }
                Section("Logs") {
                    Button("Export Current Session") { camera.export(false) }
                    Button("Export Capability Report") { camera.export(true) }
                    Text("Session \(camera.logger.sessionID)").font(.caption).textSelection(.enabled)
                }
            }
            .navigationTitle("RAW Focus Test")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
            .onChange(of: camera.exportURL) { _, value in shareURL = value }
        }
    }
    private func row(_ title: String, checked: Bool) -> some View {
        HStack { Text(title).foregroundStyle(.primary); Spacer(); if checked { Image(systemName: "checkmark") } }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
