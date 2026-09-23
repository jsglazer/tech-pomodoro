import Foundation
import Testing
@testable import TechPomodoroCore

@Suite("Boundary planner for pre-scheduled alerts")
struct BoundaryPlannerTests {

    private func started(_ settings: PomodoroSettings = Fixture.settings()) -> PomodoroState {
        PomodoroState(settings: settings).applying([(.start, Fixture.start)])
    }

    @Test("A full schedule is laid out boundary by boundary, ending in sessionComplete")
    func fullChain() {
        let plan = BoundaryPlanner.upcoming(from: started(), now: Fixture.start)

        // 25/5 × 3 reps, 15m long break, 2 cycles, 60m session rest: each cycle closes with its long
        // break, and the second long break's end is what opens the session rest.
        #expect(plan.map(\.fireAt) == [25, 30, 55, 60, 85, 100, 125, 130, 155, 160, 185, 200, 260].map {
            Fixture.start.plus(minutes: Double($0))
        })
        #expect(plan.map(\.kind) == [
            .intervalEnd, .intervalEnd, .intervalEnd, .intervalEnd, .cycleEnd, .intervalEnd,
            .intervalEnd, .intervalEnd, .intervalEnd, .intervalEnd, .cycleEnd, .sessionEnd, .sessionComplete
        ])
        #expect(plan.map(\.nextPhase) == [
            .rest, .work, .rest, .work, .longBreak, .work,
            .rest, .work, .rest, .work, .longBreak, .sessionRest, nil
        ])
    }

    @Test("Each boundary knows when the phase it begins will end")
    func nextPhaseEnds() {
        let plan = BoundaryPlanner.upcoming(from: started(), now: Fixture.start)

        #expect(plan[0].nextPhaseEndsAt == Fixture.start.plus(minutes: 30))
        #expect(plan[4].nextPhaseEndsAt == Fixture.start.plus(minutes: 100))
        #expect(plan.last?.nextPhaseEndsAt == nil)
        // Every boundary but the last is followed by the next one at exactly that instant.
        for (boundary, following) in zip(plan, plan.dropFirst()) {
            #expect(boundary.nextPhaseEndsAt == following.fireAt)
        }
    }

    @Test("Paused and idle timers have nothing to schedule")
    func pausedAndIdle() {
        let idle = PomodoroState(settings: Fixture.settings())
        let paused = started().applying([(.pause, Fixture.start.plus(minutes: 3))])

        #expect(BoundaryPlanner.upcoming(from: idle, now: Fixture.start).isEmpty)
        #expect(BoundaryPlanner.upcoming(from: paused, now: Fixture.start.plus(minutes: 4)).isEmpty)
    }

    @Test("Resuming shifts every boundary by the time spent paused")
    func resumeShifts() {
        let resumed = started().applying([
            (.pause, Fixture.start.plus(minutes: 10)),
            (.resume, Fixture.start.plus(minutes: 17))
        ])
        let plan = BoundaryPlanner.upcoming(from: resumed, now: Fixture.start.plus(minutes: 17))

        #expect(plan.first?.fireAt == Fixture.start.plus(minutes: 32))
        #expect(plan.last?.fireAt == Fixture.start.plus(minutes: 267))
    }

    @Test("repeatSession is capped by the limit rather than running forever")
    func repeatCappedByLimit() {
        let plan = BoundaryPlanner.upcoming(
            from: started(Fixture.settings(repeatSession: true)),
            now: Fixture.start,
            limit: 60,
            horizon: .greatestFiniteMagnitude
        )

        #expect(plan.count == 60)
        #expect(!plan.contains { $0.kind == .sessionComplete })
        // The session rest hands straight back to work instead of going idle.
        #expect(plan[12].kind == .intervalEnd)
        #expect(plan[12].nextPhase == .work)
    }

    @Test("The horizon stops the plan even under the limit")
    func horizonCaps() {
        let plan = BoundaryPlanner.upcoming(
            from: started(Fixture.settings(repeatSession: true)),
            now: Fixture.start,
            horizon: 60 * 60
        )

        #expect(plan.map(\.fireAt) == [25, 30, 55, 60].map { Fixture.start.plus(minutes: Double($0)) })
    }

    @Test("The default plan fits under iOS's 64 pending-notification cap")
    func defaultsFitUnderCap() {
        let plan = BoundaryPlanner.upcoming(
            from: started(Fixture.settings(work: 1, rest: 1, reps: 1, longBreak: 1, cycles: 1, sessionRest: 1, repeatSession: true)),
            now: Fixture.start
        )

        #expect(plan.count == BoundaryPlanner.defaultLimit)
        #expect(plan.count < 64)
    }

    @Test("A mid-phase settings change moves only the boundaries after the current one")
    func settingsChangeMidPhase() {
        let changed = started().applying([
            (.settingsChanged(Fixture.settings(rest: 10)), Fixture.start.plus(minutes: 5))
        ])
        let plan = BoundaryPlanner.upcoming(from: changed, now: Fixture.start.plus(minutes: 5))

        // The work phase in flight keeps its 25 minutes; the rest after it is now 10.
        #expect(plan[0].fireAt == Fixture.start.plus(minutes: 25))
        #expect(plan[1].fireAt == Fixture.start.plus(minutes: 35))
    }

    @Test("Boundaries already behind now are walked through, not scheduled")
    func staleStateSkipsPast() {
        // The shell has not reduced since the start; the clock is now inside the first rest.
        let plan = BoundaryPlanner.upcoming(from: started(), now: Fixture.start.plus(minutes: 27))

        #expect(plan.first?.fireAt == Fixture.start.plus(minutes: 30))
        #expect(plan.first?.nextPhase == .work)
    }

    @Test("Planning never mutates the state it is handed")
    func pure() {
        let state = started()
        _ = BoundaryPlanner.upcoming(from: state, now: Fixture.start)

        #expect(state == started())
    }
}
