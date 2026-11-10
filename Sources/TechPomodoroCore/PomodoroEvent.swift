import Foundation

/// Everything that can move the timer. The shell translates clicks, its refresh timer, and
/// `NSWorkspace` sleep/wake notifications into these; the reducer sees nothing else.
public enum PomodoroEvent: Sendable, Equatable {
    case start
    case pause
    case resume
    /// Clicking the countdown numbers: start when idle, pause when running, resume when paused.
    case toggleRunning
    case stop
    /// Ends the current phase now and moves straight on to the next one, running.
    case skip
    /// A refresh tick. Carries no time of its own — the reducer is handed `now` separately.
    case tick
    /// macOS is about to sleep.
    case willSleep
    /// macOS woke. Under `continueThroughSleep` this fast-forwards the schedule.
    case didWake
    case settingsChanged(PomodoroSettings)
    /// Tags the Work that follows (and the Work in progress) as paper time. Sticky: it survives every
    /// phase boundary, pause and sleep, and is cleared only by `clearPaperTag` or `stop`.
    case setPaperTag(PaperTag)
    case clearPaperTag
}
