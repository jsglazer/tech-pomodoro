import ActivityKit
import Foundation

/// The Live Activity's data, compiled into both the iOS app (which starts and updates the activity)
/// and the widget extension (which draws it). Deliberately free of `TechPomodoroCore` types: the app
/// flattens the state into plain values here, so the extension never links the core.
///
/// The same JSON shape is what a Mac pushes (`MirrorContent` in the core): renaming a field here
/// breaks mirroring unless it is renamed there too.
struct PomodoroActivityAttributes: ActivityAttributes {

    /// `"mac"` on an activity a Mac started by push to mirror its timer; nil on the iPhone's own. The
    /// app never updates or ends a mirrored activity as if it were its own, and its buttons are hidden
    /// because they could not control the Mac.
    var mirrorSource: String?

    var isMirror: Bool { mirrorSource != nil }

    /// On the iPhone's own activity: the broadcast channel it was started on, over which an awake Mac
    /// pushes the phase boundaries this suspended app cannot. Nil when started before a Mac made one.
    var ownChannel: String?

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
        /// The Mac being mirrored; nil for the iPhone's own timer.
        var mirroredFrom: String?
        /// The phase after this one, so the activity can count it down by itself once this countdown
        /// has run out and nothing has updated it. Nil while paused or when the session ends here.
        var nextPhase: NextPhase?
        /// The paper tag of tagged Work — class folder name and kind (`Read`…). Optional, so content
        /// from an older build still decodes. Same keys as `MirrorContent`.
        var paperClass: String?
        var paperKind: String?

        /// `Data - POGO 511 · Read`, or nil outside paper Work.
        var paperLine: String? {
            guard let paperClass, phaseTitle == "Work" else { return nil }
            return paperKind.map { "\(paperClass) · \($0)" } ?? paperClass
        }
    }

    struct NextPhase: Codable, Hashable, Sendable {
        var title: String
        var startsAt: Date
        var endsAt: Date
        var progressLine: String
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
