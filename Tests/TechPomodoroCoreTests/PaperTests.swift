import Foundation
import Testing
@testable import TechPomodoroCore

private let data = PaperTag(className: "Data - POGO 511", kind: .read)
private let econ = PaperTag(className: "Econ - PUBP 720", kind: .write)

private func at(_ minutes: Double, _ seconds: Double = 0) -> Date { Fixture.start.plus(minutes: minutes, seconds: seconds) }

/// Every record produced along a run of events, in order.
private func run(_ state: PomodoroState, _ steps: [(PomodoroEvent, Date)]) -> (PomodoroState, [IntervalRecord]) {
    var s = state
    var records: [IntervalRecord] = []
    for (event, date) in steps {
        s = PomodoroReducer.reduce(s, event, date)
        records += s.pendingRecords
    }
    return (s, records)
}

private func spanSeconds(_ record: IntervalRecord) -> Int {
    Int((record.paper?.seconds ?? 0).rounded())
}

@Suite("Paper: the sticky tag")
struct PaperTagTests {

    @Test("A tag set while idle applies from the next Start and survives every phase boundary")
    func stickyAcrossPhases() {
        // 25/5 × 3 reps, 15 long break, 2 cycles, 60 session rest.
        let (state, records) = run(PomodoroState(settings: Fixture.settings()), [
            (.setPaperTag(data), at(0)),
            (.start, at(0)),
            // Through rep 1, rest, rep 2, rest, rep 3, the long break and into cycle 2's first Work.
            (.tick, at(25 * 3 + 5 * 2 + 15 + 1))
        ])
        #expect(state.paperTag == data)
        #expect(state.phase == .work)
        let work = records.filter { $0.kind == .work }
        #expect(work.count == 3)
        #expect(work.allSatisfy { $0.paper?.className == "Data - POGO 511" && $0.paper?.kind == .read })
        #expect(work.allSatisfy { $0.completed && $0.elapsedSeconds == 25 * 60 && spanSeconds($0) == 25 * 60 })
        // Rests and the cycle marker never carry paper.
        #expect(records.filter { $0.kind != .work }.allSatisfy { $0.paper == nil })
    }

    @Test("Pause and resume keep the tag; the pause ends a span and the spans add up to the time worked")
    func pauseSplitsSpans() {
        let (state, records) = run(PomodoroState(settings: Fixture.settings()), [
            (.start, at(0)),
            (.setPaperTag(data), at(0)),
            (.pause, at(10)),
            (.resume, at(14)),
            (.tick, at(29))
        ])
        #expect(state.paperTag == data)
        #expect(records.count == 1)
        let record = records[0]
        #expect(record.completed)
        #expect(record.elapsedSeconds == 25 * 60)
        #expect(record.paper?.spans == [DateInterval(start: at(0), end: at(10)), DateInterval(start: at(14), end: at(29))])
        #expect(spanSeconds(record) == record.elapsedSeconds)
    }

    @Test("Sleep keeps the tag under every sleep behaviour")
    func sleepKeepsTag() {
        for behavior in SleepBehavior.allCases {
            let (state, records) = run(PomodoroState(settings: Fixture.settings(sleepBehavior: behavior)), [
                (.setPaperTag(data), at(0)),
                (.start, at(0)),
                (.willSleep, at(5)),
                (.didWake, at(9)),
                (.resume, at(9)),
                (.stop, at(12))
            ])
            #expect(state.paperTag == nil, "Stop clears the tag")
            let work = records.filter { $0.kind == .work }
            #expect(work.count == 1)
            #expect(work.first?.paper?.className == "Data - POGO 511", "\(behavior)")
            #expect(spanSeconds(work[0]) == work[0].elapsedSeconds, "\(behavior)")
        }
    }

    @Test("Only Clear and Stop end the tag; finishing the schedule keeps it")
    func clearedOnlyByClearOrStop() {
        var state = PomodoroState(settings: Fixture.settings(reps: 1, cycles: 1, sessionRest: 1))
            .applying([(.setPaperTag(data), at(0)), (.start, at(0)), (.tick, at(25 + 15 + 1 + 1))])
        #expect(state.activity == .idle)
        #expect(state.paperTag == data)

        state = PomodoroReducer.reduce(state, .clearPaperTag, at(50))
        #expect(state.paperTag == nil)

        state = state.applying([(.setPaperTag(econ), at(51)), (.stop, at(52))])
        #expect(state.paperTag == nil, "Stop clears the tag even when idle")
    }

