import Foundation

// The paper stopwatch: paper time tracked without the Pomodoro timer. It counts up from Track until
// Stop, with no countdown, no breaks and no reps; Pause ends a stretch and Resume starts the next.
// Stop saves the stretches as one paper sitting — a manual Work record, so it adds paper time but no
// work time, exactly like a past sitting logged by hand. Per device runtime state, never synced: only
// the saved sitting syncs.

public struct PaperStopwatch: Codable, Sendable, Equatable {
    /// What the sitting is filed under. Editing the paper tag while tracking retags it.
    public var tag: PaperTag
    /// The closed stretches (a pause ends one).
    public var spans: [DateInterval]
    /// Start of the stretch running now; nil while paused.
    public var runningSince: Date?

    public init(tag: PaperTag, startedAt: Date) {
        self.tag = tag
        self.spans = []
        self.runningSince = startedAt
    }

    public var isRunning: Bool { runningSince != nil }

    /// The stretches up to `now`, the running one included.
    public func spans(at now: Date) -> [DateInterval] {
        guard let open = runningSince, now > open else { return spans }
        return spans + [DateInterval(start: open, end: now)]
    }

    /// Seconds tracked so far.
    public func seconds(at now: Date) -> TimeInterval {
        spans(at: now).reduce(0) { $0 + $1.duration }
    }

    public mutating func pause(at now: Date) {
        guard let open = runningSince else { return }
        if now > open { spans.append(DateInterval(start: open, end: now)) }
        runningSince = nil
    }

    public mutating func resume(at now: Date) {
        guard runningSince == nil else { return }
        runningSince = now
    }

    /// The sitting Stop saves: a manual paper Work record of the tracked stretches. Nil when nothing
    /// was tracked (under a second).
    public func record(at now: Date, id: UUID = UUID()) -> IntervalRecord? {
        let spans = self.spans(at: now).filter { $0.duration > 0 }
        let total = spans.reduce(0) { $0 + $1.duration }
        guard let start = spans.map(\.start).min(), total >= 1 else { return nil }
        return IntervalRecord(
            id: id,
            kind: .work,
            startedAt: start,
            elapsedSeconds: Int(total.rounded()),
            completed: false,
            focus: nil,
            paper: PaperSitting(tag: tag, spans: spans),
            manual: true
        )
    }

    /// `12:05` under an hour, `1:02:05` from an hour.
    public static func elapsedText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Store

/// Where this device keeps a stopwatch in progress, so it survives a relaunch.
public protocol PaperStopwatchStoring: Sendable {
    func load() -> PaperStopwatch?
    func save(_ stopwatch: PaperStopwatch?)
}

/// The stopwatch as one JSON blob under one key of an injected `UserDefaults`.
public final class UserDefaultsPaperStopwatchStore: PaperStopwatchStoring, @unchecked Sendable {
    public static let defaultKey = "paperStopwatch.v1"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> PaperStopwatch? {
        guard let data = defaults.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PaperStopwatch.self, from: data)
    }

    public func save(_ stopwatch: PaperStopwatch?) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let stopwatch, let data = try? encoder.encode(stopwatch) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}

public final class MemoryPaperStopwatchStore: PaperStopwatchStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stopwatch: PaperStopwatch?

    public init(stopwatch: PaperStopwatch? = nil) {
        self.stopwatch = stopwatch
    }

    public func load() -> PaperStopwatch? { lock.withLock { stopwatch } }
    public func save(_ new: PaperStopwatch?) { lock.withLock { stopwatch = new } }
}

// MARK: - Menu bar

extension MenuBarFormatter {

    /// The menu bar while the stopwatch tracks and the timer is idle: a stopwatch symbol and the
    /// minutes so far, e.g. `12m`; red while paused, as a paused timer is.
    public static func stopwatchPresentation(_ stopwatch: PaperStopwatch, at now: Date, settings: PomodoroSettings) -> MenuBarPresentation {
        let minutes = Int(stopwatch.seconds(at: now)) / 60
        return MenuBarPresentation(
            text: minutes >= 60 ? String(format: "%d:%02d", minutes / 60, minutes % 60) : "\(minutes)m",
            symbolName: stopwatch.isRunning ? "stopwatch" : "pause.circle",
            foreground: stopwatch.isRunning ? .primaryText : .alert,
            background: settings.useCustomBackground ? .background : nil,
            adaptsToMenuBar: false
        )
    }
}
