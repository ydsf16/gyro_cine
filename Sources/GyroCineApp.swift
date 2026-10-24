import SwiftUI

@main
struct GyroCineApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraManager()
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--pro-ui-preview") {
                    ProAccessPreviewHost()
                } else if ProcessInfo.processInfo.arguments.contains("--slate-ui-preview") {
                    RecordingSlateView()
                } else if ProcessInfo.processInfo.arguments.contains("--settings-ui-preview") {
                    SettingsView()
                } else if ProcessInfo.processInfo.arguments.contains("--media-ui-preview") {
                    MediaLibraryView()
                } else { CameraView() }
                #else
                CameraView()
                #endif
            }.environmentObject(camera)
                .task { await ProStore.shared.prepare() }
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    RecordingLocation.shared.setActive(true)
                }
                .onChange(of: scenePhase) { _, phase in
                    UIApplication.shared.isIdleTimerDisabled = phase == .active
                    if phase == .active { RecordingLocation.shared.setActive(true) }
                    else if phase == .background { RecordingLocation.shared.setActive(false) }
                    if phase == .active { Task { await ProStore.shared.prepare() } }
                }
        }
    }
}

#if DEBUG
// Present the QA entry point in the same sheet context as Settings.
// A root ProAccessView has no presentation for its Done action to dismiss.
private struct ProAccessPreviewHost: View {
    @State private var showingPro = true
    var body: some View {
        CameraView()
            .sheet(isPresented: $showingPro) { ProAccessView() }
            .task {
                if ProcessInfo.processInfo.arguments.contains("--pro-sandbox-restore") {
                    await ProStore.shared.prepare()
                    #if !TESTFLIGHT_FREE
                    await ProStore.shared.restore()
                    #endif
                }
            }
    }
}
#endif
