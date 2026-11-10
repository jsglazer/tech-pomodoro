import Foundation

// MARK: - Projects

/// Where a note belongs: its area (a class) and its task (an assignment, Inventory, …), both as
/// vault-relative folder paths. A note with no matching task rule has its area as its task.
public struct FocusProject: Hashable, Codable, Sendable {
    public let area: String
    public let task: String

    public init(area: String, task: String) {
        self.area = area
        self.task = task
    }

    /// The project at the given drift level: the task itself, or the area standing in for it.
    public func at(_ level: DriftLevel) -> FocusProject {
        level == .task ? self : FocusProject(area: area, task: area)
    }

    public var areaName: String { Self.lastComponent(area) }
    public var taskName: String { Self.lastComponent(task) }

    /// `RD - POGO 801 › Asgn03-TheoryHypotheses`, or just the area when the task is the area.
    public var displayName: String {
        task == area ? areaName : "\(areaName) › \(taskName)"
    }

    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? (path.isEmpty ? "(vault root)" : path)
    }
}

/// Maps a vault-relative note path onto its project through the folder-glob rules.
///
/// A rule is a folder path whose segments may hold `*` (any run of characters inside one segment)
/// and `?`. It matches a note that sits somewhere *inside* the folder it names, and yields that
/// folder: `Classes/*/*` maps `Classes/2026-B/Econ/Inventory/x.md` to `Classes/2026-B/Econ`.
public enum FocusRules {

    public static func project(forFile file: String, settings: FocusSettings) -> FocusProject {
        let segments = file.split(separator: "/").map(String.init)
        let area = firstMatch(settings.areaRules, segments) ?? defaultArea(segments)
        let task = firstMatch(settings.taskRules, segments) ?? area
        return FocusProject(area: area, task: task)
    }

    static func firstMatch(_ rules: [String], _ segments: [String]) -> String? {
        for rule in rules {
            if let folder = match(rule: rule, segments: segments) { return folder }
        }
        return nil
    }

    /// The folder `rule` names, when the note at `segments` sits inside it.
    static func match(rule: String, segments: [String]) -> String? {
        let pattern = rule.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        // Strictly fewer pattern segments than path segments: the last path segment is the file.
        guard !pattern.isEmpty, pattern.count < segments.count else { return nil }
        for (p, s) in zip(pattern, segments) where !wildcard(p, matches: s) {
            return nil
        }
        return segments.prefix(pattern.count).joined(separator: "/")
    }

    /// A note outside every rule is filed under its top-level folder, or the vault root.
    static func defaultArea(_ segments: [String]) -> String {
        segments.count > 1 ? segments[0] : ""
    }

    /// Case-insensitive glob over one path segment: `*` is any run, `?` any one character.
    static func wildcard(_ pattern: String, matches text: String) -> Bool {
        let p = Array(pattern.lowercased())
        let t = Array(text.lowercased())
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

// MARK: - Activity

/// One span of a focused app window, from aw-watcher-window. Browsers also carry the tab's URL.
public struct WindowSpan: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let app: String
    public let title: String
    public let url: String?

    public init(start: Date, end: Date, app: String, title: String, url: String? = nil) {
        self.start = start
        self.end = end
        self.app = app
        self.title = title
        self.url = url
    }
}

/// One span on a note, from link-activitywatcher. `file` is vault-relative with a leading `/`.
public struct NoteSpan: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let file: String

    public init(start: Date, end: Date, file: String) {
        self.start = start
        self.end = end
        self.file = file
    }
}

/// A span aw-watcher-afk marked as away.
public struct AwaySpan: Sendable, Equatable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

/// Everything ActivityWatch knows about a stretch of time, as plain values.
public struct FocusActivity: Sendable, Equatable {
    public var windows: [WindowSpan]
    public var notes: [NoteSpan]
    public var away: [AwaySpan]
    /// The front app's open documents, from TechPomodoro's own document sensor.
    public var documents: [DocumentSpan]

