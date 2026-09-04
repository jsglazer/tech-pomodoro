import Foundation
import Testing
@testable import TechPomodoroCore

@Suite("Pause, resume, and stop edge cases")
struct PauseStopTests {

    @Test("Clicking the countdown starts, pauses, then resumes")
    func toggleCyclesThroughActivities() {
        var state = PomodoroState(settings: Fixture.settings())

        state = PomodoroReducer.reduce(state, .toggleRunning, Fixture.start)
        #expect(state.activity == .running)

        state = PomodoroReducer.reduce(state, .toggleRunning, Fixture.start.plus(minutes: 1))
        #expect(state.activity == .paused)

        state = PomodoroReducer.reduce(state, .toggleRunning, Fixture.start.plus(minutes: 2))
        #expect(state.activity == .running)
        #expect(state.remaining(at: Fixture.start.plus(minutes: 2)) == 24 * 60)
    }

    @Test("Stop mid-work logs the partial interval it interrupted")
    func stopMidWorkLogsPartial() {
        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.stop, Fixture.start.plus(minutes: 7))
            ])

        #expect(state.activity == .idle)
        #expect(state.workRecords.count == 1)
        #expect(state.workRecords[0].elapsedSeconds == 7 * 60)
        #expect(state.workRecords[0].completed == false)
    }

    @Test("Stop during a rest or a break logs nothing")
    func stopDuringRestLogsNothing() {
        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.tick, Fixture.start.plus(minutes: 25)),
                (.stop, Fixture.start.plus(minutes: 27))
            ])

        #expect(state.activity == .idle)
        #expect(state.pendingRecords.isEmpty)
    }

    @Test("Stop while paused still logs the work already done")
    func stopWhilePausedLogsWork() {
        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.pause, Fixture.start.plus(minutes: 4)),
                (.stop, Fixture.start.plus(minutes: 30))
            ])

        #expect(state.activity == .idle)
        #expect(state.workRecords.count == 1)
        // Only the four minutes actually worked, not the time spent paused.
        #expect(state.workRecords[0].elapsedSeconds == 4 * 60)
    }

    @Test("Stop resets the whole hierarchy back to a fresh session")
    func stopResetsCounters() {
        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.tick, Fixture.start.plus(minutes: 110)),
                (.stop, Fixture.start.plus(minutes: 111))
            ])

        #expect(state.completedRepsInCycle == 0)
        #expect(state.completedCyclesInSession == 0)
        #expect(state.phase == .work)
        #expect(state.phaseEndsAt == nil)
    }

    @Test("Pausing exactly at the zero boundary holds at zero, and resuming expires on the next tick")
    func pauseAtZeroBoundary() {
        let boundary = Fixture.start.plus(minutes: 25)
        var state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.pause, boundary)
            ])

        #expect(state.remainingWhenPaused == 0)
        #expect(state.phase == .work)

        state = PomodoroReducer.reduce(state, .resume, boundary.plus(minutes: 5))
        state = PomodoroReducer.reduce(state, .tick, boundary.plus(minutes: 5))

        #expect(state.phase == .rest)
        #expect(state.workRecords.count == 1)
    }

    @Test("A tick landing exactly on the boundary completes the phase")
    func tickExactlyOnBoundaryCompletes() {
        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.tick, Fixture.start.plus(minutes: 25))
            ])

        #expect(state.phase == .rest)
    }

    @Test("A tick one second before the boundary does not")
    func tickBeforeBoundaryHolds() {
        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.tick, Fixture.start.plus(minutes: 25, seconds: -1))
            ])

        #expect(state.phase == .work)
        #expect(state.remaining(at: Fixture.start.plus(minutes: 25, seconds: -1)) == 1)
    }

    @Test("Pause, resume and stop are inert when idle")
    func idleIgnoresControls() {
        let idle = PomodoroState(settings: Fixture.settings())

        #expect(PomodoroReducer.reduce(idle, .pause, Fixture.start).activity == .idle)
        #expect(PomodoroReducer.reduce(idle, .resume, Fixture.start).activity == .idle)
        #expect(PomodoroReducer.reduce(idle, .stop, Fixture.start).pendingRecords.isEmpty)
    }

    @Test("A settings change mid-phase leaves the phase in flight at its original length")
    func settingsChangeDoesNotRetargetCurrentPhase() {
        var longer = Fixture.settings()
        longer.workMinutes = 50

        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.settingsChanged(longer), Fixture.start.plus(minutes: 5))
            ])

        #expect(state.phaseEndsAt == Fixture.start.plus(minutes: 25))
        // The new length applies from the next work phase onward.
        let next = PomodoroReducer.reduce(state, .tick, Fixture.start.plus(minutes: 30))
        #expect(next.phaseEndsAt == Fixture.start.plus(minutes: 80))
    }
}
