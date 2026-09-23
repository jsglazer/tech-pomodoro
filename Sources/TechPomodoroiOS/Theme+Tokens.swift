import SwiftUI
import TechPomodoroCore
import UIKit

extension Theme {
    /// The core emits `ColorToken` values; this maps them onto the palette. App target only — the
    /// Live Activity extension shares `Theme` but not the core.
    static func color(_ token: ColorToken) -> UIColor {
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
        Color(uiColor: color(token))
    }

    /// The countdown's colour, from the same presentation the Mac menu bar draws: a threshold colour
    /// during late Work, the rest colour during rest phases, a chosen custom colour, else cyan.
    static func countdownColor(for state: PomodoroState, at now: Date) -> Color {
        Color(uiColor: countdownUIColor(for: state, at: now))
    }

    static func countdownHex(for state: PomodoroState, at now: Date) -> String {
        hexString(countdownUIColor(for: state, at: now))
    }

    private static func countdownUIColor(for state: PomodoroState, at now: Date) -> UIColor {
        guard state.activity != .paused else { return warning }
        // The iOS countdown always reads as minutes-remaining, whatever the Mac menu bar mode is, so
        // the thresholds apply here even when the synced setting says clock icon.
        var settings = state.settings
        settings.menuBarMode = .minutesRemaining
        var effective = state
        effective.settings = settings
        let presentation = MenuBarFormatter.presentation(for: effective, at: now)
        if let hex = presentation.customForegroundHex { return color(hexString: hex) }
        return color(presentation.foreground)
    }
}
