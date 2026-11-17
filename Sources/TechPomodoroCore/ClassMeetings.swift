import CryptoKit
import Foundation

// Class meetings: events in a chosen calendar (Josh-School), counted toward each class's total as kind
// `Class`. They are read by the publishing Mac at publish time and never stored as history records,
// so nothing new syncs. Each occurrence gets a deterministic id, so the ordinary paper corrections
// (delete for a skipped class, new times for leaving early) apply to it across rebuilds and devices.

/// One calendar event occurrence, as the app shell reads it from EventKit.
public struct CalendarEventOccurrence: Sendable, Equatable {
    /// The event's id across devices (`calendarItemExternalIdentifier`), or its local id.
    public var externalID: String
    /// The occurrence's original start (`occurrenceDate`), which stays the same when one occurrence of
    /// a recurring event is moved.
    public var occurrenceStart: Date
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var isCancelled: Bool
    /// The user declined it.
    public var isDeclined: Bool

    public init(
        externalID: String,
        occurrenceStart: Date,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        isCancelled: Bool = false,
        isDeclined: Bool = false
    ) {
        self.externalID = externalID
        self.occurrenceStart = occurrenceStart
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isCancelled = isCancelled
        self.isDeclined = isDeclined
    }
}

public enum ClassMeetings {

    /// What one read of the calendar came to.
    public struct Result: Sendable, Equatable {
        /// The meetings that count, corrections applied, oldest first.
        public var meetings: [PaperSittingView]
        /// Events that matched no class.
        public var unmatched: Int
        /// Events whose title matched more than one class.
        public var ambiguous: Int

        public init(meetings: [PaperSittingView] = [], unmatched: Int = 0, ambiguous: Int = 0) {
            self.meetings = meetings
            self.unmatched = unmatched
            self.ambiguous = ambiguous
        }
    }

    /// The course code at the end of a class name: `Data - POGO 511` → (`POGO`, `511`). Nil when the
    /// name does not end in letters followed by a number.
    public static func courseCode(of className: String) -> (letters: String, number: String)? {
        let pattern = #"([A-Za-z]{2,8})\s*(\d{2,5})\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: className, range: NSRange(className.startIndex..., in: className)),
              let letters = Range(match.range(at: 1), in: className),
              let number = Range(match.range(at: 2), in: className)
        else { return nil }
        return (String(className[letters]), String(className[number]))
    }

