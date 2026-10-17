import Foundation

/// Sessions, cycles and reps completed, and seconds worked, inside one rolling window.
public struct AnalyticsWindow: Sendable, Equatable {
    public let sessions: Int
    public let cycles: Int
    /// Work intervals that ran to their end. One cut short by Stop or Skip still adds its time to
    /// `workSeconds`, but is not a rep.
    public let reps: Int
    public let workSeconds: Int

    public init(sessions: Int = 0, cycles: Int, reps: Int = 0, workSeconds: Int) {
        self.sessions = sessions
        self.cycles = cycles
        self.reps = reps
        self.workSeconds = workSeconds
    }

    /// `1 sess · 3 cyc · 9 reps · 3h 45m` — the one-line form both apps show.
    public var summaryText: String {
        "\(sessions) sess · \(cycles) cyc · \(reps) \(reps == 1 ? "rep" : "reps") · \(workDurationText)"
    }

    /// `1h 25m`, or `18m` under an hour — the form the popover shows.
    public var workDurationText: String {
        let hours = workSeconds / 3600
        let minutes = (workSeconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

public struct AnalyticsSummary: Sendable, Equatable {
    public let today: AnalyticsWindow
    public let lastThreeDays: AnalyticsWindow
    public let lastFiveDays: AnalyticsWindow

    public static let empty = AnalyticsSummary(
        today: AnalyticsWindow(sessions: 0, cycles: 0, workSeconds: 0),
        lastThreeDays: AnalyticsWindow(sessions: 0, cycles: 0, workSeconds: 0),
        lastFiveDays: AnalyticsWindow(sessions: 0, cycles: 0, workSeconds: 0)
    )

    public init(today: AnalyticsWindow, lastThreeDays: AnalyticsWindow, lastFiveDays: AnalyticsWindow) {
        self.today = today
        self.lastThreeDays = lastThreeDays
        self.lastFiveDays = lastFiveDays
    }
}

/// Pure aggregation over the interval history.
///
/// The windows are *calendar days in the supplied calendar's timezone*, not trailing 72/120-hour
/// spans: "Last 3 days" is today plus the two prior calendar days, inclusive. Passing the calendar in
/// keeps midnight and DST behaviour under a test's control.
public enum AnalyticsAggregator {

    public static func summarize(
        records: [IntervalRecord],
        now: Date,
        calendar: Calendar
    ) -> AnalyticsSummary {
        AnalyticsSummary(
            today: window(records: records, now: now, calendar: calendar, days: 1),
            lastThreeDays: window(records: records, now: now, calendar: calendar, days: 3),
            lastFiveDays: window(records: records, now: now, calendar: calendar, days: 5)
        )
    }

    /// Records on or after the start of the calendar day `days - 1` days before today.
    public static func window(
        records: [IntervalRecord],
        now: Date,
        calendar: Calendar,
        days: Int
    ) -> AnalyticsWindow {
        guard let start = startOfWindow(now: now, calendar: calendar, days: days) else {
            return AnalyticsWindow(sessions: 0, cycles: 0, workSeconds: 0)
        }
        var sessions = 0
        var cycles = 0
        var reps = 0
        var seconds = 0
        for record in records where record.startedAt >= start {
            switch record.kind {
            case .work:
                seconds += record.elapsedSeconds
                if record.completed { reps += 1 }
            case .cycleCompleted: cycles += 1
            case .sessionCompleted: sessions += 1
            }
        }
        return AnalyticsWindow(sessions: sessions, cycles: cycles, reps: reps, workSeconds: seconds)
    }

    /// Midnight at the head of the window.
    public static func startOfWindow(now: Date, calendar: Calendar, days: Int) -> Date? {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today)
    }

    /// Drops records older than the retention horizon, counted in calendar days. Applied on every
    /// write so the history file cannot grow without bound.
    public static func prune(
        _ records: [IntervalRecord],
        now: Date,
        calendar: Calendar,
        retentionDays: Int = 30
    ) -> [IntervalRecord] {
        guard let cutoff = calendar.date(
            byAdding: .day,
            value: -max(0, retentionDays),
            to: calendar.startOfDay(for: now)
        ) else {
            return records
        }
        return records.filter { $0.startedAt >= cutoff }
    }
}
