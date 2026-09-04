import Foundation
import Testing
@testable import TechPomodoroCore

@Suite("Menu bar formatting and threshold colours")
struct MenuBarFormatterTests {

    private func running(remainingMinutes: Double, phase: Phase = .work, settings: PomodoroSettings = Fixture.settings()) -> (PomodoroState, Date) {
        var state = PomodoroState(settings: settings)
        state = PomodoroReducer.reduce(state, .start, Fixture.start)
        if phase != .work {
            state.phase = phase
            state.phaseDuration = settings.duration(of: phase)
        }
        state.phaseEndsAt = Fixture.start.plus(minutes: remainingMinutes)
        return (state, Fixture.start)
    }

    @Test("Idle shows the dimmed clock symbol, never a countdown")
    func idlePresentation() {
        let presentation = MenuBarFormatter.presentation(for: PomodoroState(), at: Fixture.start)

        #expect(presentation.text == nil)
        #expect(presentation.symbolName == "timer")
        #expect(presentation.foreground == .dimmedText)
    }

    @Test("Minutes round up, so the final minute reads 1 and only the last second reads 0")
    func minutesRoundUp() {
        #expect(MenuBarFormatter.minutesText(25 * 60) == "25")
        #expect(MenuBarFormatter.minutesText(24 * 60 + 1) == "25")
        #expect(MenuBarFormatter.minutesText(60) == "1")
        #expect(MenuBarFormatter.minutesText(1) == "1")
        #expect(MenuBarFormatter.minutesText(0) == "0")
    }

    @Test("Above both thresholds Work is the primary colour")
    func aboveThresholds() {
        let (state, now) = running(remainingMinutes: 6)
        #expect(MenuBarFormatter.presentation(for: state, at: now).foreground == .primaryText)
    }

    @Test("Exactly at the warning threshold Work turns warning")
    func atWarningThreshold() {
        let (state, now) = running(remainingMinutes: 5)
        #expect(MenuBarFormatter.presentation(for: state, at: now).foreground == .warning)
    }

    @Test("Exactly at the alert threshold Work turns alert")
    func atAlertThreshold() {
        let (state, now) = running(remainingMinutes: 3)
        #expect(MenuBarFormatter.presentation(for: state, at: now).foreground == .alert)
    }

    @Test("One second inside the alert threshold is still alert")
    func insideAlertThreshold() {
        let (state, now) = running(remainingMinutes: 3)
        let later = now.plus(seconds: 1)
        #expect(MenuBarFormatter.presentation(for: state, at: later).foreground == .alert)
    }

    @Test("Rest and breaks never take a threshold colour")
    func thresholdsAreWorkOnly() {
        for phase in [Phase.rest, .longBreak, .sessionRest] {
            let (state, now) = running(remainingMinutes: 1, phase: phase)
            #expect(MenuBarFormatter.presentation(for: state, at: now).foreground == .primaryText)
        }
    }

    @Test("Clock-icon mode ignores the thresholds entirely")
    func clockModeIgnoresThresholds() {
        var settings = Fixture.settings()
        settings.menuBarMode = .clockIcon
        let (state, now) = running(remainingMinutes: 1, settings: settings)
        let presentation = MenuBarFormatter.presentation(for: state, at: now)

        #expect(presentation.text == nil)
        #expect(presentation.symbolName == "timer")
        #expect(presentation.foreground == .primaryText)
    }

    @Test("A threshold of zero disables that step")
    func zeroThresholdDisabled() {
        var settings = Fixture.settings()
        settings.alertThresholdMinutes = 0
        let (state, now) = running(remainingMinutes: 2, settings: settings)
        #expect(MenuBarFormatter.presentation(for: state, at: now).foreground == .warning)

        settings.warningThresholdMinutes = 0
        let (plain, plainNow) = running(remainingMinutes: 2, settings: settings)
        #expect(MenuBarFormatter.presentation(for: plain, at: plainNow).foreground == .primaryText)
    }

    @Test("The background token appears only when a custom background is enabled")
    func backgroundIsOptIn() {
        var settings = Fixture.settings()
        let (plain, now) = running(remainingMinutes: 10, settings: settings)
        #expect(MenuBarFormatter.presentation(for: plain, at: now).background == nil)

        settings.useCustomBackground = true
        let (filled, filledNow) = running(remainingMinutes: 10, settings: settings)
        #expect(MenuBarFormatter.presentation(for: filled, at: filledNow).background == .background)
    }
}
