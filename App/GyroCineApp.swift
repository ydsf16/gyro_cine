import SwiftUI

@main
struct GyroCineApp: App {
    @StateObject private var model = RecorderViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model).preferredColorScheme(.dark).tint(RecorderTheme.accent)
        }
    }
}
