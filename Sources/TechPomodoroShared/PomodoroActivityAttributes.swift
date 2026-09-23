import ActivityKit
import Foundation

/// The Live Activity's data, compiled into both the iOS app (which starts and updates the activity)
/// and the widget extension (which draws it). Deliberately free of `TechPomodoroCore` types: the app
/// flattens the state into plain values here, so the extension never links the core.
struct PomodoroActivityAttributes: ActivityAttributes {

    struct ContentState: Codable, Hashable, Sendable {
        /// "Work", "Rest", "Long Break", "Session Rest".
        var phaseTitle: String
        var isPaused: Bool
        /// When the current phase began and ends, for the live `Text(timerInterval:)` countdown and
        /// the progress bar. While paused, `phaseEndsAt` is the end the phase would have if resumed
        /// now; the view shows `pausedRemaining` instead of counting.
        var phaseStartedAt: Date
        var phaseEndsAt: Date
        var pausedRemaining: TimeInterval?
        /// "Rep 2 of 3 · Cycle 1 of 4".
        var progressLine: String
        /// The next few boundaries, so the lock screen can say what comes next even after the current
        /// countdown has run out while the app is suspended and cannot update the activity.
        var upcoming: [UpcomingPhase]
        /// `#RRGGBB` accent for this phase: the rest colour during rest phases when enabled, else cyan.
        var tintHex: String
    }

    struct UpcomingPhase: Codable, Hashable, Sendable {
        var title: String
        var startsAt: Date
    }
}

/// What a Live Activity button asks the app to do.
enum PomodoroIntentAction: String, Sendable {
    case toggleRunning
    case stop
    case skip
}
