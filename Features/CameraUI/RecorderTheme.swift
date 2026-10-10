import SwiftUI

// Visual palette follows the user's RoamShot camera and settings screens.
enum RecorderTheme {
    static let background = Color(red: 0.045, green: 0.065, blue: 0.10)
    static let surface = Color(red: 0.085, green: 0.115, blue: 0.16)
    static let accent = Color(red: 0.31, green: 0.88, blue: 0.79)
    static let brandGradient = LinearGradient(colors: [
        Color(red: 0.15, green: 0.65, blue: 0.98),
        Color(red: 0.18, green: 0.82, blue: 0.89),
        Color(red: 0.20, green: 0.94, blue: 0.79)
    ], startPoint: .bottomLeading, endPoint: .topTrailing)
}
