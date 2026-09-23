import Foundation
import Testing
@testable import TechPomodoroCore

@Suite("Skipping the current phase")
struct SkipTests {

    @Test("Skip while idle does nothing")
    func skipWhileIdle() {
        let state = PomodoroReducer.reduce(PomodoroState(settings: Fixture.settings()), .skip, Fixture.start)

        #expect(state.activity == .idle)
        #expect(state.pendingRecords.isEmpty)
    }

    @Test("Skipping work starts the rest now and logs only the partial work done")
    func skipWorkLogsPartial() {
        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.skip, Fixture.start.plus(minutes: 10))
            ])

        #expect(state.activity == .running)
        #expect(state.phase == .rest)
        #expect(state.completedRepsInCycle == 1)
        #expect(state.phaseEndsAt == Fixture.start.plus(minutes: 15))
        #expect(state.workRecords.count == 1)
        #expect(state.workRecords[0].elapsedSeconds == 10 * 60)
        #expect(state.workRecords[0].completed == false)
        #expect(state.alerts.isEmpty)
    }

    @Test("Skipping a rest starts the next work interval now")
    func skipRest() {
        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.tick, Fixture.start.plus(minutes: 25)),
                (.skip, Fixture.start.plus(minutes: 26))
            ])

        #expect(state.phase == .work)
        #expect(state.phaseEndsAt == Fixture.start.plus(minutes: 51))
        #expect(state.pendingRecords.isEmpty)
    }

    @Test("Skipping while paused moves on and runs the next phase")
    func skipWhilePaused() {
        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.pause, Fixture.start.plus(minutes: 5)),
                (.skip, Fixture.start.plus(minutes: 20))
            ])

        #expect(state.activity == .running)
        #expect(state.phase == .rest)
        #expect(state.remainingWhenPaused == nil)
        #expect(state.phaseEndsAt == Fixture.start.plus(minutes: 25))
        #expect(state.workRecords.count == 1)
        #expect(state.workRecords[0].elapsedSeconds == 5 * 60)
    }

    @Test("Skipping the last work of a cycle reaches the long break and counts the cycle")
    func skipIntoLongBreak() {
        var state = PomodoroState(settings: Fixture.settings(reps: 1))
            .applying([(.start, Fixture.start)])
        state = PomodoroReducer.reduce(state, .skip, Fixture.start.plus(minutes: 1))

        #expect(state.phase == .longBreak)
        #expect(state.cycleRecords.count == 1)
    }

    @Test("Skipping the session rest without repeat ends the session")
    func skipSessionRestGoesIdle() {
        var state = PomodoroState(settings: Fixture.settings(reps: 1, cycles: 1))
            .applying([(.start, Fixture.start)])
        for minute in 1...3 {
            state = PomodoroReducer.reduce(state, .skip, Fixture.start.plus(minutes: Double(minute)))
        }

        #expect(state.activity == .idle)
        #expect(state.completedSessions == 1)
    }
}
