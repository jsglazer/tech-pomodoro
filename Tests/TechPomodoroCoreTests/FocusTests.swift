import Foundation
import Testing
@testable import TechPomodoroCore

private let assignment = "/Classes/2026-B/RD - POGO 801/Assign/Asgn03-TheoryHypotheses/TheoryHypo.md"
private let inventory = "/Classes/2026-B/Econ - PUBP 720/Inventory/2.4 Elasticities.md"
private let pogoInventory = "/Classes/2026-B/RD - POGO 801/Inventory/Validity.md"

private func at(_ seconds: Double) -> Date { Fixture.start.plus(seconds: seconds) }

private func window(_ from: Double, _ to: Double, _ app: String, url: String? = nil, title: String = "") -> WindowSpan {
    WindowSpan(start: at(from), end: at(to), app: app, title: title, url: url)
}

private func note(_ from: Double, _ to: Double, _ file: String) -> NoteSpan {
    NoteSpan(start: at(from), end: at(to), file: file)
}

@Suite("Focus: project rules")
struct FocusRuleTests {
    let settings = FocusSettings()

    @Test("An assignment note maps to its class and its assignment folder")
    func assignmentFolder() {
        let p = FocusRules.project(forFile: assignment, settings: settings)
        #expect(p.area == "Classes/2026-B/RD - POGO 801")
        #expect(p.task == "Classes/2026-B/RD - POGO 801/Assign/Asgn03-TheoryHypotheses")
        #expect(p.displayName == "RD - POGO 801 › Asgn03-TheoryHypotheses")
    }

    @Test("An Inventory note's task is the Inventory folder")
    func inventoryFolder() {
        let p = FocusRules.project(forFile: inventory, settings: settings)
        #expect(p.task == "Classes/2026-B/Econ - PUBP 720/Inventory")
        #expect(p.taskName == "Inventory")
    }

    @Test("A note directly in the class folder has the class as its task")
    func noteInClassRoot() {
        let p = FocusRules.project(forFile: "/Classes/2026-B/Econ - PUBP 720/Syllabus.md", settings: settings)
        #expect(p.task == p.area)
        #expect(p.displayName == "Econ - PUBP 720")
    }

    @Test("A note outside every rule falls back to its top-level folder")
    func unruledNote() {
        let p = FocusRules.project(forFile: "/Daily/2026-10-30.md", settings: settings)
        #expect(p.area == "Daily")
        #expect(p.task == "Daily")
    }

    @Test("Globs match inside a segment and ignore case")
    func wildcards() {
        #expect(FocusRules.wildcard("Asgn*", matches: "asgn03-TheoryHypotheses"))
        #expect(FocusRules.wildcard("RD - ????", matches: "RD - POGO"))
        #expect(!FocusRules.wildcard("Asgn*", matches: "Inventory"))
    }

    @Test("At class level a project's task collapses to its area")
    func areaLevel() {
        let p = FocusRules.project(forFile: assignment, settings: settings).at(.area)
        #expect(p.task == "Classes/2026-B/RD - POGO 801")
    }
}

@Suite("Focus: what counts")
struct FocusClassifierTests {
    let settings = FocusSettings()

    @Test("Anki and Zotero count toward the project")
    func onTaskApps() {
        #expect(FocusClassifier.category(window: window(0, 1, "Anki"), note: nil, settings: settings) == .support("Anki"))
        #expect(FocusClassifier.category(window: window(0, 1, "Zotero"), note: nil, settings: settings) == .support("Zotero"))
    }

    @Test("A PDF in the browser counts toward the project")
    func pdfInBrowser() {
        let w = window(0, 1, "Google Chrome", url: "https://example.org/papers/king1994.pdf")
        #expect(FocusClassifier.category(window: w, note: nil, settings: settings) == .support("PDF"))
    }

    @Test("The GMU library and Schar sites count, subdomains included")
    func allowedSites() {
        let library = window(0, 1, "Google Chrome", url: "https://library.gmu.edu/databases")
        let schar = window(0, 1, "Google Chrome", url: "https://www.schar.gmu.edu/students")
        #expect(FocusClassifier.category(window: library, note: nil, settings: settings) == .support("library.gmu.edu"))
        #expect(FocusClassifier.category(window: schar, note: nil, settings: settings) == .support("www.schar.gmu.edu"))
    }

    @Test("Any other site is a distraction labelled by host")
    func otherSites() {
        let w = window(0, 1, "Google Chrome", url: "https://www.youtube.com/watch?v=x")
        #expect(FocusClassifier.category(window: w, note: nil, settings: settings) == .distraction("Google Chrome (www.youtube.com)"))
        // Look-alike hosts do not ride on an allowed one.
        let fake = window(0, 1, "Google Chrome", url: "https://notlibrary.gmu.edu.evil.com/")
        #expect(FocusClassifier.category(window: fake, note: nil, settings: settings) != .support("notlibrary.gmu.edu.evil.com"))
    }