    @Test("A tag set during a rest marks the next Work, not the rest")
    func tagDuringRest() {
        let (_, records) = run(PomodoroState(settings: Fixture.settings()), [
            (.start, at(0)),
            (.tick, at(26)),
            (.setPaperTag(econ), at(27)),
            (.tick, at(56))
        ])
        let work = records.filter { $0.kind == .work }
        #expect(work.count == 2)
        #expect(work[0].paper == nil)
        #expect(work[1].paper?.className == "Econ - PUBP 720")
        #expect(work[1].completed)
    }

    @Test("Skip logs the tagged partial with its spans")
    func skipKeepsPaper() {
        let (_, records) = run(PomodoroState(settings: Fixture.settings()), [
            (.setPaperTag(data), at(0)),
            (.start, at(0)),
            (.skip, at(8))
        ])
        let work = records.filter { $0.kind == .work }
        #expect(work.count == 1)
        #expect(work[0].completed == false)
        #expect(work[0].elapsedSeconds == 8 * 60)
        #expect(work[0].paper?.spans == [DateInterval(start: at(0), end: at(8))])
    }
}

@Suite("Paper: a tag change splits the Work record")
struct PaperSplitTests {

    @Test("Setting a tag mid-Work closes the untagged stretch; the pieces add up to one unsplit record")
    func setMidWork() {
        let (_, records) = run(PomodoroState(settings: Fixture.settings()), [
            (.start, at(0)),
            (.setPaperTag(data), at(10)),
            (.tick, at(25))
        ])
        let work = records.filter { $0.kind == .work }
        #expect(work.count == 2)
        #expect(work[0].paper == nil)
        #expect(work[0].completed == false)
        #expect(work[0].elapsedSeconds == 10 * 60)
        #expect(work[0].startedAt == at(0))
        #expect(work[1].paper?.className == "Data - POGO 511")
        #expect(work[1].completed)
        #expect(work[1].elapsedSeconds == 15 * 60)
        #expect(work[1].startedAt == at(10))
        #expect(work.map(\.elapsedSeconds).reduce(0, +) == 25 * 60)
        #expect(spanSeconds(work[1]) == work[1].elapsedSeconds)
    }

    @Test("Changing and clearing the tag split again; reps, cycles and work time match an unsplit run")
    func analyticsUnchanged() throws {
        let split = run(PomodoroState(settings: Fixture.settings()), [
            (.setPaperTag(data), at(0)),
            (.start, at(0)),
            (.setPaperTag(econ), at(5, 30)),
            (.pause, at(9)),
            (.clearPaperTag, at(10)),
            (.resume, at(12)),
            (.tick, at(27 + 5 + 25 + 5 + 25 + 1))
        ]).1
        let plain = run(PomodoroState(settings: Fixture.settings()), [
            (.start, at(0)),
            (.pause, at(9)),
            (.resume, at(12)),
            (.tick, at(27 + 5 + 25 + 5 + 25 + 1))
        ]).1

        let splitWork = split.filter { $0.kind == .work }
        #expect(splitWork.count == plain.filter { $0.kind == .work }.count + 2)
        #expect(splitWork[0].paper?.kind == .read && splitWork[0].elapsedSeconds == 330)
        #expect(splitWork[1].paper?.kind == .write && splitWork[1].elapsedSeconds == 210)
        #expect(splitWork[2].paper == nil && splitWork[2].completed)

        let now = at(200)
        let a = AnalyticsAggregator.window(records: split, now: now, calendar: Fixture.calendar, days: 1)
        let b = AnalyticsAggregator.window(records: plain, now: now, calendar: Fixture.calendar, days: 1)
        #expect(a == b)
        #expect(a.reps == 3 && a.cycles == 1 && a.workSeconds == 75 * 60)

        // The exports carry every piece, and the seconds still add up.
        let csv = AnalyticsExporter.csv(records: split)
        var seconds = 0
        for line in csv.split(separator: "\n").dropFirst() {
            let fields: [Substring] = line.split(separator: ",", omittingEmptySubsequences: false)
            if fields[1] == "work", let value = Int(fields[3]) { seconds += value }
        }
        #expect(seconds == 75 * 60)
        #expect(try AnalyticsExporter.records(fromJSON: AnalyticsExporter.json(records: split)) == split)
    }

