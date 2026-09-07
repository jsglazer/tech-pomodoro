import AppKit
import TechPomodoroCore

/// Presents the phase-boundary alert as a blocking `NSAlert`. The app runs with `.accessory`
/// activation policy (no Dock icon), so without an explicit activate the alert can be drawn behind
/// whatever app currently has focus.
@MainActor
final class NSAlertPopupPresenter: PopupPresenting {
    func present(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }
}