    public init(windows: [WindowSpan] = [], notes: [NoteSpan] = [], away: [AwaySpan] = [], documents: [DocumentSpan] = []) {
        self.windows = windows
        self.notes = notes
        self.away = away
        self.documents = documents
    }
}

/// What a moment of activity counts as.
public enum FocusCategory: Sendable, Equatable, Hashable {
    /// Obsidian on a note in this project, or a watched app showing a document in this project.
    case project(FocusProject)
    /// An on-task app, an allowed site, or a PDF: counts toward the anchor, whatever it is.
    case support(String)
    /// Anything else, labelled by app or host.
    case distraction(String)
    /// Away, locked, or this app's own alert: neither counts nor drifts.
    case neutral

    /// `Google Chrome (youtube.com)`-style label for the popover and the alert.
    public var label: String {
        switch self {
        case .project(let p): return p.displayName
        case .support(let s): return s
        case .distraction(let d): return d
        case .neutral: return "—"
        }
    }
}

public enum FocusClassifier {

    public static func category(
        window: WindowSpan,
        note: NoteSpan?,
        documents: [String] = [],
        settings: FocusSettings
    ) -> FocusCategory {
        let app = window.app
        if contains(settings.neutralApps, app) { return .neutral }
        // A watched app showing a document inside a project folder counts toward that project; a
        // document outside every rule falls through to the on-task / PDF rules below, as before.
        if let path = FocusRules.document(for: window, among: documents),
           let project = FocusRules.project(forDocument: path, settings: settings) {
            return .project(project)
        }
        if app.caseInsensitiveCompare("Obsidian") == .orderedSame {
            // Obsidian focused with no note reported yet: nothing to judge it by.
            guard let note else { return .neutral }
            return .project(FocusRules.project(forFile: note.file, settings: settings))
        }
        if contains(settings.onTaskApps, app) { return .support(app) }
        if let url = window.url, !url.isEmpty {
            if isPDF(url: url, title: window.title) { return .support("PDF") }
            let host = URLComponents(string: url)?.host?.lowercased()
            if isAllowed(url: url, sites: settings.allowedSites) { return .support(host ?? app) }
            return .distraction(host.map { "\(app) (\($0))" } ?? app)
        }
        return .distraction(app)
    }

    static func contains(_ names: [String], _ app: String) -> Bool {
        names.contains { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(app) == .orderedSame }
    }

    static func isPDF(url: String, title: String) -> Bool {
        let path = URLComponents(string: url)?.path.lowercased() ?? ""
        return path.hasSuffix(".pdf") || title.lowercased().hasSuffix(".pdf")
    }

    /// An entry is `host` or `host/path-prefix`, with or without a scheme. The host also covers its
    /// subdomains, so `gmu.edu` would allow `library.gmu.edu`.
    static func isAllowed(url: String, sites: [String]) -> Bool {
        guard let components = URLComponents(string: url), let host = components.host?.lowercased() else {
            return false
        }
        let path = components.path.lowercased()
        for raw in sites {
            var entry = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if let scheme = entry.range(of: "://") { entry = String(entry[scheme.upperBound...]) }
            guard !entry.isEmpty else { continue }
            let parts = entry.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let entryHost = String(parts[0])
            let entryPath = parts.count > 1 ? "/" + parts[1] : ""
            guard host == entryHost || host.hasSuffix("." + entryHost) else { continue }
            if entryPath.isEmpty || entryPath == "/" || path.hasPrefix(entryPath) { return true }
        }
        return false
    }
}

// MARK: - Tracking