    @Test("A path prefix on an allowed site limits it")
    func sitePathPrefix() {
        #expect(FocusClassifier.isAllowed(url: "https://canvas.gmu.edu/courses/86506/modules", sites: ["canvas.gmu.edu/courses/86506"]))
        #expect(!FocusClassifier.isAllowed(url: "https://canvas.gmu.edu/courses/99999", sites: ["canvas.gmu.edu/courses/86506"]))
        #expect(FocusClassifier.isAllowed(url: "https://library.gmu.edu/", sites: ["https://library.gmu.edu/"]))
    }

    @Test("Other apps are distractions; the lock screen and this app are neutral")
    func appsAndNeutral() {
        #expect(FocusClassifier.category(window: window(0, 1, "Signal"), note: nil, settings: settings) == .distraction("Signal"))
        #expect(FocusClassifier.category(window: window(0, 1, "loginwindow"), note: nil, settings: settings) == .neutral)
        #expect(FocusClassifier.category(window: window(0, 1, "TechPomodoro"), note: nil, settings: settings) == .neutral)
    }

    @Test("Obsidian takes its project from the open note")
    func obsidian() {
        let category = FocusClassifier.category(window: window(0, 1, "Obsidian"), note: note(0, 1, inventory), settings: settings)
        #expect(category == .project(FocusRules.project(forFile: inventory, settings: settings)))
        #expect(FocusClassifier.category(window: window(0, 1, "Obsidian"), note: nil, settings: settings) == .neutral)
    }
}

@Suite("Focus: tracking an interval")
struct FocusTrackerTests {
    let settings = FocusSettings()
    var asgn: FocusProject { FocusRules.project(forFile: assignment, settings: settings) }
    var econ: FocusProject { FocusRules.project(forFile: inventory, settings: settings) }

    @Test("The anchor is the leading project of the opening window, and locks when it ends")
    func anchorInference() {
        let activity = FocusActivity(
            windows: [window(0, 400, "Obsidian")],
            notes: [note(0, 60, inventory), note(60, 400, assignment)]
        )
        let early = FocusTracker.snapshot(activity: activity, from: at(0), to: at(150), settings: settings)
        #expect(early.anchor == asgn)
        #expect(!early.anchorIsLocked)

        let later = FocusTracker.snapshot(activity: activity, from: at(0), to: at(400), settings: settings)
        #expect(later.anchor == asgn)
        #expect(later.anchorIsLocked)
        #expect(later.switches == 1)
    }

    @Test("Before the anchor locks, another project is not drift — a distraction is")
    func driftBeforeLock() {
        let projects = FocusActivity(
            windows: [window(0, 120, "Obsidian")],
            notes: [note(0, 60, assignment), note(60, 120, inventory)]
        )
        // Tied at 60 s each: whichever leads, moving between projects this early is not drift.
        #expect(FocusTracker.snapshot(activity: projects, from: at(0), to: at(110), settings: settings).offAnchorSeconds == 0)

        let youtube = FocusActivity(
            windows: [window(0, 60, "Obsidian"), window(60, 100, "Google Chrome", url: "https://youtube.com/")],
            notes: [note(0, 60, assignment)]
        )
        let snapshot = FocusTracker.snapshot(activity: youtube, from: at(0), to: at(100), settings: settings)
        #expect(snapshot.offAnchorSeconds == 40)
        #expect(snapshot.isDrifting)
    }

    @Test("After the lock, time on another task is drift, and Anki is not")
    func driftAfterLock() {
        let activity = FocusActivity(
            windows: [window(0, 360, "Obsidian"), window(360, 380, "Anki"), window(380, 420, "Obsidian")],
            notes: [note(0, 360, assignment), note(380, 420, inventory)]
        )
        let snapshot = FocusTracker.snapshot(activity: activity, from: at(0), to: at(420), settings: settings)
        #expect(snapshot.anchor == asgn)
        #expect(snapshot.offAnchorSeconds == 40)
        #expect(snapshot.supportSeconds == 20)
        #expect(snapshot.current == .project(econ))
    }

    @Test("At class level, another task in the same class is not drift")
    func areaLevelDrift() {
        var areaSettings = settings
        areaSettings.driftLevel = .area
        let activity = FocusActivity(
            windows: [window(0, 420, "Obsidian")],
            notes: [note(0, 360, assignment), note(360, 420, pogoInventory)]
        )
        let snapshot = FocusTracker.snapshot(activity: activity, from: at(0), to: at(420), settings: areaSettings)
        #expect(snapshot.offAnchorSeconds == 0)
        #expect(snapshot.switches == 0)
        #expect(snapshot.focusShare(level: .area) == 1)
    }