    @Test("A note change alone is the same sitting and does not split")
    func noteDoesNotSplit() {
        let (_, records) = run(PomodoroState(settings: Fixture.settings()), [
            (.setPaperTag(data), at(0)),
            (.start, at(0)),
            (.setPaperTag(PaperTag(className: data.className, kind: .read, note: "ch. 4")), at(10)),
            (.tick, at(25))
        ])
        #expect(records.count == 1)
        #expect(records[0].paper?.note == "ch. 4")
        #expect(records[0].completed)
    }

    @Test("A split while paused: the new record starts with no running stretch")
    func splitWhilePaused() {
        let (_, records) = run(PomodoroState(settings: Fixture.settings()), [
            (.setPaperTag(data), at(0)),
            (.start, at(0)),
            (.pause, at(6)),
            (.setPaperTag(econ), at(8)),
            (.resume, at(10)),
            (.tick, at(29))
        ])
        #expect(records.count == 2)
        #expect(records[0].paper?.spans == [DateInterval(start: at(0), end: at(6))])
        #expect(records[1].paper?.spans == [DateInterval(start: at(10), end: at(29))])
        #expect(records[1].elapsedSeconds == 19 * 60)
    }
}

@Suite("Paper: focus while tagged")
struct PaperFocusTests {
    let settings = FocusSettings()
    let dataNote = "/Classes/2026-B/Data - POGO 511/Inventory/OLS.md"
    let dataAssign = "/Classes/2026-B/Data - POGO 511/Assign/Asgn02/Draft.md"
    let econNote = "/Classes/2026-B/Econ - PUBP 720/Inventory/2.4 Elasticities.md"

    private func s(_ x: Double) -> Date { Fixture.start.plus(seconds: x) }

    @Test("The anchor is pinned to the tagged class from the start, at either drift level")
    func pinned() {
        var task = settings
        task.driftLevel = .task
        let activity = FocusActivity(
            windows: [WindowSpan(start: s(0), end: s(600), app: "Obsidian", title: "")],
            notes: [NoteSpan(start: s(0), end: s(300), file: econNote), NoteSpan(start: s(300), end: s(600), file: dataAssign)]
        )
        let snapshot = FocusTracker.snapshot(activity: activity, from: s(0), to: s(600), settings: task, paperClass: "Data - POGO 511")
        #expect(snapshot.anchorIsLocked)
        #expect(snapshot.anchor?.area == "Classes/2026-B/Data - POGO 511")
        // Typing in the class's own notes — any task — is on task; the other class was drift.
        #expect(snapshot.offAnchorSeconds == 0)
        #expect(snapshot.anchorSeconds(level: .task) == 300)
        #expect(snapshot.summary(level: .task, driftAlerts: 0).paperOverlapSeconds == 300)
    }

    @Test("Another class's notes drift; away time stays neutral and never raises drift")
    func otherClassDrifts() {
        let activity = FocusActivity(
            windows: [WindowSpan(start: s(0), end: s(400), app: "Obsidian", title: "")],
            notes: [NoteSpan(start: s(0), end: s(60), file: dataNote), NoteSpan(start: s(60), end: s(400), file: econNote)],
            away: [AwaySpan(start: s(400), end: s(1200))]
        )
        let drifting = FocusTracker.snapshot(activity: activity, from: s(0), to: s(300), settings: settings, paperClass: "Data - POGO 511")
        #expect(drifting.offAnchorSeconds == 240)

        let reading = FocusActivity(
            windows: [WindowSpan(start: s(0), end: s(30), app: "Obsidian", title: "")],
            notes: [NoteSpan(start: s(0), end: s(30), file: dataNote)],
            away: [AwaySpan(start: s(30), end: s(1500))]
        )
        let away = FocusTracker.snapshot(activity: reading, from: s(0), to: s(1500), settings: settings, paperClass: "Data - POGO 511")
        #expect(away.offAnchorSeconds == 0)
        #expect(!away.isDrifting)
        #expect(away.summary(level: settings.driftLevel, driftAlerts: 0).paperOverlapSeconds == 30)
    }

