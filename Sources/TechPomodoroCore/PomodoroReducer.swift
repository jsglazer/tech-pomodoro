import Foundation

/// The timer's whole behaviour, as one pure function of `(State, Event, Date)`.
///
/// No AppKit, no SwiftUI, no `Timer`, no `Task.sleep`, no reads of the system clock: every instant
/// the reducer uses arrives as the `now` parameter, which is what makes sleep/wake, pause/resume and
/// the multi-tier transitions testable by advancing an injected date.
public enum PomodoroReducer {

    /// Guards the fast-forward loop. A wake after a very long sleep still terminates; the bound is
    /// far above any plausible number of intervals in a real absence.
    private static let maxCatchUpSteps = 100_000

    public static func reduce(_ state: PomodoroState, _ event: PomodoroEvent, _ now: Date) -> PomodoroState {
        var s = state
        // Effects and records describe this reduction only.
        s.pendingEffects = []
        s.pendingRecords = []

        // Any event other than the sleep/wake pair or a tick means the user (or a settings change)
        // has taken over, so a pending sleep-pause is no longer the sleep's to undo.
        switch event {
        case .willSleep, .didWake, .tick, .setPaperTag, .clearPaperTag: break
        default: s.pausedBySleep = false
        }

        switch event {
        case .start:
            guard s.activity == .idle else { return s }
            startSession(&s, at: now)

        case .resume:
            resume(&s, at: now)

        case .pause:
            pause(&s, at: now)

        case .toggleRunning:
            switch s.activity {
            case .idle: startSession(&s, at: now)
            case .running: pause(&s, at: now)
            case .paused: resume(&s, at: now)
            }

        case .stop:
            stop(&s, at: now)

        case .skip:
            skip(&s, at: now)

        case .tick:
            advance(&s, to: now)

        case .willSleep:
            switch s.settings.sleepBehavior {
            case .continueThroughSleep:
                break
            case .pauseOnSleep:
                pause(&s, at: now)
            case .resumeOnWake:
                // Catch any boundary that fell due a moment before sleep first, so the frozen
                // remainder belongs to the phase the clock is really in.
                advance(&s, to: now)
                if s.activity == .running {
                    pause(&s, at: now)
                    s.pausedBySleep = true
                }
            }

        case .didWake:
            // Under `continueThroughSleep` the schedule catches up to the wall clock. Under
            // `pauseOnSleep` the timer was already frozen by `.willSleep` and stays that way. Under
            // `resumeOnWake` a timer the sleep froze picks up where it left off.
            switch s.settings.sleepBehavior {
            case .continueThroughSleep:
                advance(&s, to: now)
            case .pauseOnSleep:
                break
            case .resumeOnWake:
                if s.pausedBySleep {
                    s.pausedBySleep = false
                    resume(&s, at: now)
                } else {
                    // Never slept through `.willSleep` (or it arrived late): don't leave a running
                    // timer stale on screen.
                    advance(&s, to: now)
                }
            }

        case .setPaperTag(let tag):
            setPaperTag(&s, tag, at: now)

        case .clearPaperTag:
            setPaperTag(&s, nil, at: now)

        case .settingsChanged(let newSettings):
            // The phase in flight keeps the length it started with; the new durations take effect
            // from the next phase boundary.
            s.settings = newSettings
            if s.activity == .idle {
                s.phaseDuration = newSettings.duration(of: s.phase)
            }
        }

        return s
    }

    // MARK: - Transitions

    private static func startSession(_ s: inout PomodoroState, at now: Date) {
        s.completedRepsInCycle = 0
        s.completedCyclesInSession = 0
        s.completedSessions = 0
        begin(&s, phase: .work, at: now)
    }

    private static func begin(_ s: inout PomodoroState, phase: Phase, at start: Date) {
        s.phase = phase
        s.phaseStartedAt = start
        s.phaseDuration = s.settings.duration(of: phase)
        s.phaseEndsAt = start.addingTimeInterval(s.phaseDuration)
        s.remainingWhenPaused = nil
        s.activity = .running
        clearWorkRecord(&s)
        if phase == .work {
            s.workRecordStartedAt = start
            s.workSpanStartedAt = start
        }
    }

