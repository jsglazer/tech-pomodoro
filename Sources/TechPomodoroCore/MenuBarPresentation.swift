import Foundation

/// A named slot in the theme. The core decides *which* colour a thing is; only the shell knows what
/// that colour looks like, so no `NSColor` ever crosses this boundary.
public enum ColorToken: String, Sendable, Equatable, CaseIterable {
    case background
    case primaryText
    case dimmedText
    case warning
    case alert
    case rule
}

/// Everything the status item needs in order to draw itself, with no AppKit types in sight.
public struct MenuBarPresentation: Sendable, Equatable {
    /// The title to draw, e.g. `"24"`. Nil in clock-icon mode.
    public var text: String?
    /// An SF Symbol name to draw instead of a title. Nil in minutes-remaining mode.
    public var symbolName: String?
    public var foreground: ColorToken
    /// Non-nil only when the user enabled a filled background.
    public var background: ColorToken?

    public init(text: String? = nil, symbolName: String? = nil, foreground: ColorToken, background: ColorToken? = nil) {
        self.text = text
        self.symbolName = symbolName
        self.foreground = foreground
        self.background = background
    }
}

/// Maps `(state, now)` onto an abstract menu bar appearance.
///
/// Pure, so the threshold rules are unit-testable to the second, and cheap, so the shell can call it
/// on every refresh tick and redraw only when the result actually changed.
public enum MenuBarFormatter {

    public static func presentation(for state: PomodoroState, at now: Date) -> MenuBarPresentation {
        let settings = state.settings
        let background: ColorToken? = settings.useCustomBackground ? .background : nil

        guard state.activity != .idle else {
            return MenuBarPresentation(symbolName: "timer", foreground: .dimmedText, background: background)
        }

        switch settings.menuBarMode {
        case .clockIcon:
            // Clock-icon mode ignores the thresholds entirely.
            return MenuBarPresentation(
                symbolName: state.activity == .paused ? "pause.circle" : "timer",
                foreground: .primaryText,
                background: background
            )

        case .minutesRemaining:
            let remaining = state.remaining(at: now)
            return MenuBarPresentation(
                text: minutesText(remaining),
                symbolName: nil,
                foreground: foregroundToken(for: state, remaining: remaining),
                background: background
            )
        }
    }

    /// Minutes remaining, rounded up, so the title reads "1" for the whole final minute and only
    /// becomes "0" in the last second.
    public static func minutesText(_ remaining: TimeInterval) -> String {
        String(Int(ceil(max(0, remaining) / 60)))
    }

    /// Threshold colours apply to Work only, in minutes-remaining mode only; a threshold of `0`
    /// disables that step.
    private static func foregroundToken(for state: PomodoroState, remaining: TimeInterval) -> ColorToken {
        guard state.phase == .work else { return .primaryText }
        let settings = state.settings

        if settings.alertThresholdMinutes > 0,
           remaining <= TimeInterval(settings.alertThresholdMinutes * 60) {
            return .alert
        }
        if settings.warningThresholdMinutes > 0,
           remaining <= TimeInterval(settings.warningThresholdMinutes * 60) {
            return .warning
        }
        return .primaryText
    }
}
