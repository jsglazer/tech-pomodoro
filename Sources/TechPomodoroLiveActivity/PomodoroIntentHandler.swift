import Foundation

/// The extension's half of the Live Activity buttons. A `LiveActivityIntent` performs in the app's
/// process, never here, so this only exists to let the shared intents compile into the extension.
enum PomodoroIntentHandler {
    @MainActor
    static func handle(_ action: PomodoroIntentAction) async {}
}