    @Test("With nothing of the class on screen yet the anchor is the bare class name; untagged Work has no overlap field")
    func bareAnchorAndNoOverlapWhenUntagged() {
        let empty = FocusTracker.snapshot(activity: FocusActivity(), from: s(0), to: s(60), settings: settings, paperClass: "RD - POGO 801")
        #expect(empty.anchor?.area == "RD - POGO 801")
        let untagged = FocusTracker.snapshot(activity: FocusActivity(), from: s(0), to: s(60), settings: settings)
        #expect(untagged.summary(level: .area, driftAlerts: 0).paperOverlapSeconds == nil)
    }
}

@Suite("Paper: decoding and display")
struct PaperCodingTests {

    @Test("A record written before paper time decodes, and the key stays absent when nil")
    func legacyDecoding() throws {
        let old = #"[{"completed":true,"elapsedSeconds":1500,"id":"6F1C2A2E-0000-4000-8000-000000000001","kind":"work","startedAt":"2026-03-10T09:00:00Z"}]"#
        let records = try AnalyticsExporter.records(fromJSON: Data(old.utf8))
        #expect(records[0].paper == nil)
        #expect(records[0].manual == nil)
        let reencoded = String(decoding: try AnalyticsExporter.json(records: records), as: UTF8.self)
        #expect(!reencoded.contains("paper"))
        #expect(!reencoded.contains("manual"))
    }

    @Test("A paper record roundtrips through the sync payload, spans included")
    func paperRoundtrip() throws {
        let record = IntervalRecord(
            kind: .work, startedAt: at(0), elapsedSeconds: 600, completed: false,
            focus: FocusSummary(anchorArea: "a", anchorTask: "a", focusShare: 1, switches: 0, projectSeconds: [:], supportSeconds: 0, distractionSeconds: 0, driftAlerts: 0, paperOverlapSeconds: 42),
            paper: PaperSitting(tag: data, spans: [DateInterval(start: at(0), end: at(4)), DateInterval(start: at(6), end: at(12))])
        )
        let decoded = try IntervalRecord.fromSyncPayload(record.syncPayload())
        #expect(decoded == record)
        #expect(decoded.focus?.paperOverlapSeconds == 42)
    }

    @Test("An unknown kind from a newer build reads as Read")
    func unknownKind() throws {
        let json = #"{"className":"X","kind":"listen","spans":[]}"#
        #expect(try JSONDecoder().decode(PaperSitting.self, from: Data(json.utf8)).kind == .read)
    }

    @Test("Tagged Work shows P in both menu bar modes, and the hover names the class and kind")
    func menuBar() {
        var settings = Fixture.settings()
        var state = PomodoroState(settings: settings).applying([(.setPaperTag(data), at(0)), (.start, at(0))])
        #expect(MenuBarFormatter.presentation(for: state, at: at(1)).text == "24P")
        #expect(MenuBarFormatter.hoverText(for: state, at: at(12, 57)) == "Paper · Data - POGO 511 · Read 12:03")
        #expect(MenuBarFormatter.hoverInfo(for: state, at: at(1)).title == "Paper · Data - POGO 511 · Read")

        settings.menuBarMode = .clockIcon
        state = PomodoroReducer.reduce(state, .settingsChanged(settings), at(1))
        #expect(MenuBarFormatter.presentation(for: state, at: at(1)).text == "P")
        state = PomodoroReducer.reduce(state, .pause, at(2))
        #expect(MenuBarFormatter.presentation(for: state, at: at(2)).text == "P")

        // Rest is still R.
        state = state.applying([(.resume, at(3)), (.tick, at(30))])
        #expect(MenuBarFormatter.presentation(for: state, at: at(30)).text == "R")
    }

