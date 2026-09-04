import Foundation
import ServiceManagement
import TechPomodoroCore

/// Launch-at-login via `SMAppService`.
///
/// `SMAppService` only works for an app running from a registered bundle; from a bare SwiftPM binary
/// or an unregistered development build it throws. This degrades to a no-op with a warning the
/// settings pane can show, and never crashes the app.
struct SMAppServiceLoginItem: LoginItemControlling {

    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> LoginItemResult {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return LoginItemResult(isEnabled: SMAppService.mainApp.status == .enabled, warning: nil)
        } catch {
            return LoginItemResult(
                isEnabled: false,
                warning: "Launch at login is unavailable for this build — run TechPomodoro.app from /Applications."
            )
        }
    }
}