/// A contiguous stretch of one category.
public struct FocusRun: Sendable, Equatable {
    public let category: FocusCategory
    public let start: Date
    public let end: Date

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// The focus picture of one Work interval so far.
public struct FocusSnapshot: Sendable, Equatable {
    /// The project this interval is about, at the drift level. Nil until any project time exists.
    public var anchor: FocusProject?
    /// True once the opening window has passed (or the anchor was chosen by hand), so drift to
    /// another project now counts.
    public var anchorIsLocked: Bool
    public var anchorIsManual: Bool
    /// Seconds per task-level project.
    public var projectSeconds: [FocusProject: TimeInterval]
    public var supportSeconds: TimeInterval
    public var distractionSeconds: TimeInterval
    public var neutralSeconds: TimeInterval
    /// Changes between projects, or between work and distraction. Neutral time is ignored.
    public var switches: Int
    /// The current unbroken stretch off the anchor; neutral time pauses it rather than ending it.
    public var offAnchorSeconds: TimeInterval
    /// What you are on right now.
    public var current: FocusCategory
    public var runs: [FocusRun]
    /// The paper tag's class while the Work is paper time. The anchor is then pinned to that class:
    /// any note whose area's last folder is the class is on task, at either drift level.
    public var paperClass: String?

    public static let empty = FocusSnapshot(
        anchor: nil, anchorIsLocked: false, anchorIsManual: false, projectSeconds: [:],
        supportSeconds: 0, distractionSeconds: 0, neutralSeconds: 0, switches: 0,
        offAnchorSeconds: 0, current: .neutral, runs: []
    )

    public init(
        anchor: FocusProject?, anchorIsLocked: Bool, anchorIsManual: Bool,
        projectSeconds: [FocusProject: TimeInterval], supportSeconds: TimeInterval,
        distractionSeconds: TimeInterval, neutralSeconds: TimeInterval, switches: Int,
        offAnchorSeconds: TimeInterval, current: FocusCategory, runs: [FocusRun], paperClass: String? = nil
    ) {
        self.anchor = anchor
        self.anchorIsLocked = anchorIsLocked
        self.anchorIsManual = anchorIsManual
        self.projectSeconds = projectSeconds
        self.supportSeconds = supportSeconds
        self.distractionSeconds = distractionSeconds
        self.neutralSeconds = neutralSeconds
        self.switches = switches
        self.offAnchorSeconds = offAnchorSeconds
        self.current = current
        self.runs = runs
        self.paperClass = paperClass
    }

    /// Whether a project counts as the anchor.
    public func isOnAnchor(_ project: FocusProject, level: DriftLevel) -> Bool {
        if let paperClass { return FocusTracker.areaMatches(project, className: paperClass) }
        guard let anchor else { return false }
        return project.at(level) == anchor
    }

    /// Seconds on the anchor (at the drift level) plus on-task support time.
    public func anchorSeconds(level: DriftLevel) -> TimeInterval {
        guard anchor != nil || paperClass != nil else { return 0 }
        let onAnchor = projectSeconds.filter { isOnAnchor($0.key, level: level) }.values.reduce(0, +)
        return onAnchor + supportSeconds
    }

    /// Share of the counted time spent on the anchor, `0...1`; nil before anything counted.
    public func focusShare(level: DriftLevel) -> Double? {
        let counted = projectSeconds.values.reduce(0, +) + supportSeconds + distractionSeconds
        guard counted > 0 else { return nil }
        return min(1, anchorSeconds(level: level) / counted)
    }

    public var isDrifting: Bool { offAnchorSeconds > 0 }

    /// The record kept with the Work interval.
    public func summary(level: DriftLevel, driftAlerts: Int) -> FocusSummary {
        var byTask: [String: Int] = [:]
        for (project, seconds) in projectSeconds {
            byTask[project.task, default: 0] += Int(seconds.rounded())
        }
        return FocusSummary(
            anchorArea: anchor?.area,
            anchorTask: anchor?.task,
            focusShare: focusShare(level: level),
            switches: switches,
            projectSeconds: byTask,
            supportSeconds: Int(supportSeconds.rounded()),
            distractionSeconds: Int(distractionSeconds.rounded()),
            driftAlerts: driftAlerts,
            // Information only: on-screen time credited to the tagged class. Never added to paper time.
            paperOverlapSeconds: paperClass == nil ? nil : Int(anchorSeconds(level: level).rounded())
        )
    }
}

public enum FocusTracker {

