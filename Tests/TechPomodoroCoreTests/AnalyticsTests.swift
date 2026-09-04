import Foundation
import Testing
@testable import TechPomodoroCore

@Suite("Rolling analytics windows")
struct AnalyticsTests {

    private func work(_ date: Date, minutes: Int, completed: Bool = true) -> IntervalRecord {
        IntervalRecord(kind: .work, startedAt: date, elapsedSeconds: minutes * 60, completed: completed)
    }

    private func cycle(_ date: Date) -> IntervalRecord {
        IntervalRecord(kind: .cycleCompleted, startedAt: date, elapsedSeconds: 0, completed: true)
    }

    @Test("Today counts only the current calendar day")
    func todayIsOneCalendarDay() {
        let records = [
            work(Fixture.start, minutes: 25),
            work(Fixture.start.plus(minutes: -60 * 12), minutes: 25),   // 9pm yesterday
            work(Fixture.start.plus(minutes: 60), minutes: 25)
        ]
        let summary = AnalyticsAggregator.summarize(records: records, now: Fixture.start.plus(minutes: 120), calendar: Fixture.calendar)

        #expect(summary.today.workSeconds == 50 * 60)
        #expect(summary.lastThreeDays.workSeconds == 75 * 60)
    }

    @Test("Last 3 days is today plus the two prior calendar days, inclusive")
    func threeDayWindowIsInclusive() {
        let day = 24.0 * 60
        let records = [
            work(Fixture.start, minutes: 10),
            work(Fixture.start.plus(minutes: -day), minutes: 10),
            work(Fixture.start.plus(minutes: -2 * day), minutes: 10),
            work(Fixture.start.plus(minutes: -3 * day), minutes: 10)
        ]
        let summary = AnalyticsAggregator.summarize(records: records, now: Fixture.start, calendar: Fixture.calendar)

        #expect(summary.today.workSeconds == 10 * 60)
        #expect(summary.lastThreeDays.workSeconds == 30 * 60)
        #expect(summary.lastFiveDays.workSeconds == 40 * 60)
    }

    @Test("A record just before midnight three days ago falls outside the 3-day window")
    func windowBoundaryIsMidnight() {
        guard let threeDaysAgoMidnight = AnalyticsAggregator.startOfWindow(now: Fixture.start, calendar: Fixture.calendar, days: 3) else {
            Issue.record("no window start")
            return
        }
        let inside = work(threeDaysAgoMidnight, minutes: 10)
        let outside = work(threeDaysAgoMidnight.plus(seconds: -1), minutes: 10)

        let summary = AnalyticsAggregator.summarize(records: [inside, outside], now: Fixture.start, calendar: Fixture.calendar)
        #expect(summary.lastThreeDays.workSeconds == 10 * 60)
        #expect(summary.lastFiveDays.workSeconds == 20 * 60)
    }

    @Test("Only cycles that reached their Long Break count")
    func cycleCountIsExplicit() {
        let records = [cycle(Fixture.start), cycle(Fixture.start.plus(minutes: 100)), work(Fixture.start, minutes: 25)]
        let summary = AnalyticsAggregator.summarize(records: records, now: Fixture.start.plus(minutes: 200), calendar: Fixture.calendar)

        #expect(summary.today.cycles == 2)
    }

    @Test("Partial work intervals count toward total work time")
    func partialsCount() {
        let records = [work(Fixture.start, minutes: 25), work(Fixture.start.plus(minutes: 40), minutes: 7, completed: false)]
        let summary = AnalyticsAggregator.summarize(records: records, now: Fixture.start.plus(minutes: 60), calendar: Fixture.calendar)

        #expect(summary.today.workSeconds == 32 * 60)
    }

    @Test("Windows survive a spring-forward DST day without losing or duplicating a day")
    func dstTransitionIsHandled() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-03-08 is the US spring-forward date.
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 9
        components.hour = 10
        let now = calendar.date(from: components)!

        let records = (0..<5).compactMap { offset -> IntervalRecord? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
            return work(day, minutes: 10)
        }
        let summary = AnalyticsAggregator.summarize(records: records, now: now, calendar: calendar)

        #expect(summary.today.workSeconds == 10 * 60)
        #expect(summary.lastThreeDays.workSeconds == 30 * 60)
        #expect(summary.lastFiveDays.workSeconds == 50 * 60)
    }

    @Test("Empty history summarises to zeroes rather than failing")
    func emptyHistory() {
        let summary = AnalyticsAggregator.summarize(records: [], now: Fixture.start, calendar: Fixture.calendar)
        #expect(summary == AnalyticsSummary.empty)
    }

    @Test("Pruning drops records older than the retention horizon and keeps the rest")
    func pruningHorizon() {
        let day = 24.0 * 60
        let records = [
            work(Fixture.start, minutes: 10),
            work(Fixture.start.plus(minutes: -29 * day), minutes: 10),
            work(Fixture.start.plus(minutes: -31 * day), minutes: 10)
        ]
        let pruned = AnalyticsAggregator.prune(records, now: Fixture.start, calendar: Fixture.calendar, retentionDays: 30)

        #expect(pruned.count == 2)
        #expect(!pruned.contains { $0.startedAt < Fixture.start.plus(minutes: -30 * day) })
    }
}
