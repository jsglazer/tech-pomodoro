import SwiftUI
import TechPomodoroCore
import UserNotifications

@main
struct TechPomodoroiOSApp: App {
    @StateObject private var controller = PomodoroController.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView(controller: controller)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: controller.sceneDidBecomeActive()
            case .background: controller.sceneDidEnterBackground()
            default: break
            }
        }
    }
}

/// Decides how a boundary notification is shown when it fires with the app open.
///
/// Open, the controller's own tick has already played the ding (and shown the dialog, if enabled), so
/// the notification is swallowed — otherwise each boundary would sound twice. In the background it is
/// the only alert, and iOS presents it normally without consulting this delegate.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        notification.request.content.categoryIdentifier == NotificationScheduler.categoryIdentifier ? [] : [.banner, .sound]
    }
}

/// The app's half of the Live Activity buttons: the intents in `TechPomodoroShared` call this, and it
/// runs in the app's process even when the system launched that process just to perform the intent.
enum PomodoroIntentHandler {
    @MainActor
    static func handle(_ action: PomodoroIntentAction) async {
        let controller = PomodoroController.shared
        switch action {
        case .toggleRunning: controller.send(.toggleRunning)
        case .stop: controller.send(.stop)
        case .skip: controller.send(.skip)
        }
        // Do not return — and let the process be suspended — before the new notification plan and the
        // Live Activity update have reached the system.
        await controller.settle()
    }
}
