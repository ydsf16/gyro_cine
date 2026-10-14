import SwiftUI

@main
struct GyroCineApp: App {
    @StateObject private var camera = CameraManager()
    var body: some Scene {
        WindowGroup { CameraView().environmentObject(camera) }
    }
}
