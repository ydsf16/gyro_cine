import SwiftUI

@main
struct RAWFocusTestApp: App {
    @StateObject private var camera = CameraManager()
    var body: some Scene {
        WindowGroup { CameraView().environmentObject(camera) }
    }
}
