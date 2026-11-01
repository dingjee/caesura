import SwiftUI

extension Color {
    /// Parses legacy "#RRGGBB" (and #RRGGBBAA) color strings.
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8 else { return nil }
        var rgba: UInt64 = 0
        Scanner(string: value).scanHexInt64(&rgba)
        switch value.count {
        case 6:
            self.init(red: Double((rgba >> 16) & 0xFF) / 255,
                      green: Double((rgba >> 8) & 0xFF) / 255,
                      blue: Double(rgba & 0xFF) / 255)
        default:
            self.init(red: Double((rgba >> 24) & 0xFF) / 255,
                      green: Double((rgba >> 16) & 0xFF) / 255,
                      blue: Double((rgba >> 8) & 0xFF) / 255,
                      opacity: Double(rgba & 0xFF) / 255)
        }
    }
}
