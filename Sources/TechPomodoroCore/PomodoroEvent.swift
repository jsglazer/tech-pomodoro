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
    /// A refresh tick. Carries no time of its own — the reducer is handed `now` separately.
    case tick
    /// macOS is about to sleep.
    case willSleep
    /// macOS woke. Under `continueThroughSleep` this fast-forwards the schedule.
    case didWake
    case settingsChanged(PomodoroSettings)
}