    @Test("The mirrored content carries the class and kind, and content from an older build still decodes")
    func mirror() throws {
        let state = PomodoroState(settings: Fixture.settings()).applying([(.setPaperTag(data), at(0)), (.start, at(0))])
        let content = try #require(MirrorContentBuilder.content(for: state, at: at(1)))
        #expect(content.paperClass == "Data - POGO 511")
        #expect(content.paperKind == "Read")
        #expect(content.paperLine == "Data - POGO 511 · Read")

        var old = content
        old.paperClass = nil
        old.paperKind = nil
        let data = try JSONEncoder().encode(old)
        #expect(!String(decoding: data, as: UTF8.self).contains("paper"))
        #expect(try JSONDecoder().decode(MirrorContent.self, from: data).paperClass == nil)

        // The iPhone's timer state carries its tag to the Macs.
        let restored = MirrorTimerState(state).restore(onto: PomodoroSettings())
        #expect(restored?.paperTag == state.paperTag)
    }

    @Test("The tag store keeps the tag across a relaunch and forgets it when cleared")
    func tagStore() throws {
        let defaults = try #require(UserDefaults(suiteName: "paper-tag-\(UUID().uuidString)"))
        let store = UserDefaultsPaperTagStore(defaults: defaults)
        #expect(store.load() == nil)
        store.save(PaperTag(className: "Data - POGO 511", kind: .practice, note: "  set 3 "))
        #expect(store.load() == PaperTag(className: "Data - POGO 511", kind: .practice, note: "set 3"))
        store.save(nil)
        #expect(store.load() == nil)
    }
}

@Suite("Paper: settings")
struct PaperSettingsTests {

    @Test("Settings from before paper time migrate once to the three class folders")
    func migration() throws {
        let old = #"{"workMinutes":30}"#
        let decoded = try JSONDecoder().decode(PomodoroSettings.self, from: Data(old.utf8))
        #expect(decoded.paperClasses.isEmpty)
        #expect(decoded.paperMigrationLevel == 0)
        let migrated = try #require(PaperMigrations.migrate(decoded))
        #expect(migrated.paperClasses == ["Data - POGO 511", "Econ - PUBP 720", "RD - POGO 801"])
        #expect(PaperMigrations.migrate(migrated) == nil)

        // A user's own list is kept, and the defaults are only added once.
        var mine = decoded
        mine.paperClasses = ["Stats - X"]
        let kept = try #require(PaperMigrations.migrate(mine))
        #expect(kept.paperClasses.first == "Stats - X")
        #expect(PomodoroSettings().paperClasses == PaperDefaults.classes)
        #expect(PaperMigrations.migrate(PomodoroSettings()) == nil)
    }

    @Test("The class list syncs; the publish switch and path stay on their own Mac")
    func deviceFields() {
        var local = PomodoroSettings()
        local.paperPublishEnabled = true
        local.paperLogPath = "/tmp/a.json"
        var remote = PomodoroSettings()
        remote.paperClasses = ["Only"]
        let adopted = SyncMerge.adopt(remote: remote, keepingDeviceFieldsOf: local)
        #expect(adopted.paperClasses == ["Only"])
        #expect(adopted.paperPublishEnabled)
        #expect(adopted.paperLogPath == "/tmp/a.json")
        var toggled = PomodoroSettings()
        toggled.paperPublishEnabled = true
        #expect(!SyncMerge.syncedFieldsDiffer(toggled, PomodoroSettings()))
    }
}

@Suite("Paper: publishing")
struct PaperPublishingTests {

    private func sittings() -> [PaperSittingView] {
        let (_, records) = run(PomodoroState(settings: Fixture.settings()), [
            (.setPaperTag(PaperTag(className: "Data - POGO 511", kind: .read, note: "ch 4")), at(0)),
            (.start, at(0)),
            (.pause, at(10)),
            (.resume, at(13)),
            (.setPaperTag(econ), at(20)),
            (.tick, at(28))
        ])
        return PaperHistory.sittings(records: records, corrections: [])
    }

    @Test("One ActivityWatch event per span, split records and multi-span sittings included")
    func awEvents() {
        let events = PaperPublishing.awEvents(sittings())
        #expect(events.count == 3)
        #expect(events.map(\.timestamp) == ["2026-03-10T09:00:00Z", "2026-03-10T09:13:00Z", "2026-03-10T09:20:00Z"])
        #expect(events.map(\.duration) == [600, 420, 480])
        #expect(events[0].data.class == "Data - POGO 511")
        #expect(events[0].data.kind == "Read")
        #expect(events[0].data.note == "ch 4")
        #expect(events[0].data.record_id == events[1].data.record_id)
        #expect(events[2].data.kind == "Write")
        #expect(PaperPublishing.bucketID(hostname: "MBA24") == "aw-watcher-paper_MBA24")
    }

