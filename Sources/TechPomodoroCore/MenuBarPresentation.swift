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
    /// When true the shell must let macOS colour this itself — a template image, or a title in the
    /// system label colour — so the item stays legible on a light menu bar and matches its
    /// neighbours. Only a deliberate signal (a threshold colour, or a title drawn on our own filled
    /// background) overrides the system's choice.
    public var adaptsToMenuBar: Bool
    /// A user-chosen `#RRGGBB` that replaces the `foreground` token. Never set while a threshold
    /// colour is showing: a deliberate warning must not be paintable over.
    public var customForegroundHex: String?

    public init(
        text: String? = nil,
        symbolName: String? = nil,
        foreground: ColorToken,
        background: ColorToken? = nil,
        adaptsToMenuBar: Bool = true,
        customForegroundHex: String? = nil
    ) {
        self.text = text
        self.symbolName = symbolName
        self.foreground = foreground
        self.background = background
        self.adaptsToMenuBar = adaptsToMenuBar
        self.customForegroundHex = customForegroundHex
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
            return MenuBarPresentation(
                symbolName: "timer",
                foreground: .dimmedText,
                background: background,
                adaptsToMenuBar: background == nil
            )
        }

        switch settings.menuBarMode {
        case .clockIcon:
            // Clock-icon mode ignores the thresholds entirely.
            let custom = restHex(for: state) ?? (settings.useCustomTextColor ? settings.menuBarTextColorHex : nil)
            return MenuBarPresentation(
                symbolName: state.activity == .paused ? "pause.circle" : "timer",
                foreground: .primaryText,
                background: background,
                adaptsToMenuBar: background == nil && custom == nil,
                customForegroundHex: custom
            )

        case .minutesRemaining:
            let remaining = state.remaining(at: now)
            let token = foregroundToken(for: state, remaining: remaining)
            // A threshold colour is the whole point of the threshold, so it always wins; otherwise
            // the countdown adopts the menu bar's own colour like any other item.
            let isThreshold = token == .warning || token == .alert
            // A chosen colour applies to the ordinary countdown only; a threshold still wins. The
            // rest colour outranks the general custom colour, since it is the more specific signal —
            // and it can never collide with a threshold, which is Work-only.
            let custom = restHex(for: state)
                ?? ((settings.useCustomTextColor && !isThreshold) ? settings.menuBarTextColorHex : nil)
            return MenuBarPresentation(
                text: minutesText(remaining),
                symbolName: nil,
                foreground: token,
                background: background,
                adaptsToMenuBar: !isThreshold && background == nil && custom == nil,
                customForegroundHex: custom
            )
        }
    }

    /// Minutes remaining, rounded up, so the title reads "1" for the whole final minute and only
    /// becomes "0" in the last second.
    public static func minutesText(_ remaining: TimeInterval) -> String {
        String(Int(ceil(max(0, remaining) / 60)))
    }

    /// The rest-phase colour, when the user enabled it and the timer is in one of the rest phases.
    private static func restHex(for state: PomodoroState) -> String? {
        guard state.settings.useRestColor, state.phase != .work else { return nil }
        return state.settings.restColorHex
    }

    /// What the status item says on hover: the phase and the exact time left, e.g. `Work 24:31`.
    /// Pure, so the wording and the zero-padding are pinned by tests rather than by eyeballing a
    /// tooltip.
    public static func hoverText(for state: PomodoroState, at now: Date) -> String {
        guard state.activity != .idle else { return "tech-pomodoro — Ready" }

        let remaining = Int(max(0, state.remaining(at: now)).rounded(.up))
        let clock = String(format: "%02d:%02d", remaining / 60, remaining % 60)
        let prefix = state.activity == .paused ? "Paused — " : ""
        return "\(prefix)\(state.phase.title) \(clock)"
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
