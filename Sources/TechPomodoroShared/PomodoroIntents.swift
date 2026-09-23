import AppIntents
import Foundation

// The Live Activity's buttons. Compiled into both targets because the widget extension needs the
// types to build `Button(intent:)`, but a `LiveActivityIntent` always *performs* in the app's
// process — the system launches the app in the background if it is not running. Each target
// supplies its own `PomodoroIntentHandler`: the app's drives the real controller, the extension's
// is an inert stub that is never called.

struct ToggleRunningIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or Resume"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        await PomodoroIntentHandler.handle(.toggleRunning)
        return .result()
    }
}

struct StopTimerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Timer"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        await PomodoroIntentHandler.handle(.stop)
        return .result()
    }
}

struct SkipPhaseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip Phase"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        await PomodoroIntentHandler.handle(.skip)
        return .result()
    }
}
