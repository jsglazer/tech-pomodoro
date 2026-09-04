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

        case .tick:
            advance(&s, to: now)

        case .willSleep:
            if s.settings.sleepBehavior == .pauseOnSleep {
                pause(&s, at: now)
            }

        case .didWake:
            // Under `continueThroughSleep` the schedule catches up to the wall clock. Under
            // `pauseOnSleep` the timer was already frozen by `.willSleep` and stays that way.
            if s.settings.sleepBehavior == .continueThroughSleep {
                advance(&s, to: now)
            }

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
    }

    private static func pause(_ s: inout PomodoroState, at now: Date) {
        guard s.activity == .running else { return }
        s.remainingWhenPaused = s.remaining(at: now)
        s.phaseEndsAt = nil
        s.activity = .paused
    }

    private static func resume(_ s: inout PomodoroState, at now: Date) {
        guard s.activity == .paused else { return }
        // Resuming re-derives an absolute end instant from the frozen remainder; time spent paused
        // is simply never counted.
        s.phaseEndsAt = now.addingTimeInterval(s.remainingWhenPaused ?? 0)
        s.remainingWhenPaused = nil
        s.activity = .running
    }

    private static func stop(_ s: inout PomodoroState, at now: Date) {
        guard s.activity != .idle else { return }
        // A work interval cut short is still time worked: it is logged as a partial record. Stopping
        // during a rest or a break records nothing.
        if s.phase == .work, let started = s.phaseStartedAt {
            let elapsed = Int(s.elapsedInPhase(at: now).rounded())
            if elapsed > 0 {
                s.pendingRecords.append(
                    IntervalRecord(kind: .work, startedAt: started, elapsedSeconds: elapsed, completed: false)
                )
            }
        }
        goIdle(&s)
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
            if let started = s.phaseStartedAt {
                records.append(
                    IntervalRecord(
                        kind: .work,
                        startedAt: started,
                        elapsedSeconds: Int(s.phaseDuration.rounded()),
                        completed: true
                    )
                )
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
