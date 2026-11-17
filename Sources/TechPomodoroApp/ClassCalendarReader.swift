import EventKit
import Foundation
import TechPomodoroCore

/// Reads class meetings from one calendar through EventKit, for the publishing Mac. The decisions —
/// which events count, which class, the ids, corrections, overlap — are `ClassMeetings` in the core;
/// this only asks for access and turns `EKEvent`s into plain occurrences. Access is requested only
/// when the "Count class meetings" switch is turned on, never at launch.
@MainActor
final class ClassCalendarReader: ObservableObject {

    enum Access: Equatable {
        case notDetermined, granted, denied
    }

    struct Status: Equatable {
        var access: Access = .notDetermined
        /// Nil until a read was tried; false when no calendar has the chosen title.
        var calendarFound: Bool?
        var counted = 0
        var unmatched = 0
        var ambiguous = 0
        var lastRead: Date?
    }

    @Published private(set) var status = Status()
    /// The titles of this Mac's event calendars, for the picker.
    @Published private(set) var calendarTitles: [String] = []

    /// Called when the calendar database changes or a meeting ends, so the publisher re-reads.
    var onChange: (() -> Void)?

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private var endTimer: Task<Void, Never>?

    init() {
        status.access = Self.currentAccess()
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.status.access == .granted else { return }
                self.refreshTitles()
                self.onChange?()
            }
        }
        if status.access == .granted { refreshTitles() }
    }

    static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Asks for full calendar access if it has not been decided yet; then reports back through
    /// `onChange` so the publisher reads.
    func requestAccess() {
        guard Self.currentAccess() == .notDetermined else {
            status.access = Self.currentAccess()
            if status.access == .granted { refreshTitles() }
            return
        }
        store.requestFullAccessToEvents { [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                self.status.access = granted ? .granted : .denied
                if granted {
                    self.store.reset()
                    self.refreshTitles()
                }
                self.onChange?()
            }
        }
    }

    private func refreshTitles() {
        calendarTitles = Array(Set(store.calendars(for: .event).map(\.title))).sorted()
    }

    /// The meetings in the named calendar over the paper retention window, corrections applied. Empty
    /// (with the status saying why) when access is missing or the calendar isn't there.
    func meetings(calendarTitle: String, classes: [String], corrections: [PaperCorrection], now: Date, calendar: Calendar) -> [PaperSittingView] {
        status.access = Self.currentAccess()
        guard status.access == .granted else {
            status.calendarFound = nil
            return []
        }
        let calendars = store.calendars(for: .event).filter { $0.title == calendarTitle }
        status.calendarFound = !calendars.isEmpty
        guard !calendars.isEmpty,
              let from = calendar.date(byAdding: .day, value: -PaperHistory.retentionDays, to: calendar.startOfDay(for: now)),
              let ahead = calendar.date(byAdding: .day, value: 8, to: now)
        else { return [] }
        let events = store.events(matching: store.predicateForEvents(withStart: from, end: ahead, calendars: calendars))
        let occurrences = events.map(Self.occurrence)
        let result = ClassMeetings.meetings(events: occurrences.filter { $0.start < now }, classes: classes, corrections: corrections, now: now)
        status.counted = result.meetings.count
        status.unmatched = result.unmatched
        status.ambiguous = result.ambiguous
        status.lastRead = now
        scheduleNextEnd(after: now, among: occurrences)
        return result.meetings
    }

    /// Re-reads at the next meeting's end, so a meeting that just finished is published in full.
    private func scheduleNextEnd(after now: Date, among events: [CalendarEventOccurrence]) {
        endTimer?.cancel()
        let next = events.filter { !$0.isAllDay && !$0.isCancelled && $0.end > now }.map(\.end).min()
        guard let next else { return }
        let delay = next.timeIntervalSince(now) + 5
        endTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.onChange?()
        }
    }

    /// Stops the end-of-meeting timer (the switch was turned off).
    func stop() {
        endTimer?.cancel()
        endTimer = nil
        status = Status(access: Self.currentAccess())
    }

    nonisolated static func occurrence(_ event: EKEvent) -> CalendarEventOccurrence {
        let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
        return CalendarEventOccurrence(
            externalID: event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? UUID().uuidString,
            occurrenceStart: event.occurrenceDate ?? event.startDate,
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            isCancelled: event.status == .canceled,
            isDeclined: declined
        )
    }
}
