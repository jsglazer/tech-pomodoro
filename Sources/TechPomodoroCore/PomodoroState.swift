import Foundation

/// Something the shell must do as a result of a reduction. The core never plays a sound or touches a
/// status item itself; it only says that an alert is due.
public enum PomodoroEffect: Sendable, Equatable {
    case alert(AlertKind)
}

/// Which boundary an alert marks. The shell maps these onto the ding and the menu bar flash.
public enum AlertKind: String, Sendable, Equatable {
    /// A work or rest interval ended and the next one began.
    case intervalEnd
    /// A cycle's reps are exhausted and the Long Break began.
    case cycleEnd
    /// A session's cycles are exhausted and the Session Rest began.
    case sessionEnd
    /// The whole schedule finished and the timer returned to idle.
    case sessionComplete
}

/// The entire timer, as one `Sendable` value.
///
/// Remaining time is never stored as a decrementing counter: while running, the only truth is
/// `phaseEndsAt`, an absolute wall-clock instant, and remaining time is always derived from it
/// against a supplied `now`.
public struct PomodoroState: Sendable, Equatable {
    public enum Activity: String, Sendable, Equatable {
        case idle
        case running
        case paused
    }

    public var activity: Activity
    public var phase: Phase
    /// The wall-clock instant the current phase ends. Non-nil only while running.
    public var phaseEndsAt: Date?
    /// Frozen remaining seconds. Non-nil only while paused.
    public var remainingWhenPaused: TimeInterval?
    /// When the current phase began, used as the start stamp of the work record it produces.
    public var phaseStartedAt: Date?
    /// The current phase's length, captured when it began, so a mid-phase settings change cannot
    /// retroactively change how much of it counts as elapsed.
    public var phaseDuration: TimeInterval

    public var completedRepsInCycle: Int
    public var completedCyclesInSession: Int
    public var completedSessions: Int

    public var settings: PomodoroSettings

    /// Effects produced by the most recent reduction only. Each reduction replaces them, so they
    /// never accumulate and the shell cannot replay a stale alert.
    public var pendingEffects: [PomodoroEffect]
    /// Records produced by the most recent reduction only, for the shell to hand to the store.
    public var pendingRecords: [IntervalRecord]

    public init(settings: PomodoroSettings = PomodoroSettings()) {
        self.activity = .idle
        self.phase = .work
        self.phaseEndsAt = nil
        self.remainingWhenPaused = nil
        self.phaseStartedAt = nil
        self.phaseDuration = settings.duration(of: .work)
        self.completedRepsInCycle = 0
        self.completedCyclesInSession = 0
        self.completedSessions = 0
        self.settings = settings
        self.pendingEffects = []
        self.pendingRecords = []
    }

    /// Seconds left in the current phase at `now`. Zero when idle.
    public func remaining(at now: Date) -> TimeInterval {
        switch activity {
        case .idle:
            return 0
        case .running:
            guard let end = phaseEndsAt else { return 0 }
            return max(0, end.timeIntervalSince(now))
        case .paused:
            return max(0, remainingWhenPaused ?? 0)
        }
    }

    /// Seconds of the current phase already spent at `now`.
    public func elapsedInPhase(at now: Date) -> TimeInterval {
        guard activity != .idle else { return 0 }
        return max(0, phaseDuration - remaining(at: now))
    }

    /// `0...1` through the current phase, for the popover's progress ring.
    public func progress(at now: Date) -> Double {
        guard phaseDuration > 0, activity != .idle else { return 0 }
        return min(1, max(0, elapsedInPhase(at: now) / phaseDuration))
    }

    /// The rep number being worked, 1-based, for the popover's "Rep 2 of 3" line.
    public var currentRep: Int {
        min(completedRepsInCycle + 1, max(1, settings.repsPerCycle))
    }

    /// The cycle number in progress, 1-based.
    public var currentCycle: Int {
        min(completedCyclesInSession + 1, max(1, settings.cyclesPerSession))
    }
}
