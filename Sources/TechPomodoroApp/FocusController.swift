import Foundation
import TechPomodoroCore

/// Focus tracking for the Work interval in progress: polls ActivityWatch, keeps the interval's
/// pauses, scores the interval with `FocusTracker`, and decides when a drift alert is due. Split out
/// of `AppController`, which owns the timer and hands this the state after every reduction; the
/// alert itself (sound, flash, popup) stays with `AppController`, which owns those services.
@MainActor
final class FocusController {

    /// The focus picture of the Work interval in progress; nil outside Work or before the first poll.
    private(set) var snapshot: FocusSnapshot?
    /// `Live`, `Offline — …`, `Off`, or `Waiting for Work`, for the popover.
    private(set) var status: String = "Waiting for Work"
    /// The summary line of the Work interval that ended last.
    private(set) var lastLine: String?

    /// Something above changed; `AppController` republishes it and redraws the menu bar.
    var onUpdate: () -> Void = {}
    /// A drift alert is due for this snapshot. Called at most once per stretch off the anchor.
    var onDriftAlert: (FocusSnapshot) -> Void = { _ in }
    /// False while a popup is up: no drift alert may stack on it.
    var canAlert: () -> Bool = { true }

    /// Seconds between ActivityWatch polls during Work.
    static let pollSeconds: TimeInterval = 5

    private let source = ActivityWatchSource()
    private let now: () -> Date
    /// The timer as it stands after the latest reduction.
    private let currentState: () -> PomodoroState

    /// `phaseStartedAt` of the Work interval being tracked. A new value means a new interval.
    private var intervalStart: Date?
    private var activity: FocusActivity?
    private var manualAnchor: FocusProject?
    private var driftAlertCount = 0
    /// Set once the current off-anchor stretch has alerted; cleared when you get back on task, so
    /// each stretch alerts once.
    private var driftAlerted = false
    private var lastPoll: Date = .distantPast
    /// Pauses within the tracked Work interval, closed, plus the one in progress. Paused time is
    /// neutral for focus.
    private var pausedSpans: [AwaySpan] = []
    private var pauseStartedAt: Date?
    private var pollInFlight = false

    init(now: @escaping () -> Date, currentState: @escaping () -> PomodoroState) {
        self.now = now
        self.currentState = currentState
    }

    private var state: PomodoroState { currentState() }
    private var settings: PomodoroSettings { state.settings }

    private var isTracking: Bool {
        settings.focus.enabled && state.activity != .idle && state.phase == .work
    }

    // MARK: - Driven by AppController after each reduction

    /// Records pause spans so focus can treat them as neutral.
    func notePause(from old: PomodoroState.Activity, to new: PomodoroState.Activity, at now: Date) {
        if new == .paused, old != .paused {
            pauseStartedAt = now
        } else if old == .paused, new != .paused, let start = pauseStartedAt {
            pausedSpans.append(AwaySpan(start: start, end: now))
            pauseStartedAt = nil
        }
    }

    /// Hands the tracked interval's summary to its work record. Only the record that starts where the
    /// tracked interval started gets one: a sleep catch-up can close several intervals at once, and
    /// the earlier ones were never watched.
    func attach(to records: [IntervalRecord]) -> [IntervalRecord] {
        guard let start = intervalStart, let snapshot else { return records }
        return records.map { record in
            guard record.kind == .work, record.startedAt == start else { return record }
            var record = record
            let summary = snapshot.summary(level: settings.focus.driftLevel, driftAlerts: driftAlertCount)
            record.focus = summary
            lastLine = summary.lineText
            return record
        }
    }

    /// Starts tracking afresh whenever a new Work interval begins, and stops outside Work.
    func trackInterval() {
        // A paper tag change splits a Work interval into records; each is tracked on its own.
        let start = isTracking ? (state.workRecordStartedAt ?? state.phaseStartedAt) : nil
        guard start != intervalStart else { return }
        intervalStart = start
        pausedSpans = []
        if state.activity != .paused { pauseStartedAt = nil }
        snapshot = nil
        activity = nil
        manualAnchor = nil
        driftAlertCount = 0
        driftAlerted = false
        lastPoll = .distantPast
        if !settings.focus.enabled {
            status = "Off"
        } else if start == nil {
            status = "Waiting for Work"
        } else {
            status = "Connecting…"
        }
    }

    func pollIfDue(at now: Date) {
        guard isTracking, state.activity == .running, let start = intervalStart,
              !pollInFlight, now.timeIntervalSince(lastPoll) >= Self.pollSeconds else { return }
        lastPoll = now
        pollInFlight = true
        let server = settings.focus.serverURL
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pollInFlight = false }
            do {
                let activity = try await self.source.fetch(server: server, from: start, to: self.now())
                // The interval may have ended while the request was out.
                guard self.intervalStart == start else { return }
                self.activity = activity
                self.status = "Live"
                self.recompute()
            } catch {
                guard self.intervalStart == start else { return }
                self.status = "Offline — \(error.localizedDescription)"
                self.onUpdate()
            }
        }
    }

    // MARK: - Anchor

    /// Projects seen so far this interval, most time first, for the anchor override menu.
    var projects: [FocusProject] {
        guard let snapshot else { return [] }
        var totals: [FocusProject: TimeInterval] = [:]
        for (project, seconds) in snapshot.projectSeconds {
            totals[project.at(settings.focus.driftLevel), default: 0] += seconds
        }
        return totals.sorted { $0.value > $1.value }.map(\.key)
    }

    /// Pins the anchor by hand for the rest of this interval; nil goes back to inferring it.
    func setAnchor(_ project: FocusProject?) {
        manualAnchor = project
        driftAlerted = false
        recompute()
    }

    // MARK: - Scoring

    /// The pauses of the tracked interval, the open one running to `now`.
    private func pauses(at now: Date) -> [AwaySpan] {
        guard let open = pauseStartedAt, now > open else { return pausedSpans }
        return pausedSpans + [AwaySpan(start: open, end: now)]
    }

    private func recompute() {
        guard let start = intervalStart, let activity else { return }
        let now = now()
        let snapshot = FocusTracker.snapshot(
            activity: activity,
            from: start,
            to: now,
            settings: settings.focus,
            manualAnchor: manualAnchor,
            paused: pauses(at: now),
            paperClass: state.phase == .work ? state.paperTag?.className : nil
        )
        self.snapshot = snapshot
        checkDrift(snapshot)
        onUpdate()
    }

    /// One alert per stretch off the anchor, once it has run `driftAlertSeconds`.
    private func checkDrift(_ snapshot: FocusSnapshot) {
        guard snapshot.isDrifting else {
            driftAlerted = false
            return
        }
        let threshold = settings.focus.driftAlertSeconds
        guard threshold > 0, !driftAlerted, canAlert(), state.activity == .running,
              snapshot.offAnchorSeconds >= TimeInterval(threshold) else { return }
        driftAlerted = true
        driftAlertCount += 1
        onDriftAlert(snapshot)
    }
}