    /// Gaps between window spans shorter than this are the watcher's own polling jitter, and are
    /// bridged rather than read as "no window".
    static let windowGapTolerance: TimeInterval = 5
    /// The newest window span is taken to still be open if it ended at most this long ago: the
    /// watcher only extends it on its next poll.
    static let liveTolerance: TimeInterval = 15

    public static func snapshot(
        activity: FocusActivity,
        from start: Date,
        to now: Date,
        settings: FocusSettings,
        manualAnchor: FocusProject? = nil,
        paused: [AwaySpan] = [],
        paperClass: String? = nil
    ) -> FocusSnapshot {
        guard now > start else { return .empty }
        // Time the timer spent paused is neutral, like away time: it counts neither way and does not
        // extend an off-anchor streak, so resuming after a pause spent elsewhere never alerts.
        var activity = activity
        activity.away += paused
        let runs = self.runs(activity: activity, from: start, to: now, settings: settings)
        let level = settings.driftLevel

        var projectSeconds: [FocusProject: TimeInterval] = [:]
        var support: TimeInterval = 0, distraction: TimeInterval = 0, neutral: TimeInterval = 0
        for run in runs {
            switch run.category {
            case .project(let p): projectSeconds[p, default: 0] += run.duration
            case .support: support += run.duration
            case .distraction: distraction += run.duration
            case .neutral: neutral += run.duration
            }
        }

        // The anchor: chosen by hand, or the leading project of the opening window. With no project
        // time in the opening window at all, the leader so far stands in, unlocked.
        let lockAt = start.addingTimeInterval(TimeInterval(settings.anchorLockMinutes * 60))
        let paperClass = paperClass.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        var anchor = manualAnchor?.at(level)
        var locked = manualAnchor != nil
        if let paperClass {
            // Paper time pins the anchor to the tagged class, locked from the start. The class's own
            // area path once a note in it has been seen; until then the bare class name.
            let seen = runs.compactMap { run -> FocusProject? in
                if case .project(let p) = run.category, areaMatches(p, className: paperClass) { return p }
                return nil
            }.first
            anchor = seen.map { FocusProject(area: $0.area, task: $0.area) } ?? FocusProject(area: paperClass, task: paperClass)
            locked = true
        } else if anchor == nil {
            if let opening = leader(runs, until: min(now, lockAt), level: level) {
                anchor = opening
                locked = now >= lockAt
            } else {
                anchor = leader(runs, until: now, level: level)
            }
        }

        func onAnchor(_ p: FocusProject) -> Bool {
            if let paperClass { return areaMatches(p, className: paperClass) }
            return p.at(level) == anchor
        }
        func key(_ c: FocusCategory) -> String? {
            switch c {
            case .project(let p):
                if paperClass != nil, onAnchor(p), let anchor { return "p:" + anchor.task }
                return "p:" + p.at(level).task
            case .support: return anchor.map { "p:" + $0.task }
            case .distraction: return "distraction"
            case .neutral: return nil
            }
        }
        func isOff(_ c: FocusCategory) -> Bool {
            switch c {
            case .distraction: return true
            case .project(let p): return locked && anchor != nil && !onAnchor(p)
            case .support, .neutral: return false
            }
        }

        var switches = 0
        var last: String?
        for run in runs {
            guard let k = key(run.category) else { continue }
            if let last, last != k { switches += 1 }
            last = k
        }

        var streak: TimeInterval = 0
        for run in runs.reversed() {
            if run.category == .neutral { continue }
            guard isOff(run.category) else { break }
            streak += run.duration
        }

        return FocusSnapshot(
            anchor: anchor,
            anchorIsLocked: locked,
            anchorIsManual: manualAnchor != nil,
            projectSeconds: projectSeconds,
            supportSeconds: support,
            distractionSeconds: distraction,
            neutralSeconds: neutral,
            switches: switches,
            offAnchorSeconds: streak,
            current: runs.last?.category ?? .neutral,
            runs: runs,
            paperClass: paperClass
        )
    }

