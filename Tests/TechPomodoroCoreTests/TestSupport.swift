import Foundation
@testable import TechPomodoroCore

/// A fixed, timezone-pinned reference point so every date in the suite is explicit.
/// 2026-03-10 09:00:00 in a fixed +00:00 calendar.
enum Fixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    static let start: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 10
        components.hour = 9
        components.minute = 0
        components.second = 0
        return calendar.date(from: components)!
    }()

    /// Settings small enough to read at a glance: 25m work, 5m rest, 3 reps, 15m break,
    /// 2 cycles, 60m session rest.
    static func settings(
        work: Int = 25,
        rest: Int = 5,
        reps: Int = 3,
        longBreak: Int = 15,
        cycles: Int = 2,
        sessionRest: Int = 60,
        repeatSession: Bool = false
    ) -> PomodoroSettings {
        PomodoroSettings(
            workMinutes: work,
            restMinutes: rest,
            repsPerCycle: reps,
            longBreakMinutes: longBreak,
            cyclesPerSession: cycles,
            sessionRestMinutes: sessionRest,
            repeatSession: repeatSession
        )
    }
}

extension Date {
    /// `Fixture.start.plus(minutes: 25)` reads better than nested `addingTimeInterval` calls.
    func plus(minutes: Double = 0, seconds: Double = 0) -> Date {
        addingTimeInterval(minutes * 60 + seconds)
    }
}

extension PomodoroState {
    /// Applies a sequence of events, each at its own instant, threading the state through.
    func applying(_ steps: [(PomodoroEvent, Date)]) -> PomodoroState {
        steps.reduce(self) { state, step in
            PomodoroReducer.reduce(state, step.0, step.1)
        }
    }

    var alerts: [AlertKind] {
        pendingEffects.compactMap { effect in
            if case .alert(let kind) = effect { return kind }
            return nil
        }
    }

    var workRecords: [IntervalRecord] {
        pendingRecords.filter { $0.kind == .work }
    }

    var cycleRecords: [IntervalRecord] {
        pendingRecords.filter { $0.kind == .cycleCompleted }
    }
}
