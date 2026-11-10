import ActivityKit
import Foundation
import TechPomodoroCore
import UIKit

/// Keeps one Live Activity — the lock screen and Dynamic Island countdown, iOS's analogue of the
/// menu bar item — in step with the timer.
///
/// The countdown inside it is `Text(timerInterval:)`, which the system renders with no help from the
/// app. A suspended app cannot update it at a boundary, so three things carry it across:
/// - `staleDate` is the end of the current phase, so the system draws it again right there, and the
///   widget moves on to the `nextPhase` the content carries (one boundary, with no help at all);
/// - it is started on this iPhone's own broadcast channel when a Mac has made one, and an awake Mac
///   that sees this iPhone's timer in CloudKit pushes every boundary on it;
/// - it snaps back to exact on the next foreground, on any of its own buttons (their intents run in
///   the app), or on tapping a notification.
@MainActor
final class LiveActivityController {
    private var activity: Activity<PomodoroActivityAttributes>?
    /// The last content pushed, so a refresh that changes nothing is not sent to the system.
    private var lastContent: PomodoroActivityAttributes.ContentState?
    /// The update or end in flight, chained so they reach the system in order.
    private var work: Task<Void, Never>?
    /// A channel the system refused to start an activity on; not tried again until it changes.
    private var refusedChannel: String?

    /// False when the user switched Live Activities off, or on an iPad that has none.
    private var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Brings the activity in line with `state`: starts one for a timer that has none, updates it,
    /// or ends it when the timer is idle. Adopts an activity left over from before a relaunch.
    ///
    /// `suppressed` while a Mac timer is mirrored: the Mac wins, so this iPhone's own activity steps
    /// aside and comes back when the Mac goes idle. Activities a Mac started are never touched here.
    ///
    /// `channelID` is this iPhone's own broadcast channel, when a Mac has made one. An activity started
    /// before it existed is replaced once, the next time the app is in the foreground, so the Macs'
    /// boundary pushes can reach it.
    func sync(with state: PomodoroState, at now: Date, suppressed: Bool = false, channelID: String? = nil) {
        if activity == nil {
            // Keep the first surviving activity, end any extras from an earlier crash.
            let existing = Activity<PomodoroActivityAttributes>.activities.filter { !$0.attributes.isMirror }
            activity = existing.first
            for extra in existing.dropFirst() {
                // `Activity` is not marked `Sendable`, though ActivityKit documents driving it from
                // tasks; each handle is only ever touched through this ordered queue.
                nonisolated(unsafe) let extra = extra
                enqueue { await extra.end(nil, dismissalPolicy: .immediate) }
            }
        }

        guard state.activity != .idle, !suppressed,
              let content = MirrorContentBuilder.content(for: state, at: now, primaryHex: Theme.primaryHex)
                  .map(PomodoroActivityAttributes.ContentState.init) else {
            end()
            return
        }

        if let current = activity, let channelID, current.attributes.ownChannel != channelID, channelID != refusedChannel,
           UIApplication.shared.applicationState == .active, isAvailable {
            // Only in the foreground, where a new one can be requested straight away.
            self.activity = nil
            nonisolated(unsafe) let replaced = current
            enqueue { await replaced.end(nil, dismissalPolicy: .immediate) }
        }

        guard content != lastContent || activity == nil else { return }
        lastContent = content
        let staleDate = state.activity == .running ? state.phaseEndsAt : nil
        let activityContent = ActivityContent(state: content, staleDate: staleDate)

        if let activity {
            nonisolated(unsafe) let activity = activity
            enqueue { await activity.update(activityContent) }
        } else if isAvailable {
            let channel = channelID == refusedChannel ? nil : channelID
            do {
                activity = try Activity.request(
                    attributes: PomodoroActivityAttributes(ownChannel: channel),
                    content: activityContent,
                    pushType: channel.map { .channel($0) }
                )
            } catch {
                guard let channel else { return }
                // The channel was refused; the timer still gets its activity, just without Mac pushes.
                NSLog("tech-pomodoro: could not start the Live Activity on channel \(channel): \(error.localizedDescription)")
                refusedChannel = channel
                activity = try? Activity.request(attributes: PomodoroActivityAttributes(), content: activityContent, pushType: nil)
            }
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
}
