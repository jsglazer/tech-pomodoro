import Foundation
import Testing
@testable import TechPomodoroCore

private let classes = ["Data - POGO 511", "Econ - PUBP 720", "RD - POGO 801"]
private let t0 = Date(timeIntervalSince1970: 1_794_000_000)

private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

private func event(
    _ title: String = "Data Analysis POGO 511",
    from: Double = 0,
    to: Double = 160,
    id: String = "evt-1",
    allDay: Bool = false,
    cancelled: Bool = false,
    declined: Bool = false
) -> CalendarEventOccurrence {
    CalendarEventOccurrence(
        externalID: id, occurrenceStart: at(from), title: title, start: at(from), end: at(to),
        isAllDay: allDay, isCancelled: cancelled, isDeclined: declined
    )
}

private func sitting(_ className: String, _ kind: PaperKind, from: Double, to: Double, id: UUID = UUID()) -> PaperSittingView {
    let span = DateInterval(start: at(from), end: at(to))
    return PaperSittingView(id: id, className: className, kind: kind, note: nil, spans: [span], manual: false, seconds: Int(span.duration))
}

@Suite("Class meetings")
struct ClassMeetingsTests {

    @Test func courseCodeIsTheTrailingLettersAndNumber() {
        #expect(ClassMeetings.courseCode(of: "Data - POGO 511")! == ("POGO", "511"))
        #expect(ClassMeetings.courseCode(of: "Econ - PUBP720")! == ("PUBP", "720"))
        #expect(ClassMeetings.courseCode(of: "Reading group") == nil)
    }

    @Test func titlesMatchWithAnySpacingAndCase() {
        #expect(ClassMeetings.title("Data Analysis POGO 511", matches: "Data - POGO 511"))
        #expect(ClassMeetings.title("pogo511 lecture", matches: "Data - POGO 511"))
        #expect(ClassMeetings.title("POGO  511", matches: "Data - POGO 511"))
        #expect(!ClassMeetings.title("POGO 5110", matches: "Data - POGO 511"))
        #expect(!ClassMeetings.title("XPOGO 511", matches: "Data - POGO 511"))
        #expect(!ClassMeetings.title("POGO 801", matches: "Data - POGO 511"))
    }

    @Test func aMatchedPastMeetingCountsAsClass() throws {
        let result = ClassMeetings.meetings(events: [event()], classes: classes, corrections: [], now: at(300))
        let meeting = try #require(result.meetings.first)
        #expect(result.meetings.count == 1)
        #expect(meeting.className == "Data - POGO 511")
        #expect(meeting.kind == .classMeeting)
        #expect(meeting.kind.title == "Class")
        #expect(meeting.fromCalendar)
        #expect(meeting.seconds == 160 * 60)
    }

    @Test func noMatchAndTwoMatchesAreCountedNotUsed() {
        let events = [event("Dinner", id: "a"), event("POGO 511 vs POGO 801 review", id: "b"), event(id: "c")]
        let result = ClassMeetings.meetings(events: events, classes: classes, corrections: [], now: at(300))
        #expect(result.meetings.count == 1)
        #expect(result.unmatched == 1)
        #expect(result.ambiguous == 1)
    }

    @Test func allDayCancelledDeclinedAndFutureAreSkipped() {
        let events = [
            event(id: "allday", allDay: true), event(id: "cancel", cancelled: true),
            event(id: "decline", declined: true), event(from: 400, to: 500, id: "future"),
        ]
        let result = ClassMeetings.meetings(events: events, classes: classes, corrections: [], now: at(300))
        #expect(result.meetings.isEmpty)
    }

    @Test func aMeetingInProgressCountsUpToNow() throws {
        let result = ClassMeetings.meetings(events: [event()], classes: classes, corrections: [], now: at(60))
        #expect(try #require(result.meetings.first).seconds == 60 * 60)
    }

    @Test func idsAreDeterministicPerOccurrence() {
        let a = ClassMeetings.meetingID(externalID: "evt-1", occurrenceStart: at(0))
        #expect(a == ClassMeetings.meetingID(externalID: "evt-1", occurrenceStart: at(0)))
        #expect(a != ClassMeetings.meetingID(externalID: "evt-1", occurrenceStart: at(7 * 24 * 60)))
        #expect(a != ClassMeetings.meetingID(externalID: "evt-2", occurrenceStart: at(0)))
        let one = ClassMeetings.meetings(events: [event()], classes: classes, corrections: [], now: at(300))
        let two = ClassMeetings.meetings(events: [event()], classes: classes, corrections: [], now: at(900))
        #expect(one.meetings.map(\.id) == two.meetings.map(\.id))
        #expect(one.meetings.first?.id == a)
    }

    @Test func aDeletionDropsTheMeeting() {
        let id = ClassMeetings.meetingID(externalID: "evt-1", occurrenceStart: at(0))
        let delete = PaperCorrection(targetID: id, modifiedAt: at(200), deleted: true)
        let edit = PaperCorrection(targetID: id, modifiedAt: at(250), note: "back again")
        let result = ClassMeetings.meetings(events: [event()], classes: classes, corrections: [delete, edit], now: at(300))
        #expect(result.meetings.isEmpty)
    }