    /// The paper tag names a class by its folder name; a focus area is a vault path. They match on the
    /// area's last folder: area `Classes/2026-B/Data - POGO 511` ↔ class `Data - POGO 511`.
    public static func areaMatches(_ project: FocusProject, className: String) -> Bool {
        project.areaName.caseInsensitiveCompare(className.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// Splits `start...now` at every span edge and categorises each piece, merging neighbours that
    /// land in the same category.
    static func runs(activity: FocusActivity, from start: Date, to now: Date, settings: FocusSettings) -> [FocusRun] {
        let windows = bridged(activity.windows, now: now)
        let notes = activity.notes.sorted { $0.start < $1.start }

        var edges: Set<Date> = [start, now]
        for w in windows { edges.insert(w.start); edges.insert(w.end) }
        for n in notes { edges.insert(n.start) }
        for a in activity.away { edges.insert(a.start); edges.insert(a.end) }
        for d in activity.documents { edges.insert(d.start) }
        let cuts = edges.filter { $0 >= start && $0 <= now }.sorted()

        var runs: [FocusRun] = []
        for (a, b) in zip(cuts, cuts.dropFirst()) where b > a {
            let mid = a.addingTimeInterval(b.timeIntervalSince(a) / 2)
            let category = self.category(
                at: mid, windows: windows, notes: notes, away: activity.away, documents: activity.documents, settings: settings
            )
            if let previous = runs.last, previous.category == category {
                runs[runs.count - 1] = FocusRun(category: category, start: previous.start, end: b)
            } else {
                runs.append(FocusRun(category: category, start: a, end: b))
            }
        }
        return runs
    }

    static func category(
        at t: Date,
        windows: [WindowSpan],
        notes: [NoteSpan],
        away: [AwaySpan],
        documents: [DocumentSpan] = [],
        settings: FocusSettings
    ) -> FocusCategory {
        if away.contains(where: { $0.start <= t && t < $0.end }) { return .neutral }
        guard let window = windows.last(where: { $0.start <= t && t < $0.end }) else { return .neutral }
        // The note open at `t` is the newest one reported by then: the plugin goes quiet while you
        // read without typing, but the note is still the one on screen.
        let note = notes.last { $0.start <= t }
        // The documents the sensor saw for this app around `t` (its event is extended each sample,
        // so allow the live tolerance past its end, as for windows).
        let docs = documents.last {
            $0.app.caseInsensitiveCompare(window.app) == .orderedSame
                && $0.start <= t && t < $0.end.addingTimeInterval(liveTolerance)
        }?.paths ?? []
        return FocusClassifier.category(window: window, note: note, documents: docs, settings: settings)
    }

    /// Sorts the window spans, closes polling-jitter gaps, and holds the newest span open to `now`.
    static func bridged(_ spans: [WindowSpan], now: Date) -> [WindowSpan] {
        let sorted = spans.sorted { $0.start < $1.start }
        var out: [WindowSpan] = []
        for (i, s) in sorted.enumerated() {
            var end = s.end
            if i + 1 < sorted.count {
                let next = sorted[i + 1].start
                if next > end, next.timeIntervalSince(end) <= windowGapTolerance { end = next }
            } else if now > end, now.timeIntervalSince(end) <= liveTolerance {
                end = now
            }
            out.append(WindowSpan(start: s.start, end: end, app: s.app, title: s.title, url: s.url))
        }
        return out
    }

    /// The project with the most time before `until`, at the drift level.
    static func leader(_ runs: [FocusRun], until: Date, level: DriftLevel) -> FocusProject? {
        var totals: [FocusProject: TimeInterval] = [:]
        for run in runs where run.start < until {
            guard case .project(let p) = run.category else { continue }
            let end = min(run.end, until)
            totals[p.at(level), default: 0] += end.timeIntervalSince(run.start)
        }
        // Ties break on the path, so the anchor never flickers between equal projects.
        return totals.max { $0.value == $1.value ? $0.key.task > $1.key.task : $0.value < $1.value }?.key
    }
}

// MARK: - History

/// The focus record kept with a Work interval.
public struct FocusSummary: Codable, Sendable, Equatable {
    public var anchorArea: String?
    public var anchorTask: String?
    public var focusShare: Double?
    public var switches: Int
    /// Seconds per task folder.
    public var projectSeconds: [String: Int]
    public var supportSeconds: Int
    public var distractionSeconds: Int
    public var driftAlerts: Int
    /// Paper Work only: seconds of on-screen activity credited to the tagged class during the record.
    /// Information only — never added to paper time (a tagged span counts once, for the tagged class).
    /// Optional, so older decoders and older history are unaffected.
    public var paperOverlapSeconds: Int?

    public init(
        anchorArea: String?,
        anchorTask: String?,
        focusShare: Double?,
        switches: Int,
        projectSeconds: [String: Int],
        supportSeconds: Int,
        distractionSeconds: Int,
        driftAlerts: Int,
        paperOverlapSeconds: Int? = nil
    ) {
        self.anchorArea = anchorArea
        self.anchorTask = anchorTask
        self.focusShare = focusShare
        self.switches = switches
        self.projectSeconds = projectSeconds
        self.supportSeconds = supportSeconds
        self.distractionSeconds = distractionSeconds
        self.driftAlerts = driftAlerts
        self.paperOverlapSeconds = paperOverlapSeconds
    }

    /// `Asgn03-TheoryHypotheses · 78% · 3 switches` — the end-of-interval line.
    public var lineText: String {
        let name = anchorTask.map(FocusProject.lastComponent) ?? "No project"
        let share = focusShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        return "\(name) · \(share) · \(switches) \(switches == 1 ? "switch" : "switches")"
    }
}

public struct ProjectTotal: Sendable, Equatable, Identifiable {
    public let task: String
    public let seconds: Int
    public var id: String { task }
    public var name: String { FocusProject.lastComponent(task) }
}

public enum FocusAnalytics {

    /// Seconds per task over the calendar-day window, most first.
    public static func projectTotals(
        records: [IntervalRecord],
        now: Date,
        calendar: Calendar,
        days: Int
    ) -> [ProjectTotal] {
        guard let start = AnalyticsAggregator.startOfWindow(now: now, calendar: calendar, days: days) else { return [] }
        var totals: [String: Int] = [:]
        for record in records where record.kind == .work && record.startedAt >= start {
            for (task, seconds) in record.focus?.projectSeconds ?? [:] {
                totals[task, default: 0] += seconds
            }
        }
        return totals
            .map { ProjectTotal(task: $0.key, seconds: $0.value) }
            .sorted { $0.seconds == $1.seconds ? $0.task < $1.task : $0.seconds > $1.seconds }
    }

    /// Mean focus share over the window's tracked Work intervals, or nil when none were tracked.
    public static func meanFocusShare(records: [IntervalRecord], now: Date, calendar: Calendar, days: Int) -> Double? {
        guard let start = AnalyticsAggregator.startOfWindow(now: now, calendar: calendar, days: days) else { return nil }
        let shares = records.compactMap { $0.kind == .work && $0.startedAt >= start ? $0.focus?.focusShare : nil }
        guard !shares.isEmpty else { return nil }
        return shares.reduce(0, +) / Double(shares.count)
    }
}

// MARK: - ActivityWatch wire format

/// Decodes aw-server event lists into the plain spans above. Pure, so the wire format is pinned by
/// tests against captured JSON.
public enum ActivityWatchParser {

    private struct Event: Decodable {
        let timestamp: String
        let duration: Double
        let data: [String: JSONValue]
    }

    private enum JSONValue: Decodable {
        case string(String)
        case other

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .string(s) } else { self = .other }
        }

        var string: String? {
            if case .string(let s) = self { return s }
            return nil
        }
    }

