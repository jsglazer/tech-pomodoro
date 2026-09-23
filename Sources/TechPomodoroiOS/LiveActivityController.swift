import ActivityKit
import Foundation
import TechPomodoroCore

/// Keeps one Live Activity — the lock screen and Dynamic Island countdown, iOS's analogue of the
/// menu bar item — in step with the timer.
///
/// The countdown inside it is `Text(timerInterval:)`, which the system renders with no help from the
/// app. What it cannot do is cross a boundary on its own: a suspended app cannot update it, and a
/// push-driven update needs an APNs sender this app does not have. So the content also lists the next
/// few boundaries, and `staleDate` marks it out of date at the end of the current phase rather than
/// letting it show a finished countdown as if it were current. It snaps back to exact on the next
/// foreground, on any of its own buttons (their intents run in the app), or on tapping a notification.
@MainActor
final class LiveActivityController {
    private var activity: Activity<PomodoroActivityAttributes>?
    /// The last content pushed, so a refresh that changes nothing is not sent to the system.
    private var lastContent: PomodoroActivityAttributes.ContentState?
    /// The update or end in flight, chained so they reach the system in order.
    private var work: Task<Void, Never>?

    /// False when the user switched Live Activities off, or on an iPad that has none.
    private var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Brings the activity in line with `state`: starts one for a timer that has none, updates it,
    /// or ends it when the timer is idle. Adopts an activity left over from before a relaunch.
    func sync(with state: PomodoroState, at now: Date) {
        if activity == nil {
            // Keep the first surviving activity, end any extras from an earlier crash.
            let existing = Activity<PomodoroActivityAttributes>.activities
            activity = existing.first
            for extra in existing.dropFirst() {
                // `Activity` is not marked `Sendable`, though ActivityKit documents driving it from
                // tasks; each handle is only ever touched through this ordered queue.
                nonisolated(unsafe) let extra = extra
                enqueue { await extra.end(nil, dismissalPolicy: .immediate) }
            }
        }

        guard state.activity != .idle else {
            end()
            return
        }

        let content = Self.content(for: state, at: now)
        guard content != lastContent || activity == nil else { return }
        lastContent = content
        let staleDate = state.activity == .running ? state.phaseEndsAt : nil
        let activityContent = ActivityContent(state: content, staleDate: staleDate)

        if let activity {
            nonisolated(unsafe) let activity = activity
            enqueue { await activity.update(activityContent) }
        } else if isAvailable {
            activity = try? Activity.request(
                attributes: PomodoroActivityAttributes(),
                content: activityContent,
                pushType: nil
            )
        }
    }

    private func end() {
        lastContent = nil
        guard let activity else { return }
        self.activity = nil
        nonisolated(unsafe) let ending = activity
        enqueue { await ending.end(nil, dismissalPolicy: .immediate) }
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = work
        work = Task {
            await previous?.value
            await operation()
        }
    }

    /// Returns once every queued update has reached the system.
    func settle() async {
        await work?.value
    }

    /// Flattens the core state into the plain values the extension draws.
    static func content(for state: PomodoroState, at now: Date) -> PomodoroActivityAttributes.ContentState {
        let settings = state.settings
        let isPaused = state.activity == .paused
        let remaining = state.remaining(at: now)
        // Paused, the end is where it would land if resumed this instant, so the bar holds its place.
        let end = isPaused ? now.addingTimeInterval(remaining) : (state.phaseEndsAt ?? now)
        // Measured back from the end rather than read from `phaseStartedAt`, which a pause does not
        // move: after a resume the bar must still span exactly one phase length.
        let start = end.addingTimeInterval(-state.phaseDuration)
        let upcoming = BoundaryPlanner.upcoming(from: state, now: now, limit: 3)
            .compactMap { boundary in
                boundary.nextPhase.map {
                    PomodoroActivityAttributes.UpcomingPhase(title: $0.title, startsAt: boundary.fireAt)
                }
            }
        let tint = settings.useRestColor && state.phase != .work ? settings.restColorHex : Theme.primaryHex

        return PomodoroActivityAttributes.ContentState(
            phaseTitle: state.phase.title,
            isPaused: isPaused,
            phaseStartedAt: start,
            phaseEndsAt: end,
            pausedRemaining: isPaused ? remaining : nil,
            progressLine: "Rep \(state.currentRep) of \(settings.repsPerCycle) · Cycle \(state.currentCycle) of \(settings.cyclesPerSession)",
            upcoming: upcoming,
            tintHex: tint
        )
    }
}
