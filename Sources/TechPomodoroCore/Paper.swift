import Foundation

// Paper time: Work intervals spent away from the screen — reading, writing, practising or watching —
// credited to a class. A tag on the timer (`PomodoroState.paperTag`) marks the Work that follows as
// paper time; each tagged Work record carries a `PaperSitting` with the exact stretches it ran.
//
// The overlap rule: a tagged span counts once, for the tagged class. On-screen activity during the
// span is kept for information (`FocusSummary.paperOverlapSeconds`) and never added to paper time.

/// What kind of paper work a sitting was.
public enum PaperKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case read
    case write
    case practice
    case watch

    public var id: String { rawValue }

    /// `Read`, `Write`, `Practice`, `Watch` — also the form written to the vault file.
    public var title: String {
        switch self {
        case .read: return "Read"
        case .write: return "Write"
        case .practice: return "Practice"
        case .watch: return "Watch"
        }
    }

    /// An unknown raw value from a newer build reads as Read rather than failing the whole record.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaperKind(rawValue: raw) ?? .read
    }
}

/// The paper tag set on the timer. Per device runtime state, never a synced setting.
public struct PaperTag: Codable, Sendable, Equatable, Hashable {
    /// The class folder name exactly, e.g. `Data - POGO 511`.
    public var className: String
    public var kind: PaperKind
    public var note: String?

    public init(className: String, kind: PaperKind = .read, note: String? = nil) {
        self.className = className
        self.kind = kind
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// The class and kind — what a record is filed under. A tag that differs only in its note is the
    /// same sitting, so changing the note never splits a Work record.
    public func sameSitting(as other: PaperTag?) -> Bool {
        guard let other else { return false }
        return className == other.className && kind == other.kind
    }

    /// `Data - POGO 511 · Read`.
    public var label: String { "\(className) · \(kind.title)" }

    /// `Data · Read` — the class's first word, for tight spaces (the end-of-Work dialog line).
    public var shortLabel: String { "\(PaperTag.shortClass(className)) · \(kind.title)" }

    /// `Data - POGO 511` → `Data`; a name with no ` - ` is kept whole.
    public static func shortClass(_ name: String) -> String {
        guard let range = name.range(of: " - ") else { return name }
        let head = name[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? name : head
    }
}

/// The paper part of a Work record: the tag it ran under and the wall-clock stretches it actually
/// ran. A pause ends a span and the resume starts the next, so the spans add up to the record's
/// `elapsedSeconds` (to the rounding second).
public struct PaperSitting: Codable, Sendable, Equatable, Hashable {
    public var className: String
    public var kind: PaperKind
    public var note: String?
    public var spans: [DateInterval]

    public init(className: String, kind: PaperKind, note: String? = nil, spans: [DateInterval]) {
        self.className = className
        self.kind = kind
        self.note = note
        self.spans = spans
    }

    public init(tag: PaperTag, spans: [DateInterval]) {
        self.init(className: tag.className, kind: tag.kind, note: tag.note, spans: spans)
    }

    public var seconds: TimeInterval { spans.reduce(0) { $0 + $1.duration } }
    public var start: Date? { spans.map(\.start).min() }
    public var end: Date? { spans.map(\.end).max() }
}

/// An edit or deletion of a paper sitting. History records are immutable and merge by id, so a fix is
/// a record of its own, applied when the history is read. Corrections for one target fold oldest
/// first: each field set replaces the one before it. A deletion is final — a later or concurrent edit
/// never brings a deleted sitting back.
public struct PaperCorrection: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: UUID
    /// The `IntervalRecord` this corrects.
    public let targetID: UUID
    public let modifiedAt: Date
    public var className: String?
    public var kind: PaperKind?
    /// An empty string clears the note.
    public var note: String?
    /// New start and end. Honoured only for manual sittings: a timed sitting's spans are what the
    /// timer measured.
    public var start: Date?
    public var end: Date?
    public var deleted: Bool

    public init(
        id: UUID = UUID(),
        targetID: UUID,
        modifiedAt: Date,
        className: String? = nil,
        kind: PaperKind? = nil,
        note: String? = nil,
        start: Date? = nil,
        end: Date? = nil,
        deleted: Bool = false
    ) {
        self.id = id
        self.targetID = targetID
        self.modifiedAt = modifiedAt
        self.className = className
        self.kind = kind
        self.note = note
        self.start = start
        self.end = end
        self.deleted = deleted
    }

    public func syncPayload() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func fromSyncPayload(_ data: Data) throws -> PaperCorrection {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PaperCorrection.self, from: data)
    }
}

// MARK: - Reading the history

