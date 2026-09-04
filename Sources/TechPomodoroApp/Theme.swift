import AppKit
import SwiftUI
import TechPomodoroCore

/// The one place a colour is defined.
///
/// The core emits `ColorToken` values; this is the only file that knows what they look like, so the
/// DevNotes palette can be re-tuned here without touching a single line of logic.
enum Theme {
    static let background = hex(0x0A0A0A)
    static let primaryText = hex(0x22D3EE)
    static let dimmedText = hex(0x5A7C82)
    static let warning = hex(0xFACC15)
    static let alert = hex(0xEF4444)
    static let rule = hex(0x164E63)

    static func color(_ token: ColorToken) -> NSColor {
        switch token {
        case .background: return background
        case .primaryText: return primaryText
        case .dimmedText: return dimmedText
        case .warning: return warning
        case .alert: return alert
        case .rule: return rule
        }
    }

    static func swiftUIColor(_ token: ColorToken) -> Color {
        Color(nsColor: color(token))
    }

    /// Parses a `#RRGGBB` string, falling back to the primary cyan when it does not parse — a bad
    /// stored value must never leave the menu bar item invisible.
    static func color(hexString: String) -> NSColor {
        var trimmed = hexString.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else { return primaryText }
        return hex(value)
    }

    /// `#RRGGBB` for a colour, so a picker selection round-trips through the settings blob.
    static func hexString(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#22D3EE" }
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }

    private static func hex(_ value: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    static let tpBackground = Theme.swiftUIColor(.background)
    static let tpPrimary = Theme.swiftUIColor(.primaryText)
    static let tpDimmed = Theme.swiftUIColor(.dimmedText)
    static let tpWarning = Theme.swiftUIColor(.warning)
    static let tpAlert = Theme.swiftUIColor(.alert)
    static let tpRule = Theme.swiftUIColor(.rule)
}
