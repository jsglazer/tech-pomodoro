import SwiftUI
import UIKit

/// The one place a colour is defined on iOS — the `UIColor` twin of the macOS `Theme`, with the same
/// tokens and hex values, so a palette change is made in both files and nowhere else.
///
/// Also compiled into the Live Activity extension, which is why it does not import the core: the
/// token mapping lives in `Theme+Tokens.swift`, which only the app builds.
enum Theme {
    static let background = hex(0x0A0A0A)
    static let primaryText = hex(0x22D3EE)
    static let dimmedText = hex(0x5A7C82)
    static let warning = hex(0xFACC15)
    static let alert = hex(0xEF4444)
    static let rule = hex(0x164E63)

    /// `#22D3EE`, the primary cyan, for anything that carries a colour as a string.
    static let primaryHex = "#22D3EE"

    /// Parses a `#RRGGBB` string, falling back to the primary cyan when it does not parse — a bad
    /// stored value must never leave the countdown invisible.
    static func color(hexString: String) -> UIColor {
        var trimmed = hexString.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else { return primaryText }
        return hex(value)
    }

    /// `#RRGGBB` for a colour, so a picker selection round-trips through the settings blob.
    static func hexString(_ color: UIColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return primaryHex }
        func channel(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(red), channel(green), channel(blue))
    }

    private static func hex(_ value: Int) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    static let tpBackground = Color(uiColor: Theme.background)
    static let tpPrimary = Color(uiColor: Theme.primaryText)
    static let tpDimmed = Color(uiColor: Theme.dimmedText)
    static let tpWarning = Color(uiColor: Theme.warning)
    static let tpAlert = Color(uiColor: Theme.alert)
    static let tpRule = Color(uiColor: Theme.rule)

    init(hexString: String) {
        self.init(uiColor: Theme.color(hexString: hexString))
    }
}