/// One paper sitting as the app shows and publishes it: a Work record with `paper`, corrections applied.
public struct PaperSittingView: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let className: String
    public let kind: PaperKind
    public let note: String?
    public let spans: [DateInterval]
    public let manual: Bool
    /// The record's own elapsed time (timed sittings) or the span total (manual ones).
    public let seconds: Int

    public var start: Date { spans.map(\.start).min() ?? .distantPast }
    public var end: Date { spans.map(\.end).max() ?? .distantPast }
}

public enum PaperHistory {

    /// Paper records are kept this many calendar days, past the ordinary 30-day retention, so a whole
    /// term's sittings stay in the vault file.
    public static let retentionDays = 400

    /// Applies the corrections to the history: deleted sittings drop out, edited ones take the new
    /// class, kind, note (and, for manual sittings, times). Records without `paper` are untouched,
    /// and so is any record a correction does not target. A correction whose target has not arrived
    /// yet is simply held until it does.
    public static func apply(_ corrections: [PaperCorrection], to records: [IntervalRecord]) -> [IntervalRecord] {
        guard !corrections.isEmpty else { return records }
        let byTarget = Dictionary(grouping: corrections, by: \.targetID)
        return records.compactMap { record in
            guard var paper = record.paper, let fixes = byTarget[record.id] else { return record }
            let ordered = fixes.sorted { $0.modifiedAt == $1.modifiedAt ? $0.id.uuidString < $1.id.uuidString : $0.modifiedAt < $1.modifiedAt }
            if ordered.contains(where: \.deleted) { return nil }
            var record = record
            for fix in ordered {
                if let name = fix.className?.trimmingCharacters(in: .whitespaces), !name.isEmpty { paper.className = name }
                if let kind = fix.kind { paper.kind = kind }
                if let note = fix.note {
                    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    paper.note = trimmed.isEmpty ? nil : trimmed
                }
                if record.isManual, let start = fix.start ?? paper.start, let end = fix.end ?? paper.end,
                   fix.start != nil || fix.end != nil {
                    let span = ManualSitting.span(start: start, end: end)
                    paper.spans = [span]
                    record = IntervalRecord(
                        id: record.id, kind: record.kind, startedAt: span.start,
                        elapsedSeconds: Int(span.duration.rounded()), completed: record.completed,
                        focus: record.focus, paper: paper, manual: record.manual
                    )
                }
            }
            record.paper = paper
            return record
        }
    }

    /// Every paper sitting, corrections applied, oldest first.
    public static func sittings(records: [IntervalRecord], corrections: [PaperCorrection]) -> [PaperSittingView] {
        apply(corrections, to: records)
            .compactMap { record -> PaperSittingView? in
                guard record.kind == .work, let paper = record.paper, !paper.spans.isEmpty else { return nil }
                return PaperSittingView(
                    id: record.id,
                    className: paper.className,
                    kind: paper.kind,
                    note: paper.note,
                    spans: paper.spans.sorted { $0.start < $1.start },
                    manual: record.isManual,
                    seconds: record.isManual ? Int(paper.seconds.rounded()) : record.elapsedSeconds
                )
            }
            .sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
    }

    /// Paper seconds per class over the calendar-day window, most first.
    public static func totals(
        records: [IntervalRecord],
        corrections: [PaperCorrection],
        now: Date,
        calendar: Calendar,
        days: Int
    ) -> [(className: String, seconds: Int)] {
        guard let start = AnalyticsAggregator.startOfWindow(now: now, calendar: calendar, days: days) else { return [] }
        var totals: [String: Int] = [:]
        for sitting in sittings(records: records, corrections: corrections) where sitting.start >= start {
            totals[sitting.className, default: 0] += sitting.seconds
        }
        return totals
            .map { (className: $0.key, seconds: $0.value) }
            .sorted { $0.seconds == $1.seconds ? $0.className < $1.className : $0.seconds > $1.seconds }
    }

    /// `Data 1h 05m · Econ 25m` — today's Paper line; nil when there is none.
    public static func lineText(_ totals: [(className: String, seconds: Int)]) -> String? {
        guard !totals.isEmpty else { return nil }
        return totals.map { "\(PaperTag.shortClass($0.className)) \(durationText($0.seconds))" }.joined(separator: " · ")
    }

    /// `1h 05m`, or `25m` under an hour.
    public static func durationText(_ seconds: Int) -> String {
        let minutes = (seconds + 30) / 60
        return minutes >= 60 ? String(format: "%dh %02dm", minutes / 60, minutes % 60) : "\(minutes)m"
    }

    /// The last `days` calendar days of sittings, newest first, for the sittings list.
    public static func recent(
        records: [IntervalRecord],
        corrections: [PaperCorrection],
        now: Date,
        calendar: Calendar,
        days: Int = 14
    ) -> [PaperSittingView] {
        guard let start = AnalyticsAggregator.startOfWindow(now: now, calendar: calendar, days: days) else { return [] }
        return sittings(records: records, corrections: corrections).filter { $0.start >= start }.reversed()
    }