    @Test("Getting back on task ends the stretch; neutral time pauses it")
    func streakRules() {
        let back = FocusActivity(
            windows: [window(0, 60, "Obsidian"), window(60, 100, "Signal"), window(100, 130, "Obsidian")],
            notes: [note(0, 130, assignment)]
        )
        #expect(FocusTracker.snapshot(activity: back, from: at(0), to: at(130), settings: settings).offAnchorSeconds == 0)

        let paused = FocusActivity(
            windows: [window(0, 60, "Obsidian"), window(60, 80, "Signal"), window(80, 200, "loginwindow"), window(200, 215, "Signal")],
            notes: [note(0, 60, assignment)]
        )
        #expect(FocusTracker.snapshot(activity: paused, from: at(0), to: at(215), settings: settings).offAnchorSeconds == 35)
    }

    @Test("Away time is neutral even with a distraction window open")
    func awayIsNeutral() {
        let activity = FocusActivity(
            windows: [window(0, 60, "Obsidian"), window(60, 400, "Google Chrome", url: "https://youtube.com")],
            notes: [note(0, 60, assignment)],
            away: [AwaySpan(start: at(70), end: at(400))]
        )
        let snapshot = FocusTracker.snapshot(activity: activity, from: at(0), to: at(400), settings: settings)
        #expect(snapshot.offAnchorSeconds == 10)
        #expect(snapshot.neutralSeconds == 330)
    }

    @Test("A note opened before the interval began is the one being worked on")
    func noteFromBeforeInterval() {
        let activity = FocusActivity(windows: [window(0, 60, "Obsidian")], notes: [note(-600, -590, assignment)])
        let snapshot = FocusTracker.snapshot(activity: activity, from: at(0), to: at(60), settings: settings)
        #expect(snapshot.projectSeconds[asgn] == 60)
    }

    @Test("Short gaps between window spans are bridged, and the newest span is held open to now")
    func bridging() {
        let activity = FocusActivity(
            windows: [window(0, 29, "Obsidian"), window(31, 50, "Obsidian")],
            notes: [note(0, 50, assignment)]
        )
        let snapshot = FocusTracker.snapshot(activity: activity, from: at(0), to: at(60), settings: settings)
        #expect(snapshot.projectSeconds[asgn] == 60)
        #expect(snapshot.neutralSeconds == 0)
    }

    @Test("A pinned anchor locks at once and makes the other project drift")
    func manualAnchor() {
        let activity = FocusActivity(
            windows: [window(0, 100, "Obsidian")],
            notes: [note(0, 70, assignment), note(70, 100, inventory)]
        )
        let snapshot = FocusTracker.snapshot(activity: activity, from: at(0), to: at(100), settings: settings, manualAnchor: econ)
        #expect(snapshot.anchor == econ)
        #expect(snapshot.anchorIsManual && snapshot.anchorIsLocked)
        #expect(snapshot.offAnchorSeconds == 0)
        #expect(snapshot.focusShare(level: .task) == 0.3)
    }

    @Test("The summary keeps seconds per task and the end-of-interval line")
    func summary() {
        let activity = FocusActivity(
            windows: [window(0, 1200, "Obsidian"), window(1200, 1500, "Google Chrome", url: "https://news.ycombinator.com")],
            notes: [note(0, 1200, assignment)]
        )
        let summary = FocusTracker.snapshot(activity: activity, from: at(0), to: at(1500), settings: settings)
            .summary(level: .task, driftAlerts: 1)
        #expect(summary.projectSeconds == [asgn.task: 1200])
        #expect(summary.distractionSeconds == 300)
        #expect(summary.lineText == "Asgn03-TheoryHypotheses · 80% · 1 switch")
    }
}

@Suite("Focus: history and wire format")
struct FocusHistoryTests {

    @Test("History written before focus tracking still decodes")
    func legacyRecordDecodes() throws {
        let json = #"[{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","kind":"work","startedAt":"2026-03-10T09:00:00Z","elapsedSeconds":1500,"completed":true}]"#
        let records = try AnalyticsExporter.records(fromJSON: Data(json.utf8))
        #expect(records.count == 1)
        #expect(records[0].focus == nil)
    }