    private static func events(_ data: Data) throws -> [(start: Date, end: Date, data: [String: JSONValue])] {
        try JSONDecoder().decode([Event].self, from: data).compactMap { e in
            guard let start = date(e.timestamp) else { return nil }
            return (start, start.addingTimeInterval(max(0, e.duration)), e.data)
        }
    }

    public static func windows(_ data: Data) throws -> [WindowSpan] {
        try events(data).map {
            WindowSpan(
                start: $0.start,
                end: $0.end,
                app: $0.data["app"]?.string ?? "",
                title: $0.data["title"]?.string ?? "",
                url: $0.data["url"]?.string
            )
        }
    }

    public static func notes(_ data: Data) throws -> [NoteSpan] {
        try events(data).compactMap { e in
            guard let file = e.data["file"]?.string else { return nil }
            return NoteSpan(start: e.start, end: e.end, file: file)
        }
    }

    /// Events from the documents bucket (`app`, `bundle_id`, `count`, `paths`).
    public static func documents(_ data: Data) throws -> [DocumentSpan] {
        struct DocEvent: Decodable {
            struct Payload: Decodable {
                let app: String?
                let paths: [String]?
            }
            let timestamp: String
            let duration: Double
            let data: Payload
        }
        return try JSONDecoder().decode([DocEvent].self, from: data).compactMap { e in
            guard let start = date(e.timestamp), let app = e.data.app else { return nil }
            return DocumentSpan(start: start, end: start.addingTimeInterval(max(0, e.duration)), app: app, paths: e.data.paths ?? [])
        }
    }

