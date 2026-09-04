import Foundation
import Testing
@testable import TechPomodoroCore

@Suite("Multi-tier interval transitions")
struct TransitionTests {

    @Test("Start begins a work phase ending one work length later")
    func startBeginsWork() {
        let state = PomodoroState(settings: Fixture.settings())
            .applying([(.start, Fixture.start)])

        #expect(state.activity == .running)
        #expect(state.phase == .work)
        #expect(state.phaseEndsAt == Fixture.start.plus(minutes: 25))
        #expect(state.remaining(at: Fixture.start) == 25 * 60)
    }

    @Test("Work ends into Rest, and logs a completed work interval")
    func workEndsIntoRest() {
        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.tick, Fixture.start.plus(minutes: 25))
            ])

        #expect(state.phase == .rest)
        #expect(state.completedRepsInCycle == 1)
        #expect(state.alerts == [.intervalEnd])
        #expect(state.workRecords.count == 1)
        #expect(state.workRecords[0].elapsedSeconds == 25 * 60)
        #expect(state.workRecords[0].completed)
        #expect(state.workRecords[0].startedAt == Fixture.start)
    }

    @Test("Rest ends back into Work without logging anything")
    func restEndsIntoWork() {
        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.tick, Fixture.start.plus(minutes: 30))
            ])

        #expect(state.phase == .work)
        #expect(state.completedRepsInCycle == 1)
        #expect(state.phaseEndsAt == Fixture.start.plus(minutes: 55))
    }

    @Test("The last rep of a cycle ends into the Long Break and logs the cycle")
    func repsExhaustIntoLongBreak() {
        // 3 reps of 25+5: the third work block ends 85 minutes in.
        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.tick, Fixture.start.plus(minutes: 85))
            ])

        #expect(state.phase == .longBreak)
        #expect(state.completedRepsInCycle == 3)
        #expect(state.alerts == [.cycleEnd])
        #expect(state.cycleRecords.count == 1)
        #expect(state.phaseEndsAt == Fixture.start.plus(minutes: 100))
    }

    @Test("A cycle's Long Break ends into the next cycle's first Work")
    func longBreakEndsIntoNextCycle() {
        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.tick, Fixture.start.plus(minutes: 100))
            ])

        #expect(state.phase == .work)
        #expect(state.completedCyclesInSession == 1)
        #expect(state.completedRepsInCycle == 0)
        #expect(state.alerts == [.intervalEnd])
    }

    @Test("The last cycle of a session ends into Session Rest")
    func cyclesExhaustIntoSessionRest() {
        // One cycle is 100 minutes (3x(25+5) + 15 break wait: 85 work/rest + 15 break).
        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.tick, Fixture.start.plus(minutes: 200))
            ])

        #expect(state.phase == .sessionRest)
        #expect(state.completedCyclesInSession == 2)
        #expect(state.alerts == [.sessionEnd])
        #expect(state.phaseEndsAt == Fixture.start.plus(minutes: 260))
    }

    @Test("Reaching the Session Rest logs the completed session")
    func sessionRestLogsTheSession() {
        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.tick, Fixture.start.plus(minutes: 200))
            ])

        #expect(state.pendingRecords.filter { $0.kind == .sessionCompleted }.count == 1)
    }

    @Test("A non-repeating session finishes into idle with one completion alert")
    func sessionRestEndsIntoIdle() {
        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.tick, Fixture.start.plus(minutes: 260))
            ])

        #expect(state.activity == .idle)
        #expect(state.completedSessions == 1)
        #expect(state.alerts == [.sessionComplete])
        #expect(state.phaseEndsAt == nil)
    }

    @Test("A repeating session rolls straight into the next session's first Work")
    func repeatingSessionRolls() {
        let state = PomodoroState(settings: Fixture.settings(repeatSession: true))
            .applying([
                (.start, Fixture.start),
                (.tick, Fixture.start.plus(minutes: 260))
            ])

        #expect(state.activity == .running)
        #expect(state.phase == .work)
        #expect(state.completedSessions == 1)
        #expect(state.completedCyclesInSession == 0)
        #expect(state.phaseEndsAt == Fixture.start.plus(minutes: 285))
    }

    @Test("Every work interval of a full session is logged exactly once")
    func fullSessionLogsEveryInterval() {
        var state = PomodoroState(settings: Fixture.settings())
        state = PomodoroReducer.reduce(state, .start, Fixture.start)

        var work = 0
        var cycles = 0
        // Tick once a minute through the whole session rather than in one jump.
        for minute in 1...260 {
            state = PomodoroReducer.reduce(state, .tick, Fixture.start.plus(minutes: Double(minute)))
            work += state.workRecords.count
            cycles += state.cycleRecords.count
        }

        #expect(work == 6)      // 3 reps x 2 cycles
        #expect(cycles == 2)
        #expect(state.activity == .idle)
    }
}