    @Test func aTimeEditShortensTheMeetingAndClassKindEditsAreIgnored() throws {
        let id = ClassMeetings.meetingID(externalID: "evt-1", occurrenceStart: at(0))
        let leftEarly = PaperCorrection(
            targetID: id, modifiedAt: at(200), className: "Econ - PUBP 720", kind: .read, note: "left at break", end: at(90)
        )
        let result = ClassMeetings.meetings(events: [event()], classes: classes, corrections: [leftEarly], now: at(300))
        let meeting = try #require(result.meetings.first)
        #expect(meeting.seconds == 90 * 60)
        #expect(meeting.className == "Data - POGO 511")
        #expect(meeting.kind == .classMeeting)
        #expect(meeting.note == "left at break")
    }

    @Test func sameClassOverlapCountsOnceAsClass() throws {
        let meeting = sitting("Data - POGO 511", .classMeeting, from: 0, to: 160)
        let notes = sitting("Data - POGO 511", .write, from: 140, to: 200)
        let inside = sitting("Data - POGO 511", .read, from: 10, to: 40)
        let other = sitting("RD - POGO 801", .read, from: 100, to: 130)
        let all = ClassMeetings.combined(sittings: [notes, inside, other], meetings: [PaperSittingView(
            id: meeting.id, className: meeting.className, kind: .classMeeting, note: nil, spans: meeting.spans,
            manual: false, seconds: meeting.seconds, fromCalendar: true
        )])
        let trimmed = try #require(all.first { $0.id == notes.id })
        #expect(trimmed.seconds == 40 * 60)
        #expect(trimmed.spans == [DateInterval(start: at(160), end: at(200))])
        #expect(!all.contains { $0.id == inside.id })
        #expect(all.first { $0.id == other.id }?.seconds == 30 * 60)
        #expect(all.reduce(0) { $0 + $1.seconds } == (160 + 40 + 30) * 60)
    }

    @Test func aSpanCutInTheMiddleLeavesTwoPieces() {
        let block = DateInterval(start: at(10), end: at(20))
        let span = DateInterval(start: at(0), end: at(30))
        #expect(ClassMeetings.subtract(block, from: span) == [DateInterval(start: at(0), end: at(10)), DateInterval(start: at(20), end: at(30))])
    }

    @Test func publishingCarriesKindClassAndSource() throws {
        let meeting = PaperSittingView(
            id: UUID(), className: "Data - POGO 511", kind: .classMeeting, note: nil,
            spans: [DateInterval(start: at(0), end: at(160))], manual: false, seconds: 9600, fromCalendar: true
        )
        let paper = sitting("RD - POGO 801", .read, from: 200, to: 230)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let file = PaperPublishing.vaultFile([meeting, paper], generated: at(300), calendar: calendar)
        #expect(file.version == 1)
        #expect(file.sittings.map(\.kind) == ["Class", "Read"])
        #expect(file.sittings.map(\.source) == ["calendar", "app"])
        #expect(file.sittings.first?.minutes == 160)
        let events = PaperPublishing.awEvents([meeting, paper])
        #expect(events.map(\.data.kind) == ["Class", "Read"])
        #expect(events.map(\.data.source) == ["calendar", "app"])
        #expect(PaperPublishing.fingerprint([meeting]) != PaperPublishing.fingerprint([paper]))
    }

    @Test func classIsNeverOfferedOnTheTag() {
        #expect(!PaperKind.pickable.contains(.classMeeting))
        #expect(PaperKind.pickable == [.read, .write, .practice, .watch])
        #expect(PaperKind(rawValue: "class") == .classMeeting)
    }

    @Test func totalsOverSittingsIncludeMeetings() {
        let meeting = PaperSittingView(
            id: UUID(), className: "Data - POGO 511", kind: .classMeeting, note: nil,
            spans: [DateInterval(start: at(0), end: at(160))], manual: false, seconds: 9600, fromCalendar: true
        )
        let paper = sitting("Data - POGO 511", .read, from: 200, to: 230)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let totals = PaperHistory.totals(sittings: [meeting, paper], now: at(300), calendar: calendar, days: 3)
        #expect(totals.count == 1)
        #expect(totals.first?.seconds == (160 + 30) * 60)
    }

    @Test func meetingSettingsAreDeviceOnly() throws {
        var local = PomodoroSettings()
        local.paperMeetingsEnabled = true
        local.paperMeetingsCalendar = "Josh-School"
        var remote = PomodoroSettings()
        remote.paperMeetingsEnabled = false
        remote.paperMeetingsCalendar = "Other"
        let merged = SyncMerge.adopt(remote: remote, keepingDeviceFieldsOf: local)
        #expect(merged.paperMeetingsEnabled)
        #expect(merged.paperMeetingsCalendar == "Josh-School")
        let old = try JSONDecoder().decode(PomodoroSettings.self, from: Data("{}".utf8))
        #expect(!old.paperMeetingsEnabled)
        #expect(old.paperMeetingsCalendar == "Josh-School")
    }
}
