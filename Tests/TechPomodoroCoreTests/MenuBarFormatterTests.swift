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

    @Test("Idle and ordinary countdowns let macOS colour them, so they match the rest of the bar")
    func neutralStatesAdapt() {
        #expect(MenuBarFormatter.presentation(for: PomodoroState(), at: Fixture.start).adaptsToMenuBar)

        let (active, now) = running(remainingMinutes: 20)
        #expect(MenuBarFormatter.presentation(for: active, at: now).adaptsToMenuBar)

        var clockMode = Fixture.settings()
        clockMode.menuBarMode = .clockIcon
        let (icon, iconNow) = running(remainingMinutes: 1, settings: clockMode)
        #expect(MenuBarFormatter.presentation(for: icon, at: iconNow).adaptsToMenuBar)
    }

    @Test("A threshold colour overrides the menu bar's own colour — that is the point of it")
    func thresholdsDoNotAdapt() {
        for minutes in [5.0, 3.0, 1.0] {
            let (state, now) = running(remainingMinutes: minutes)
            #expect(MenuBarFormatter.presentation(for: state, at: now).adaptsToMenuBar == false)
        }
    }

    @Test("A filled background takes the colour into our own hands")
    func customBackgroundDoesNotAdapt() {
        var settings = Fixture.settings()
        settings.useCustomBackground = true
        let (state, now) = running(remainingMinutes: 20, settings: settings)
        #expect(MenuBarFormatter.presentation(for: state, at: now).adaptsToMenuBar == false)
    }

    @Test("A custom text colour replaces the ordinary countdown colour")
    func customTextColourApplies() {
        var settings = Fixture.settings()
        settings.useCustomTextColor = true
        settings.menuBarTextColorHex = "#FF8800"

        let (state, now) = running(remainingMinutes: 20, settings: settings)
        let presentation = MenuBarFormatter.presentation(for: state, at: now)

        #expect(presentation.customForegroundHex == "#FF8800")
        #expect(presentation.adaptsToMenuBar == false)
    }

    @Test("A threshold colour still wins over the custom text colour")
    func thresholdBeatsCustomColour() {
        var settings = Fixture.settings()
        settings.useCustomTextColor = true
        settings.menuBarTextColorHex = "#FF8800"

        let (state, now) = running(remainingMinutes: 2, settings: settings)
        let presentation = MenuBarFormatter.presentation(for: state, at: now)

        #expect(presentation.customForegroundHex == nil)
        #expect(presentation.foreground == .alert)
    }

    @Test("The custom colour tints the clock icon too")
    func customColourAppliesInIconMode() {
        var settings = Fixture.settings()
        settings.menuBarMode = .clockIcon
        settings.useCustomTextColor = true
        settings.menuBarTextColorHex = "#FF8800"

        let (state, now) = running(remainingMinutes: 20, settings: settings)
        #expect(MenuBarFormatter.presentation(for: state, at: now).customForegroundHex == "#FF8800")
    }

    @Test("Hover text names the phase and the exact time left, zero-padded")
    func hoverTextWhileRunning() {
        let state = PomodoroState(settings: Fixture.settings())
            .applying([(.start, Fixture.start)])

        #expect(MenuBarFormatter.hoverText(for: state, at: Fixture.start) == "Work 25:00")
        #expect(MenuBarFormatter.hoverText(for: state, at: Fixture.start.plus(minutes: 20, seconds: 51)) == "Work 04:09")
        #expect(MenuBarFormatter.hoverText(for: state, at: Fixture.start.plus(minutes: 24, seconds: 55)) == "Work 00:05")
    }

    @Test("Hover text names the rest phases too")
    func hoverTextDuringRest() {
        let state = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.tick, Fixture.start.plus(minutes: 25))
            ])

        #expect(MenuBarFormatter.hoverText(for: state, at: Fixture.start.plus(minutes: 27)) == "Rest 03:00")
    }

    @Test("Hover text says Ready when idle and marks a pause")
    func hoverTextIdleAndPaused() {
        #expect(MenuBarFormatter.hoverText(for: PomodoroState(), at: Fixture.start) == "tech-pomodoro — Ready")

        let paused = PomodoroState(settings: Fixture.settings())
            .applying([
                (.start, Fixture.start),
                (.pause, Fixture.start.plus(minutes: 10))
            ])
        #expect(MenuBarFormatter.hoverText(for: paused, at: Fixture.start.plus(minutes: 45)) == "Paused — Work 15:00")
    }

    @Test("Hover info splits the phase from the countdown for the larger readout")
    func hoverInfoParts() {
        let state = PomodoroState(settings: Fixture.settings())
            .applying([(.start, Fixture.start)])

        let running = MenuBarFormatter.hoverInfo(for: state, at: Fixture.start.plus(minutes: 20, seconds: 51))
        #expect(running.title == "Work")
        #expect(running.detail == "04:09")

        let idle = MenuBarFormatter.hoverInfo(for: PomodoroState(), at: Fixture.start)
        #expect(idle.title == "Ready")
        #expect(idle.detail == "--:--")

        let paused = state.applying([(.pause, Fixture.start.plus(minutes: 10))])
        let pausedInfo = MenuBarFormatter.hoverInfo(for: paused, at: Fixture.start.plus(minutes: 90))
        #expect(pausedInfo.title == "Paused — Work")
        #expect(pausedInfo.detail == "15:00")
    }

    @Test("The rest phases take the rest colour, Work does not")
    func restColourAppliesToRestPhases() {
        var settings = Fixture.settings()
        settings.restColorHex = "#22C55E"

        for phase in [Phase.rest, .longBreak, .sessionRest] {
            let (state, now) = running(remainingMinutes: 4, phase: phase, settings: settings)
            #expect(MenuBarFormatter.presentation(for: state, at: now).customForegroundHex == "#22C55E")
        }

        let (work, workNow) = running(remainingMinutes: 20, settings: settings)
        #expect(MenuBarFormatter.presentation(for: work, at: workNow).customForegroundHex == nil)
    }

    @Test("Turning the rest colour off hands the rest phases back to the menu bar")
    func restColourCanBeDisabled() {
        var settings = Fixture.settings()
        settings.useRestColor = false

        let (state, now) = running(remainingMinutes: 4, phase: .rest, settings: settings)
        let presentation = MenuBarFormatter.presentation(for: state, at: now)

        #expect(presentation.customForegroundHex == nil)
        #expect(presentation.adaptsToMenuBar)
    }

    @Test("The rest colour outranks the general custom text colour")
    func restColourBeatsCustomColour() {
        var settings = Fixture.settings()
        settings.useCustomTextColor = true
        settings.menuBarTextColorHex = "#FF8800"
        settings.restColorHex = "#22C55E"

        let (rest, restNow) = running(remainingMinutes: 4, phase: .rest, settings: settings)
        #expect(MenuBarFormatter.presentation(for: rest, at: restNow).customForegroundHex == "#22C55E")

        let (work, workNow) = running(remainingMinutes: 20, settings: settings)
        #expect(MenuBarFormatter.presentation(for: work, at: workNow).customForegroundHex == "#FF8800")
    }

    @Test("Green rest colouring is on out of the box")
    func restColourDefaults() {
        let settings = PomodoroSettings()

        #expect(settings.useRestColor)
        #expect(settings.restColorHex == "#22C55E")
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