    /// True when the title contains the class's course code as a whole word, case-insensitive and
    /// with or without the space: `POGO 511`, `pogo511` — but not `POGO 5110`.
    public static func title(_ title: String, matches className: String) -> Bool {
        guard let code = courseCode(of: className) else { return false }
        let pattern = #"(?<![A-Za-z0-9])"# + NSRegularExpression.escapedPattern(for: code.letters)
            + #"\s*"# + NSRegularExpression.escapedPattern(for: code.number) + #"(?![0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }

    /// The deterministic id of one occurrence: a name-based (version 5 style) UUID of the event's
    /// external id and the occurrence's original start, so it is the same on every rebuild and Mac.
    public static func meetingID(externalID: String, occurrenceStart: Date) -> UUID {
        let name = "\(externalID)|\(Int(occurrenceStart.timeIntervalSince1970.rounded()))"
        var bytes = Array(Insecure.SHA1.hash(data: Data(("tech-pomodoro.class-meeting|" + name).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// The meetings that count. All-day, cancelled, declined and not-yet-started events are skipped;
    /// a meeting in progress counts up to `now`. Each event must match exactly one class. Deleting
    /// corrections drop a meeting; start/end corrections give it new times (still capped at `now`);
    /// a note correction sets its note. Class and kind corrections are ignored.
    public static func meetings(
        events: [CalendarEventOccurrence],
        classes: [String],
        corrections: [PaperCorrection],
        now: Date
    ) -> Result {
        let names = classes.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let byTarget = Dictionary(grouping: corrections, by: \.targetID)
        var result = Result()
        var seen = Set<UUID>()
        for event in events where !event.isAllDay && !event.isCancelled && !event.isDeclined && event.start < now {
            let matched = names.filter { title(event.title, matches: $0) }
            guard matched.count == 1, let className = matched.first else {
                if matched.isEmpty { result.unmatched += 1 } else { result.ambiguous += 1 }
                continue
            }
            let id = meetingID(externalID: event.externalID, occurrenceStart: event.occurrenceStart)
            guard seen.insert(id).inserted else { continue }
            var start = event.start
            var end = event.end
            var note: String?
            if let fixes = byTarget[id] {
                let ordered = fixes.sorted { $0.modifiedAt == $1.modifiedAt ? $0.id.uuidString < $1.id.uuidString : $0.modifiedAt < $1.modifiedAt }
                if ordered.contains(where: \.deleted) { continue }
                for fix in ordered {
                    if let s = fix.start { start = s }
                    if let e = fix.end { end = e }
                    if let n = fix.note {
                        let trimmed = n.trimmingCharacters(in: .whitespacesAndNewlines)
                        note = trimmed.isEmpty ? nil : trimmed
                    }
                }
                if end < start { end = ManualSitting.span(start: start, end: end).end }
            }
            end = min(end, now)
            guard end > start else { continue }
            let span = DateInterval(start: start, end: end)
            result.meetings.append(PaperSittingView(
                id: id, className: className, kind: .classMeeting, note: note, spans: [span],
                manual: false, seconds: Int(span.duration.rounded()), fromCalendar: true
            ))
        }
        result.meetings.sort { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        return result
    }

    /// Paper sittings with the time they share with a meeting of the same class taken out, so that
    /// overlap counts once, as Class. A sitting left with nothing is dropped. Overlaps across
    /// different classes are kept. The history itself is never touched: this is for what is shown and
    /// published.
    public static func trimmed(_ sittings: [PaperSittingView], against meetings: [PaperSittingView]) -> [PaperSittingView] {
        guard !meetings.isEmpty else { return sittings }
        let byClass = Dictionary(grouping: meetings.flatMap { m in m.spans.map { (m.className, $0) } }, by: \.0)
            .mapValues { $0.map(\.1) }
        return sittings.compactMap { sitting in
            guard !sitting.fromCalendar, let blocks = byClass[sitting.className] else { return sitting }
            var spans: [DateInterval] = []
            var removed: TimeInterval = 0
            for span in sitting.spans {
                var pieces = [span]
                for block in blocks {
                    pieces = pieces.flatMap { subtract(block, from: $0) }
                }
                removed += span.duration - pieces.reduce(0) { $0 + $1.duration }
                spans.append(contentsOf: pieces)
            }
            guard removed > 0 else { return sitting }
            let seconds = max(0, sitting.seconds - Int(removed.rounded()))
            guard !spans.isEmpty, seconds > 0 else { return nil }
            return PaperSittingView(
                id: sitting.id, className: sitting.className, kind: sitting.kind, note: sitting.note,
                spans: spans, manual: sitting.manual, seconds: seconds, fromCalendar: false
            )
        }
    }

    /// `span` minus `block`: nothing, one piece or two.
    static func subtract(_ block: DateInterval, from span: DateInterval) -> [DateInterval] {
        guard block.end > span.start, block.start < span.end else { return [span] }
        var pieces: [DateInterval] = []
        if block.start > span.start { pieces.append(DateInterval(start: span.start, end: block.start)) }
        if block.end < span.end { pieces.append(DateInterval(start: block.end, end: span.end)) }
        return pieces
    }

    /// Paper sittings and meetings together, overlap trimmed, oldest first — what is published.
    public static func combined(sittings: [PaperSittingView], meetings: [PaperSittingView]) -> [PaperSittingView] {
        (trimmed(sittings, against: meetings) + meetings)
            .sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
    }
}
