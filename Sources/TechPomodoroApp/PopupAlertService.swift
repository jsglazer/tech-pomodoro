import AppKit
import TechPomodoroCore

/// Presents the phase-boundary alert as a blocking `NSAlert`. The app runs with `.accessory`
/// activation policy (no Dock icon), so without an explicit activate the alert can be drawn behind
/// whatever app currently has focus.
///
/// With a time limit, a timer scheduled in the modal panel run loop mode — the only mode
/// `runModal()` services — ends the modal session unanswered, so a boundary alert nobody is at the
/// desk to click cannot sit on screen indefinitely.
@MainActor
final class NSAlertPopupPresenter: PopupPresenting {
    func present(title: String, message: String, dismissAfter: TimeInterval?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational

        var timeout: Timer?
        if let dismissAfter, dismissAfter > 0 {
            let timer = Timer(timeInterval: dismissAfter, repeats: false) { _ in
                MainActor.assumeIsolated { NSApp.stopModal(withCode: .abort) }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            timeout = timer
        }
        alert.runModal()
        timeout?.invalidate()
    }
}