    public static func away(_ data: Data) throws -> [AwaySpan] {
        try events(data).compactMap { e in
            e.data["status"]?.string == "afk" ? AwaySpan(start: e.start, end: e.end) : nil
        }
    }

    /// Bucket ids from `GET /api/0/buckets/`, newest-updated first.
    public static func bucketIDs(_ data: Data) throws -> [String] {
        struct Bucket: Decodable { let id: String; let last_updated: String? }
        let buckets = try JSONDecoder().decode([String: Bucket].self, from: data)
        return buckets.values
            .sorted { ($0.last_updated ?? "") > ($1.last_updated ?? "") }
            .map(\.id)
    }

    /// aw-server writes microseconds (`2026-10-30T22:40:05.117000+00:00`), which
    /// `ISO8601DateFormatter` does not reliably read, so the fraction is cut to milliseconds first.
    static func date(_ s: String) -> Date? {
        var text = s
        if let dot = text.firstIndex(of: ".") {
            let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
            let fractionEnd = text.index(dot, offsetBy: digits.count + 1)
            text.replaceSubrange(text.index(after: dot)..<fractionEnd, with: String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = text.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

// MARK: - Menu bar

extension MenuBarFormatter {

    /// The ordinary presentation, repainted in the drift colour while a running Work interval is off
    /// its anchor. Drift outranks the threshold colours: it is the one signal you can act on now.
    public static func presentation(for state: PomodoroState, at now: Date, focus: FocusSnapshot?) -> MenuBarPresentation {
        var presentation = presentation(for: state, at: now)
        guard let focus, focus.isDrifting, state.activity == .running, state.phase == .work else {
            return presentation
        }
        presentation.customForegroundHex = state.settings.focus.driftColorHex
        presentation.adaptsToMenuBar = false
        return presentation
    }

    /// The hover readout with the anchor named in the title during Work, e.g. `Work — Asgn03-…`.
    public static func hoverInfo(for state: PomodoroState, at now: Date, focus: FocusSnapshot?) -> HoverInfo {
        let info = hoverInfo(for: state, at: now)
        // Paper Work already names its class; the pinned anchor would only repeat it.
        guard let anchor = focus?.anchor, state.activity != .idle, state.phase == .work, state.paperTag == nil else { return info }
        return HoverInfo(title: "\(info.title) — \(anchor.taskName)", detail: info.detail)
    }
}
