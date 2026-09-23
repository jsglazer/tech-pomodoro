import Foundation
import TechPomodoroCore
import UserNotifications

/// Hands every upcoming phase boundary to iOS as a local notification, so alerts arrive on time with
/// the app suspended or killed and no background execution at all.
///
/// The plan is always rebuilt whole: every pending request is withdrawn and the current chain from
/// `BoundaryPlanner` scheduled in its place. The controller calls `replan` after any reduction that
/// moves a boundary — start, pause, resume, stop, skip, a settings change — and whenever the app
/// becomes active, which also slides the 60-request / 24-hour window forward under `repeatSession`.
@MainActor
final class NotificationScheduler {
    nonisolated static let categoryIdentifier = "tech-pomodoro.boundary"
    private static let identifierPrefix = "tech-pomodoro.boundary."

    enum Authorization: Equatable {
        case notDetermined
        case denied
        case authorized
    }

    private let center = UNUserNotificationCenter.current()
    private(set) var authorization: Authorization = .notDetermined
    /// Serialises plans so an older one can never land after a newer one.
    private var planTask: Task<Void, Never>?

    /// Asks for permission the first time the user starts a timer, rather than at launch, so the
    /// prompt arrives with an obvious reason. `.timeSensitive` delivery rides on the entitlement.
    func requestAuthorizationIfNeeded() async {
        await refreshAuthorization()
        guard authorization == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await refreshAuthorization()
    }

    func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: authorization = .notDetermined
        case .denied: authorization = .denied
        default: authorization = .authorized
        }
    }

    /// Replaces every pending boundary notification with the plan for `state`.
    ///
    /// Triggers are relative intervals, so they are measured from the clock at the moment of adding
    /// rather than from when `replan` was called; queued behind an earlier plan they would otherwise
    /// fire late by however long that plan took.
    func replan(for state: PomodoroState) {
        let previous = planTask
        planTask = Task { [center] in
            await previous?.value
            let requests = Self.requests(for: state, at: Date())
            let pending = await center.pendingNotificationRequests()
                .map(\.identifier)
                .filter { $0.hasPrefix(Self.identifierPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: pending)
            for request in requests {
                try? await center.add(request)
            }
        }
    }

    /// Returns once the most recent plan has been handed to the system.
    func settle() async {
        await planTask?.value
    }

    /// Withdraws every pending boundary notification, e.g. on Stop.
    func cancelAll() {
        replan(for: PomodoroState())
    }

    // MARK: - Building requests

    /// Pure apart from reading the bundle for the sound file, so it is simple to reason about: one
    /// request per boundary the planner returns, each firing at the boundary's own instant.
    static func requests(for state: PomodoroState, at now: Date) -> [UNNotificationRequest] {
        let settings = state.settings
        return BoundaryPlanner.upcoming(from: state, now: now).map { boundary in
            let content = UNMutableNotificationContent()
            let text = Self.text(for: boundary)
            content.title = text.title
            content.body = text.body
            content.categoryIdentifier = categoryIdentifier
            content.interruptionLevel = .timeSensitive
            content.threadIdentifier = "tech-pomodoro"
            if settings.dingEnabled {
                // A notification sound plays once; `dingRepeatCount` applies to in-app playback only.
                let file = BundledSoundCatalog.notificationFileName(for: settings.soundName)
                content.sound = UNNotificationSound(named: UNNotificationSoundName(file))
            }
            let interval = max(1, boundary.fireAt.timeIntervalSince(now))
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let identifier = identifierPrefix + String(Int(boundary.fireAt.timeIntervalSince1970))
            return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        }
    }

    /// The same wording the Mac's alert dialog uses, naming what is starting rather than what ended.
    static func text(for boundary: PhaseBoundary) -> (title: String, body: String) {
        switch boundary.kind {
        case .intervalEnd, .cycleEnd, .sessionEnd:
            let phase = boundary.nextPhase?.title ?? "The next phase"
            let until = boundary.nextPhaseEndsAt.map { " Until \($0.formatted(date: .omitted, time: .shortened))." } ?? ""
            return ("Time's up", "\(phase) is starting.\(until)")
        case .sessionComplete:
            return ("Session complete", "The full schedule has finished.")
        }
    }
}
