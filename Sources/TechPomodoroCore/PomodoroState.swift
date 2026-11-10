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

    /// True only while the timer is paused because the Mac went to sleep under `resumeOnWake`, so
    /// the wake resumes a sleep pause but never a pause the user made themselves.
    public var pausedBySleep: Bool

    public var settings: PomodoroSettings

    /// The paper tag, when the Work is paper time. Per device; cleared only by `clearPaperTag` or Stop.
    public var paperTag: PaperTag?
    /// Where the current Work *record* began. Usually `phaseStartedAt`; later when a paper tag change
    /// split the interval. Nil outside Work.
    public var workRecordStartedAt: Date?
    /// The closed stretches the current Work record has run (a pause ends one).
    public var workSpans: [DateInterval]
    /// Start of the stretch running now; nil while paused or outside Work.
    public var workSpanStartedAt: Date?
    /// Whole seconds of this Work phase already logged by earlier split records, so the pieces add up
    /// to exactly what one unsplit record would have logged.
    public var workSecondsRecorded: Int

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
        self.pausedBySleep = false
        self.settings = settings
        self.paperTag = nil
        self.workRecordStartedAt = nil
        self.workSpans = []
        self.workSpanStartedAt = nil
        self.workSecondsRecorded = 0
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

    /// True while a running or paused Work interval is tagged as paper time.
    public var isPaperWork: Bool {
        paperTag != nil && activity != .idle && phase == .work
    }

    /// The stretches of the current Work record up to `now`, the running one included.
    public func workSpans(at now: Date) -> [DateInterval] {
        guard let open = workSpanStartedAt, now > open else { return workSpans }
        return workSpans + [DateInterval(start: open, end: now)]
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
