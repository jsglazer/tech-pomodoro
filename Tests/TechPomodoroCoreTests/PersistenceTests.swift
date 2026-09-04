import Foundation
import Testing
@testable import TechPomodoroCore

@Suite("Persistence and export")
struct PersistenceTests {

    /// Every test gets its own directory under the system temp dir, created and torn down here, so
    /// nothing ever touches the real Application Support history.
    private func withTemporaryStore(_ body: (FileIntervalStore) throws -> Void) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tech-pomodoro-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try body(FileIntervalStore(url: directory.appendingPathComponent("intervals.json")))
    }

    private func work(_ date: Date, minutes: Int, completed: Bool = true) -> IntervalRecord {
        IntervalRecord(kind: .work, startedAt: date, elapsedSeconds: minutes * 60, completed: completed)
    }

    @Test("Loading a store that has never been written returns an empty history")
    func loadMissingFile() throws {
        try withTemporaryStore { store in
            try #expect(store.load().isEmpty)
        }
    }

    @Test("Records survive a write/read roundtrip unchanged")
    func roundtrip() throws {
        try withTemporaryStore { store in
            let records = [work(Fixture.start, minutes: 25), work(Fixture.start.plus(minutes: 30), minutes: 7, completed: false)]
            try store.replace(with: records)

            let loaded = try store.load()
            #expect(loaded == records)
        }
    }

    @Test("Appending accumulates onto the existing history")
    func appendAccumulates() throws {
        try withTemporaryStore { store in
            try store.append([work(Fixture.start, minutes: 25)], now: Fixture.start, calendar: Fixture.calendar)
            try store.append([work(Fixture.start.plus(minutes: 30), minutes: 25)], now: Fixture.start.plus(minutes: 30), calendar: Fixture.calendar)

            try #expect(store.load().count == 2)
        }
    }

    @Test("Appending prunes anything past the retention horizon")
    func appendPrunes() throws {
        try withTemporaryStore { store in
            let day = 24.0 * 60
            try store.replace(with: [work(Fixture.start.plus(minutes: -40 * day), minutes: 25)])
            let written = try store.append([work(Fixture.start, minutes: 25)], now: Fixture.start, calendar: Fixture.calendar)

            #expect(written.count == 1)
            try #expect(store.load().count == 1)
        }
    }

    @Test("An empty append leaves the file untouched")
    func emptyAppendIsInert() throws {
        try withTemporaryStore { store in
            try store.replace(with: [work(Fixture.start, minutes: 25)])
            let written = try store.append([], now: Fixture.start, calendar: Fixture.calendar)

            #expect(written.count == 1)
        }
    }

    @Test("Settings roundtrip through an injected UserDefaults suite")
    func settingsRoundtrip() throws {
        let suiteName = "tech-pomodoro-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsSettingsStore(defaults: defaults)
        #expect(store.load() == PomodoroSettings())

        var settings = PomodoroSettings()
        settings.workMinutes = 50
        settings.soundName = "Submarine"
        settings.sleepBehavior = .pauseOnSleep
        store.save(settings)

        #expect(store.load() == settings)
    }

    @Test("A settings blob missing newer keys decodes onto the shipped defaults")
    func settingsDecodeIsForgiving() throws {
        let json = Data(#"{"workMinutes":42}"#.utf8)
        let decoded = try JSONDecoder().decode(PomodoroSettings.self, from: json)

        #expect(decoded.workMinutes == 42)
        #expect(decoded.restMinutes == PomodoroSettings().restMinutes)
        #expect(decoded.sleepBehavior == .continueThroughSleep)
    }

    @Test("The repeat counts and the custom colour survive a settings roundtrip")
    func repeatSettingsRoundtrip() throws {
        let suiteName = "tech-pomodoro-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings = PomodoroSettings()
        settings.dingRepeatCount = 4
        settings.flashRepeatCount = 6
        settings.useCustomTextColor = true
        settings.menuBarTextColorHex = "#FF8800"

        let store = UserDefaultsSettingsStore(defaults: defaults)
        store.save(settings)

        #expect(store.load() == settings)
    }

    @Test("Repeat counts are clamped to at least one")
    func repeatCountsClamped() {
        let settings = PomodoroSettings(dingRepeatCount: 0, flashRepeatCount: -3)

        #expect(settings.dingRepeatCount == 1)
        #expect(settings.flashRepeatCount == 1)
    }

    @Test("Shipped defaults are one ding and three flashes, with no custom colour")
    func repeatDefaults() {
        let settings = PomodoroSettings()

        #expect(settings.dingRepeatCount == 1)
        #expect(settings.flashRepeatCount == 3)
        #expect(settings.useCustomTextColor == false)
    }

    @Test("JSON export roundtrips losslessly")
    func jsonExportRoundtrip() throws {
        let records = [work(Fixture.start, minutes: 25), IntervalRecord(kind: .cycleCompleted, startedAt: Fixture.start.plus(minutes: 85), elapsedSeconds: 0, completed: true)]
        let data = try AnalyticsExporter.json(records: records)

        try #expect(AnalyticsExporter.records(fromJSON: data) == records)
    }

    @Test("CSV export writes a header and one row per record")
    func csvExportShape() {
        let records = [work(Fixture.start, minutes: 25), work(Fixture.start.plus(minutes: 30), minutes: 7, completed: false)]
        let lines = AnalyticsExporter.csv(records: records)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        #expect(lines.count == 3)
        #expect(lines[0] == AnalyticsExporter.csvHeader)
        #expect(lines[1].contains("work,"))
        #expect(lines[1].hasSuffix("1500,true"))
        #expect(lines[2].hasSuffix("420,false"))
    }

    @Test("An empty export is a header alone, not an error")
    func csvExportEmpty() {
        #expect(AnalyticsExporter.csv(records: []) == AnalyticsExporter.csvHeader + "\n")
    }
}
