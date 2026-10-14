import SwiftUI

@main
struct GyroCineApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraManager()
    var body: some Scene {
        WindowGroup {
            CameraView().environmentObject(camera)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
                .onChange(of: scenePhase) { _, phase in
                    UIApplication.shared.isIdleTimerDisabled = phase == .active
                }
        }
    }
}