    @Test("The vault file lists each sitting once, sorted by start, in local time")
    func vaultFile() throws {
        var calendar = Fixture.calendar
        calendar.timeZone = TimeZone(secondsFromGMT: -5 * 3600)!
        let file = PaperPublishing.vaultFile(sittings(), generated: at(30), calendar: calendar)
        #expect(file.version == 1)
        #expect(file.generated == "2026-03-10T09:30:00Z")
        #expect(file.sittings.count == 2)
        let first = file.sittings[0]
        #expect(first.date == "2026-03-10")
        #expect(first.class == "Data - POGO 511")
        #expect(first.kind == "Read")
        #expect(first.start == "04:00")
        #expect(first.end == "04:20")
        #expect(first.minutes == 17)
        #expect(first.note == "ch 4")
        #expect(first.spans == [["2026-03-10T09:00:00Z", "2026-03-10T09:10:00Z"], ["2026-03-10T09:13:00Z", "2026-03-10T09:20:00Z"]])
        #expect(file.sittings[1].kind == "Write" && file.sittings[1].minutes == 8 && file.sittings[1].note == "")

        let json = try JSONSerialization.jsonObject(with: PaperPublishing.vaultJSON(sittings(), generated: at(30), calendar: calendar)) as? [String: Any]
        #expect(Set(json?.keys ?? [:].keys) == ["version", "generated", "sittings"])
        let row = (json?["sittings"] as? [[String: Any]])?.first
        #expect(Set(row?.keys ?? [:].keys) == ["id", "date", "class", "kind", "start", "end", "minutes", "note", "spans"])
    }

    @Test("Paper records outlive the ordinary 30-day retention")
    func retention() {
        let old = IntervalRecord(kind: .work, startedAt: at(-60 * 24 * 90), elapsedSeconds: 60, completed: true)
        let paper = IntervalRecord(kind: .work, startedAt: old.startedAt, elapsedSeconds: 60, completed: true, paper: PaperSitting(tag: data, spans: []))
        let ancient = IntervalRecord(kind: .work, startedAt: at(-60 * 24 * 500), elapsedSeconds: 60, completed: true, paper: PaperSitting(tag: data, spans: []))
        let kept = AnalyticsAggregator.prune([old, paper, ancient], now: at(0), calendar: Fixture.calendar)
        #expect(kept.map(\.id) == [paper.id])
    }
}

@Suite("Paper: corrections and past sittings")
struct PaperCorrectionTests {

    private let target = IntervalRecord(
        kind: .work, startedAt: at(0), elapsedSeconds: 1500, completed: true,
        paper: PaperSitting(tag: data, spans: [DateInterval(start: at(0), end: at(25))])
    )

    @Test("Concurrent edits fold oldest first: the later edit of each field wins")
    func concurrentEdits() {
        let a = PaperCorrection(targetID: target.id, modifiedAt: at(30), className: "Econ - PUBP 720", note: "from Mac")
        let b = PaperCorrection(targetID: target.id, modifiedAt: at(31), kind: .watch, note: "from iPhone")
        // Merged in either order, the same result.
        let ab = PaperHistory.mergeCorrections(local: [a], remote: [b], now: at(40), calendar: Fixture.calendar)
        let ba = PaperHistory.mergeCorrections(local: [b], remote: [a], now: at(40), calendar: Fixture.calendar)
        #expect(ab == ba)
        let sitting = PaperHistory.sittings(records: [target], corrections: ab)[0]
        #expect(sitting.className == "Econ - PUBP 720")
        #expect(sitting.kind == .watch)
        #expect(sitting.note == "from iPhone")
        #expect(sitting.seconds == 1500, "A timed sitting keeps its measured time")
    }

