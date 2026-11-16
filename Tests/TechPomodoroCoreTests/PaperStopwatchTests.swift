import Foundation
import Testing
@testable import TechPomodoroCore

@Suite("Paper: the stopwatch")
struct PaperStopwatchTests {
    let tag = PaperTag(className: "Data - POGO 511", kind: .read, note: "ch. 4")

    private func at(_ minutes: Double) -> Date { Fixture.start.plus(minutes: minutes) }

    @Test("Counts up from Track; a pause ends a stretch and the resume starts the next")
    func countsUpWithPauses() {
        var watch = PaperStopwatch(tag: tag, startedAt: at(0))
        #expect(watch.seconds(at: at(10)) == 600)
        watch.pause(at: at(10))
        #expect(!watch.isRunning)
        #expect(watch.seconds(at: at(30)) == 600)
        watch.resume(at: at(30))
        #expect(watch.seconds(at: at(35)) == 900)
        #expect(watch.spans(at: at(35)) == [DateInterval(start: at(0), end: at(10)), DateInterval(start: at(30), end: at(35))])
    }

    @Test("Stop saves a manual paper sitting: never a rep, no focus, the stretches as spans")
    func recordIsManualSitting() throws {
        var watch = PaperStopwatch(tag: tag, startedAt: at(0))
        watch.pause(at: at(20))
        watch.resume(at: at(25))
        let record = try #require(watch.record(at: at(40)))
        #expect(record.kind == .work)
        #expect(record.isManual)
        #expect(!record.completed)
        #expect(record.focus == nil)
        #expect(record.startedAt == at(0))
        #expect(record.elapsedSeconds == 35 * 60)
        #expect(record.paper?.className == "Data - POGO 511")
        #expect(record.paper?.note == "ch. 4")
        #expect(record.paper?.spans.count == 2)

        let sittings = PaperHistory.sittings(records: [record], corrections: [])
        #expect(sittings.first?.seconds == 35 * 60)
        #expect(sittings.first?.manual == true)
    }

    @Test("Nothing tracked saves nothing")
    func emptyRecordIsNil() {
        var watch = PaperStopwatch(tag: tag, startedAt: at(0))
        watch.pause(at: at(0))
        #expect(watch.record(at: at(5)) == nil)
    }

    @Test("Elapsed text: mm:ss under an hour, h:mm:ss from an hour")
    func elapsedText() {
        #expect(PaperStopwatch.elapsedText(725) == "12:05")
        #expect(PaperStopwatch.elapsedText(3725) == "1:02:05")
    }

    @Test("The store round-trips a stopwatch in progress and clears on nil")
    func storeRoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "PaperStopwatchTests-\(UUID().uuidString)"))
        let store = UserDefaultsPaperStopwatchStore(defaults: defaults)
        var watch = PaperStopwatch(tag: tag, startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        watch.pause(at: Date(timeIntervalSince1970: 1_800_000_600))
        store.save(watch)
        #expect(store.load() == watch)
        store.save(nil)
        #expect(store.load() == nil)
    }

    @Test("The menu bar shows the minutes tracked, red while paused")
    func menuBar() {
        var watch = PaperStopwatch(tag: tag, startedAt: at(0))
        let running = MenuBarFormatter.stopwatchPresentation(watch, at: at(12), settings: PomodoroSettings())
        #expect(running.text == "12m")
        #expect(running.symbolName == "stopwatch")
        watch.pause(at: at(75))
        let paused = MenuBarFormatter.stopwatchPresentation(watch, at: at(80), settings: PomodoroSettings())
        #expect(paused.text == "1:15")
        #expect(paused.foreground == .alert)
    }
}
