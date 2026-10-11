import SwiftUI

// Translucent camera controls with a mint accent.
enum RecorderTheme {
    static let background = Color(white: 0.035)
    static let surface = Color(white: 0.085)
    static let accent = Color(red: 0.22, green: 0.82, blue: 0.70)
    static let brandGradient = LinearGradient(colors: [
        Color(red: 0.15, green: 0.65, blue: 0.98),
        Color(red: 0.18, green: 0.82, blue: 0.89),
        Color(red: 0.20, green: 0.94, blue: 0.79)
    ], startPoint: .bottomLeading, endPoint: .topTrailing)
}
