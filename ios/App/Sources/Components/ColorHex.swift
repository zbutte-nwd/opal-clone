import SwiftUI

extension Color {
    /// "#RRGGBB" or "RRGGBB"; falls back to the accent color for nil/invalid input.
    init(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { self = .accentColor; return }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { self = .accentColor; return }
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255,
                  opacity: 1)
    }
}

enum GroupPalette {
    static let hexes = ["#FF6B6B", "#FF9F43", "#F4C430", "#2EC4B6", "#4A90E2", "#7C5CFF", "#E056A0", "#8E8E93"]
    static func nextHex(used: [String?]) -> String {
        hexes.first { h in !used.contains { $0?.uppercased() == h } } ?? hexes[0]
    }
}