    @Test("A deletion is final: an edit made after it does not bring the sitting back")
    func deleteThenEdit() {
        let delete = PaperCorrection(targetID: target.id, modifiedAt: at(30), deleted: true)
        let edit = PaperCorrection(targetID: target.id, modifiedAt: at(35), className: "RD - POGO 801")
        #expect(PaperHistory.sittings(records: [target], corrections: [delete, edit]).isEmpty)
        #expect(PaperHistory.apply([edit, delete], to: [target]).isEmpty)
        // Other records are untouched.
        let other = IntervalRecord(kind: .work, startedAt: at(60), elapsedSeconds: 60, completed: true)
        #expect(PaperHistory.apply([delete], to: [target, other]) == [other])
    }

    @Test("An edit for a record not yet synced waits, and applies once the record arrives")
    func editBeforeRecord() {
        let edit = PaperCorrection(targetID: target.id, modifiedAt: at(30), kind: .practice)
        #expect(PaperHistory.sittings(records: [], corrections: [edit]).isEmpty)
        let merged = PaperHistory.mergeCorrections(local: [], remote: [edit], now: at(31), calendar: Fixture.calendar)
        #expect(merged == [edit])
        let arrived = SyncMerge.mergeHistory(local: [], remote: [target], now: at(31), calendar: Fixture.calendar)
        #expect(PaperHistory.sittings(records: arrived, corrections: merged).first?.kind == .practice)
    }

    @Test("A correction survives the sync payload")
    func correctionPayload() throws {
        let c = PaperCorrection(targetID: target.id, modifiedAt: at(30), className: "X", kind: .write, note: "", start: at(1), end: at(2), deleted: false)
        #expect(try PaperCorrection.fromSyncPayload(c.syncPayload()) == c)
        // An older build reading it as an interval fails to decode and skips it, rather than crashing.
        #expect(throws: (any Error).self) { try IntervalRecord.fromSyncPayload(c.syncPayload()) }
    }

    @Test("A past sitting adds paper time but never reps or work time; an end before the start runs past midnight")
    func manualSitting() {
        let start = at(60 * 13)  // 22:00
        let endTime = at(14 * 60 + 30) // 23:30 the same day
        let span = ManualSitting.span(start: start, endTimeOf: endTime, calendar: Fixture.calendar)
        #expect(span.duration == 90 * 60)
        let overnight = ManualSitting.span(start: start, endTimeOf: at(16 * 60), calendar: Fixture.calendar) // 01:00 → next day
        #expect(overnight.duration == 3 * 3600)

        let record = ManualSitting.record(tag: econ, span: span)
        #expect(record.isManual && !record.completed && record.focus == nil)
        #expect(record.paper?.spans == [span])
        let window = AnalyticsAggregator.window(records: [record], now: at(60 * 14 + 40), calendar: Fixture.calendar, days: 1)
        #expect(window.workSeconds == 0 && window.reps == 0)
        #expect(PaperHistory.totals(records: [record], corrections: [], now: at(60 * 14 + 40), calendar: Fixture.calendar, days: 1).first?.seconds == 5400)
    }

    @Test("A manual sitting's times can be corrected; a timed sitting's cannot")
    func correctTimes() {
        let manual = ManualSitting.record(tag: data, span: DateInterval(start: at(0), end: at(30)))
        let fix = PaperCorrection(targetID: manual.id, modifiedAt: at(40), start: at(5), end: at(50))
        let fixed = PaperHistory.sittings(records: [manual], corrections: [fix])[0]
        #expect(fixed.start == at(5) && fixed.end == at(50) && fixed.seconds == 45 * 60)

        let timedFix = PaperCorrection(targetID: target.id, modifiedAt: at(40), start: at(5), end: at(50))
        let timed = PaperHistory.sittings(records: [target], corrections: [timedFix])[0]
        #expect(timed.start == at(0) && timed.seconds == 1500)
    }

    @Test("Today's Paper line sums by class")
    func todayLine() {
        let second = IntervalRecord(kind: .work, startedAt: at(30), elapsedSeconds: 1500, completed: true,
                                    paper: PaperSitting(tag: data, spans: [DateInterval(start: at(30), end: at(55))]))
        let third = ManualSitting.record(tag: econ, span: DateInterval(start: at(60), end: at(85)))
        let totals = PaperHistory.totals(records: [target, second, third], corrections: [], now: at(90), calendar: Fixture.calendar, days: 1)
        #expect(PaperHistory.lineText(totals) == "Data 50m · Econ 25m")
    }
}