    /// Corrections merged by id, oldest first; kept as long as paper records are.
    public static func mergeCorrections(local: [PaperCorrection], remote: [PaperCorrection], now: Date, calendar: Calendar) -> [PaperCorrection] {
        var seen = Set(local.map(\.id))
        var merged = local
        for c in remote where !seen.contains(c.id) {
            seen.insert(c.id)
            merged.append(c)
        }
        merged.sort { $0.modifiedAt == $1.modifiedAt ? $0.id.uuidString < $1.id.uuidString : $0.modifiedAt < $1.modifiedAt }
        guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: calendar.startOfDay(for: now)) else { return merged }
        return merged.filter { $0.modifiedAt >= cutoff }
    }
}

// MARK: - Manual sittings

/// A past sitting logged by hand, the "Log a past sitting" of the old Shortcut.
public enum ManualSitting {

    /// `end` earlier than `start` means the sitting ran past midnight.
    public static func span(start: Date, end: Date, calendar: Calendar = .current) -> DateInterval {
        var end = end
        while end < start, let next = calendar.date(byAdding: .day, value: 1, to: end) {
            end = next
        }
        return DateInterval(start: start, end: max(start, end))
    }

    /// `end` taken as a time of day on `start`'s day (the sheet's default), rolled past midnight if
    /// it falls before `start`.
    public static func span(start: Date, endTimeOf endTime: Date, calendar: Calendar = .current) -> DateInterval {
        let parts = calendar.dateComponents([.hour, .minute], from: endTime)
        let sameDay = calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: start) ?? endTime
        return span(start: start, end: sameDay, calendar: calendar)
    }

    /// The Work record for a past sitting: paper set, never completed (so never a rep), no focus,
    /// marked manual so it adds paper time but no work time to the analytics.
    public static func record(tag: PaperTag, span: DateInterval, id: UUID = UUID()) -> IntervalRecord {
        IntervalRecord(
            id: id,
            kind: .work,
            startedAt: span.start,
            elapsedSeconds: Int(span.duration.rounded()),
            completed: false,
            focus: nil,
            paper: PaperSitting(tag: tag, spans: [span]),
            manual: true
        )
    }
}

// MARK: - Settings

public enum PaperDefaults {
    /// The class folders of term 2026-B. The names must match the folders exactly: the vault totals
    /// match on them.
    public static let classes = ["Data - POGO 511", "Econ - PUBP 720", "RD - POGO 801"]
}

// MARK: - Stores

/// Where this device keeps its paper tag between launches. The tag is per device, never synced.
public protocol PaperTagStoring: Sendable {
    func load() -> PaperTag?
    func save(_ tag: PaperTag?)
}

/// The tag as one JSON blob under one key of an injected `UserDefaults`.
public final class UserDefaultsPaperTagStore: PaperTagStoring, @unchecked Sendable {
    public static let defaultKey = "paperTag.v1"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> PaperTag? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PaperTag.self, from: data)
    }

    public func save(_ tag: PaperTag?) {
        guard let tag, let data = try? JSONEncoder().encode(tag) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}

/// Where the paper corrections live: a list of their own beside the history, merged by id.
public protocol PaperCorrectionStoring: Sendable {
    func load() -> [PaperCorrection]
    func replace(with corrections: [PaperCorrection]) throws
}

extension PaperCorrectionStoring {
    /// Adds corrections (merged by id) and returns the full list written.
    @discardableResult
    public func add(_ new: [PaperCorrection], now: Date, calendar: Calendar = .current) throws -> [PaperCorrection] {
        let merged = PaperHistory.mergeCorrections(local: load(), remote: new, now: now, calendar: calendar)
        try replace(with: merged)
        return merged
    }
}

/// `paper-corrections.json` beside the interval history, written atomically.
public struct FilePaperCorrectionStore: PaperCorrectionStoring {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func applicationSupportURL() throws -> URL {
        try FileIntervalStore.applicationSupportURL()
            .deletingLastPathComponent()
            .appendingPathComponent("paper-corrections.json", isDirectory: false)
    }

    public func load() -> [PaperCorrection] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PaperCorrection].self, from: data)) ?? []
    }

    public func replace(with corrections: [PaperCorrection]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(corrections).write(to: url, options: .atomic)
    }
}

public final class MemoryPaperCorrectionStore: PaperCorrectionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var corrections: [PaperCorrection]

    public init(corrections: [PaperCorrection] = []) {
        self.corrections = corrections
    }

    public func load() -> [PaperCorrection] {
        lock.withLock { corrections }
    }

    public func replace(with new: [PaperCorrection]) throws {
        lock.withLock { corrections = new }
    }
}
