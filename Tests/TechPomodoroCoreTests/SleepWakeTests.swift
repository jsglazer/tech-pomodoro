import Foundation
import Testing
@testable import TechPomodoroCore

@Suite("Sleep, wake, and clock jumps")
struct SleepWakeTests {

    @Test("Waking mid-work leaves the same phase with time correctly consumed")
    func wakeInsideTheSamePhase() {
        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.willSleep, Fixture.start.plus(minutes: 5)),
                (.didWake, Fixture.start.plus(minutes: 15))
            ])

        #expect(state.activity == .running)
        #expect(state.phase == .work)
        #expect(state.remaining(at: Fixture.start.plus(minutes: 15)) == 10 * 60)
    }

    @Test("A long sleep fast-forwards to exactly the phase the wall clock implies")
    func longSleepFastForwards() {
        let wake = Fixture.start.plus(minutes: 200)
        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.willSleep, Fixture.start.plus(minutes: 3)),
                (.didWake, wake)
            ])

        // Identical to having ticked every second through those 200 minutes.
        #expect(state.phase == .sessionRest)
        #expect(state.completedCyclesInSession == 2)
        #expect(state.phaseEndsAt == Fixture.start.plus(minutes: 260))
    }

    @Test("A backlog of missed boundaries produces exactly one catch-up alert")
    func atMostOneCatchUpAlert() {
        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.didWake, Fixture.start.plus(minutes: 200))
            ])

        #expect(state.alerts.count == 1)
        #expect(state.alerts == [.sessionEnd])
    }

    @Test("Records for every phase crossed during the sleep are still kept")
    func catchUpKeepsEveryRecord() {
        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.didWake, Fixture.start.plus(minutes: 200))
            ])

        #expect(state.workRecords.count == 6)
        #expect(state.cycleRecords.count == 2)
    }

    @Test("pauseOnSleep freezes the timer and the wake does not resume it")
    func pauseOnSleepFreezes() {
        var settings = Fixture.settings()
        settings.sleepBehavior = .pauseOnSleep

        let state = PomodoroState(settings: settings)
            .applying([
                (.start, Fixture.start),
                (.willSleep, Fixture.start.plus(minutes: 10)),
                (.didWake, Fixture.start.plus(minutes: 400))
            ])

        #expect(state.activity == .paused)
        #expect(state.phase == .work)
        #expect(state.remaining(at: Fixture.start.plus(minutes: 400)) == 15 * 60)
    }

    @Test("Time spent paused is never counted against the phase")
    func pausedTimeDoesNotElapse() {
        let resumeAt = Fixture.start.plus(minutes: 90)
        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.pause, Fixture.start.plus(minutes: 10)),
                (.resume, resumeAt)
            ])

        #expect(state.phase == .work)
        #expect(state.phaseEndsAt == resumeAt.plus(minutes: 15))
        #expect(state.remaining(at: resumeAt) == 15 * 60)
    }

    @Test("Ticking while paused changes nothing")
    func tickWhilePausedIsInert() {
        let paused = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.pause, Fixture.start.plus(minutes: 10))
            ])
        let ticked = PomodoroReducer.reduce(paused, .tick, Fixture.start.plus(minutes: 400))

        #expect(ticked.activity == .paused)
        #expect(ticked.remainingWhenPaused == paused.remainingWhenPaused)
        #expect(ticked.pendingEffects.isEmpty)
    }

    @Test("Fast-forwarding is identical whether ticked once or once a minute")
    func fastForwardMatchesSteadyTicking() {
        var stepwise = PomodoroState(settings: Fixture.settings())
        stepwise = PomodoroReducer.reduce(stepwise, .start, Fixture.start)
        for minute in 1...150 {
            stepwise = PomodoroReducer.reduce(stepwise, .tick, Fixture.start.plus(minutes: Double(minute)))
        }

        let jumped = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.tick, Fixture.start.plus(minutes: 150))
            ])

        #expect(stepwise.phase == jumped.phase)
        #expect(stepwise.phaseEndsAt == jumped.phaseEndsAt)
        #expect(stepwise.completedRepsInCycle == jumped.completedRepsInCycle)
        #expect(stepwise.completedCyclesInSession == jumped.completedCyclesInSession)
    }
}