    private static func pause(_ s: inout PomodoroState, at now: Date) {
        guard s.activity == .running else { return }
        s.remainingWhenPaused = s.remaining(at: now)
        s.phaseEndsAt = nil
        s.activity = .paused
        // A pause ends the running stretch of a Work record.
        if let open = s.workSpanStartedAt {
            if now > open { s.workSpans.append(DateInterval(start: open, end: now)) }
            s.workSpanStartedAt = nil
        }
    }

    private static func resume(_ s: inout PomodoroState, at now: Date) {
        guard s.activity == .paused else { return }
        // Resuming re-derives an absolute end instant from the frozen remainder; time spent paused
        // is simply never counted.
        s.phaseEndsAt = now.addingTimeInterval(s.remainingWhenPaused ?? 0)
        s.remainingWhenPaused = nil
        s.activity = .running
        if s.phase == .work, s.workRecordStartedAt != nil { s.workSpanStartedAt = now }
    }

    private static func stop(_ s: inout PomodoroState, at now: Date) {
        // Stop clears the paper tag, idle or not.
        defer { s.paperTag = nil }
        guard s.activity != .idle else { return }
        // A work interval cut short is still time worked: it is logged as a partial record. Stopping
        // during a rest or a break records nothing.
        if s.phase == .work, let partial = closeWorkRecord(&s, at: now, phaseElapsed: s.elapsedInPhase(at: now), completed: false) {
            s.pendingRecords.append(partial)
        }
        goIdle(&s)
    }

    /// Sets, changes or clears the paper tag. During Work (running or paused) a change of class or
    /// kind — or setting or clearing the tag — closes the stretch so far as its own Work record, under
    /// the tag it ran with, and carries on as a new record; only the record that reaches the end of
    /// the phase is `completed`, so reps and work time count exactly as without the split. A change
    /// of note alone is the same sitting and never splits. Outside Work it only sets the tag.
    private static func setPaperTag(_ s: inout PomodoroState, _ tag: PaperTag?, at now: Date) {
        let old = s.paperTag
        guard old != tag else { return }
        let sameSitting = tag.map { $0.sameSitting(as: old) } ?? false
        if s.activity != .idle, s.phase == .work, !sameSitting {
            if let piece = closeWorkRecord(&s, at: now, phaseElapsed: s.elapsedInPhase(at: now), completed: false) {
                s.pendingRecords.append(piece)
            }
            s.workRecordStartedAt = now
            s.workSpans = []
            s.workSpanStartedAt = s.activity == .running ? now : nil
        }
        s.paperTag = tag
    }

    /// The record of the current Work stretch, ending at `end`, where `phaseElapsed` is how much of
    /// the phase has run by then. Only the part not already logged by an earlier split counts. A
    /// partial record with nothing in it is nil; a completed one is always returned, so the rep counts.
    private static func closeWorkRecord(
        _ s: inout PomodoroState,
        at end: Date,
        phaseElapsed: TimeInterval,
        completed: Bool
    ) -> IntervalRecord? {
        guard let started = s.workRecordStartedAt ?? s.phaseStartedAt else { return nil }
        let total = Int(phaseElapsed.rounded())
        let elapsed = max(0, total - s.workSecondsRecorded)
        let spans = s.workSpans(at: end)
        s.workSecondsRecorded = max(s.workSecondsRecorded, total)
        guard completed || elapsed > 0 else { return nil }
        return IntervalRecord(
            kind: .work,
            startedAt: started,
            elapsedSeconds: elapsed,
            completed: completed,
            paper: s.paperTag.map { PaperSitting(tag: $0, spans: spans) }
        )
    }

    private static func clearWorkRecord(_ s: inout PomodoroState) {
        s.workRecordStartedAt = nil
        s.workSpans = []
        s.workSpanStartedAt = nil
        s.workSecondsRecorded = 0
    }

