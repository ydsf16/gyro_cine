import SwiftUI

@main
struct GyroCineApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraManager()
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--slate-ui-preview") {
                    RecordingSlateView()
                } else if ProcessInfo.processInfo.arguments.contains("--settings-ui-preview") {
                    SettingsView()
                } else { CameraView() }
                #else
                CameraView()
                #endif
            }.environmentObject(camera)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
                .onChange(of: scenePhase) { _, phase in
                    UIApplication.shared.isIdleTimerDisabled = phase == .active
                }
        }
    }
}