    @Test("Settings written before focus tracking get the focus defaults")
    func legacySettingsDecode() throws {
        let decoded = try JSONDecoder().decode(PomodoroSettings.self, from: Data(#"{"workMinutes":50}"#.utf8))
        #expect(decoded.workMinutes == 50)
        #expect(decoded.focus == FocusSettings())
        let partial = try JSONDecoder().decode(FocusSettings.self, from: Data(#"{"driftAlertSeconds":60}"#.utf8))
        #expect(partial.driftAlertSeconds == 60)
        #expect(partial.allowedSites == ["library.gmu.edu", "schar.gmu.edu", "windows.cloud.microsoft"])
    }

    @Test("Project totals add up per task across the day's records")
    func projectTotals() {
        func record(_ minutes: Double, _ seconds: [String: Int]) -> IntervalRecord {
            IntervalRecord(
                kind: .work, startedAt: Fixture.start.plus(minutes: minutes), elapsedSeconds: 1500, completed: true,
                focus: FocusSummary(anchorArea: nil, anchorTask: nil, focusShare: 0.5, switches: 0,
                                    projectSeconds: seconds, supportSeconds: 0, distractionSeconds: 0, driftAlerts: 0)
            )
        }
        let records = [record(0, ["A/x": 600, "A/y": 100]), record(30, ["A/x": 300]), record(-24 * 60, ["A/z": 999])]
        let totals = FocusAnalytics.projectTotals(records: records, now: Fixture.start.plus(minutes: 60), calendar: Fixture.calendar, days: 1)
        #expect(totals == [ProjectTotal(task: "A/x", seconds: 900), ProjectTotal(task: "A/y", seconds: 100)])
        #expect(FocusAnalytics.meanFocusShare(records: records, now: Fixture.start.plus(minutes: 60), calendar: Fixture.calendar, days: 1) == 0.5)
    }

    @Test("CSV quotes folder names that hold commas")
    func csvQuoting() {
        let record = IntervalRecord(
            kind: .work, startedAt: Fixture.start, elapsedSeconds: 60, completed: true,
            focus: FocusSummary(anchorArea: "Classes/A, B", anchorTask: "Classes/A, B/T", focusShare: 0.75, switches: 2,
                                projectSeconds: [:], supportSeconds: 0, distractionSeconds: 15, driftAlerts: 1)
        )
        let row = AnalyticsExporter.csv(records: [record]).split(separator: "\n")[1]
        #expect(row.hasSuffix(#""Classes/A, B","Classes/A, B/T",0.750,2,15,1,,,,,,"#))
    }

    @Test("aw-server events parse, microsecond timestamps included")
    func parsing() throws {
        let windows = #"[{"id":1,"timestamp":"2026-10-30T22:39:33.843000+00:00","duration":10.8,"data":{"title":"ActivityWatch","url":"http://localhost:5600/","app":"Google Chrome"}}]"#
        let w = try ActivityWatchParser.windows(Data(windows.utf8))
        #expect(w.count == 1)
        #expect(w[0].app == "Google Chrome" && w[0].url == "http://localhost:5600/")
        #expect(abs(w[0].end.timeIntervalSince(w[0].start) - 10.8) < 0.001)
        #expect(abs(w[0].start.timeIntervalSince1970 - 1793399973.843) < 0.001)

        let notes = #"[{"timestamp":"2026-10-30T21:24:19.5+00:00","duration":13,"data":{"file":"/A/b.md","project":"VaultSchar","tabCount":3}}]"#
        #expect(try ActivityWatchParser.notes(Data(notes.utf8)).first?.file == "/A/b.md")

        let afk = #"[{"timestamp":"2026-10-30T21:24:40Z","duration":2626.7,"data":{"status":"afk"}},{"timestamp":"2026-10-30T20:04:59Z","duration":4781.1,"data":{"status":"not-afk"}}]"#
        #expect(try ActivityWatchParser.away(Data(afk.utf8)).count == 1)
    }

    @Test("Drift repaints a running Work countdown, and nothing else")
    func driftColour() {
        var state = PomodoroReducer.reduce(PomodoroState(settings: PomodoroSettings()), .start, Fixture.start)
        let drifting = FocusSnapshot(
            anchor: nil, anchorIsLocked: false, anchorIsManual: false, projectSeconds: [:], supportSeconds: 0,
            distractionSeconds: 40, neutralSeconds: 0, switches: 0, offAnchorSeconds: 40,
            current: .distraction("Signal"), runs: []
        )
        let now = Fixture.start.plus(minutes: 1)
        #expect(MenuBarFormatter.presentation(for: state, at: now, focus: drifting).customForegroundHex == "#A855F7")
        #expect(MenuBarFormatter.presentation(for: state, at: now, focus: .empty) == MenuBarFormatter.presentation(for: state, at: now))

        state = PomodoroReducer.reduce(state, .pause, now)
        #expect(MenuBarFormatter.presentation(for: state, at: now, focus: drifting).customForegroundHex == nil)
    }
}