    /// Cuts the current phase short and begins the next one at `now`, running even if the skipped
    /// phase was paused. The counters advance exactly as if the phase had ended on its own, but a
    /// skipped work interval is logged as the partial time actually worked, never as a full one, and
    /// no alert fires — the user asked for the change, so there is nothing to announce.
    private static func skip(_ s: inout PomodoroState, at now: Date) {
        guard s.activity != .idle else { return }
        let skippedPhase = s.phase
        let partial = skippedPhase == .work
            ? closeWorkRecord(&s, at: now, phaseElapsed: s.elapsedInPhase(at: now), completed: false)
            : nil

        // Paused, the end instant is gone; running, it is in the future. Either way the phase ends now.
        s.phaseEndsAt = now
        s.remainingWhenPaused = nil
        s.activity = .running

        var records: [IntervalRecord] = []
        var discardedAlert: AlertKind?
        completePhase(&s, endingAt: now, records: &records, alert: &discardedAlert)

        if skippedPhase == .work {
            records.removeAll { $0.kind == .work }
            if let partial { records.insert(partial, at: 0) }
        }
        s.pendingRecords = records
    }

    private static func goIdle(_ s: inout PomodoroState) {
        s.activity = .idle
        s.phase = .work
        s.phaseEndsAt = nil
        s.remainingWhenPaused = nil
        s.phaseStartedAt = nil
        s.phaseDuration = s.settings.duration(of: .work)
        s.completedRepsInCycle = 0
        s.completedCyclesInSession = 0
        clearWorkRecord(&s)
    }

    /// Fast-forwards through every phase whose end instant has already passed at `now`.
    ///
    /// Each phase is chained from the previous phase's *end*, never from `now`, so a wake after two
    /// hours lands on exactly the phase the wall clock implies with no accumulated drift. Records for
    /// every phase crossed are kept, but only the last alert survives: waking to a backlog produces
    /// one catch-up ding, not a burst of them.
    private static func advance(_ s: inout PomodoroState, to now: Date) {
        guard s.activity == .running else { return }

        var records: [IntervalRecord] = []
        var lastAlert: AlertKind?
        var steps = 0

        while s.activity == .running, let end = s.phaseEndsAt, now >= end, steps < maxCatchUpSteps {
            steps += 1
            completePhase(&s, endingAt: end, records: &records, alert: &lastAlert)
        }

        s.pendingRecords = records
        s.pendingEffects = lastAlert.map { [.alert($0)] } ?? []
    }

    private static func completePhase(
        _ s: inout PomodoroState,
        endingAt end: Date,
        records: inout [IntervalRecord],
        alert: inout AlertKind?
    ) {
        let settings = s.settings

        switch s.phase {
        case .work:
            if let record = closeWorkRecord(&s, at: end, phaseElapsed: s.phaseDuration, completed: true) {
                records.append(record)
            }
            s.completedRepsInCycle += 1
            if s.completedRepsInCycle >= max(1, settings.repsPerCycle) {
                // The cycle reached its Long Break, which is what makes it count in the analytics.
                records.append(
                    IntervalRecord(kind: .cycleCompleted, startedAt: end, elapsedSeconds: 0, completed: true)
                )
                alert = .cycleEnd
                begin(&s, phase: .longBreak, at: end)
            } else {
                alert = .intervalEnd
                begin(&s, phase: .rest, at: end)
            }

        case .rest:
            alert = .intervalEnd
            begin(&s, phase: .work, at: end)

        case .longBreak:
            s.completedRepsInCycle = 0
            s.completedCyclesInSession += 1
            if s.completedCyclesInSession >= max(1, settings.cyclesPerSession) {
                // The session reached its Session Rest, which is what makes it count.
                records.append(
                    IntervalRecord(kind: .sessionCompleted, startedAt: end, elapsedSeconds: 0, completed: true)
                )
                alert = .sessionEnd
                begin(&s, phase: .sessionRest, at: end)
            } else {
                alert = .intervalEnd
                begin(&s, phase: .work, at: end)
            }

        case .sessionRest:
            s.completedSessions += 1
            s.completedCyclesInSession = 0
            s.completedRepsInCycle = 0
            if settings.repeatSession {
                alert = .intervalEnd
                begin(&s, phase: .work, at: end)
            } else {
                let finished = s.completedSessions
                alert = .sessionComplete
                goIdle(&s)
                s.completedSessions = finished
            }
        }
    }
}
