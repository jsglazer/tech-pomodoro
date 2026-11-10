import AppKit
import Combine
import SwiftUI
import TechPomodoroCore
import TechPomodoroSync

/// The OS shell around the pure core.
///
/// It owns the one runloop timer, the stores, and the AppKit services; every decision about *what*
/// the timer does is delegated to `PomodoroReducer`. Nothing here computes elapsed time.
@MainActor
final class AppController: ObservableObject {

    @Published private(set) var state: PomodoroState
    @Published private(set) var analytics: AnalyticsSummary = .empty
    @Published private(set) var history: [IntervalRecord] = []
    @Published var loginItemWarning: String?
    /// The iCloud sync row in Settings.
    @Published private(set) var syncStatus: CloudSyncStatus = .off

    /// The focus picture of the Work interval in progress; nil outside Work or before the first poll.
    @Published private(set) var focus: FocusSnapshot?
    /// `Live`, `Offline — …`, `Off`, or `Waiting for Work`, for the popover.
    @Published private(set) var focusStatus: String = "Waiting for Work"
    /// The summary line of the Work interval that ended last.
    @Published private(set) var lastFocusLine: String?
    /// The document sensor's status line for the Focus tab.
    @Published private(set) var documentSensorStatus: DocumentSensorEngine.Status = .waiting

    /// Republished once a second purely so SwiftUI re-renders the countdown.
    ///
    /// Only while the popover is actually on screen: with it closed there is no SwiftUI view left to
    /// re-render (`AppDelegate` tears the hosting controller down), so publishing a new date every
    /// second would only wake observers for nothing. The menu bar reads `now` instead, which is
    /// always current.
    @Published private(set) var displayNow: Date

    /// The last date a reduction ran at. Unlike `displayNow` this is never gated, so the menu bar
    /// countdown keeps ticking whether or not the popover is open.
    private var now: Date

    private var isPopoverVisible = false

    let soundCatalog: SystemSoundCatalog

    private let dateProvider: DateProvider
    private let calendar: Calendar
    private let intervalStore: any IntervalStore
    private let settingsStore: any SettingsStoring
    private let soundPlayer: any SoundPlaying
    private let popupPresenter: any PopupPresenting
    private let loginItem: any LoginItemControlling
    private weak var presenter: StatusItemPresenter?

    /// Set for the duration of `popupPresenter.present`, whose `NSAlert.runModal()` pumps a nested
    /// run loop that would otherwise let the `.common`-mode refresh timer re-enter `send` while this
    /// reduction is still on the stack, corrupting the state read after `handle(effects:)` returns.
    private var isPresentingPopup = false

    private let focusSource = ActivityWatchSource()
    /// `phaseStartedAt` of the Work interval being tracked. A new value means a new interval.
    private var focusIntervalStart: Date?
    private var focusActivity: FocusActivity?
    private var manualAnchor: FocusProject?
    private var driftAlertCount = 0
    /// Set once the current off-anchor stretch has alerted; cleared when you get back on task, so
    /// each stretch alerts once.
    private var driftAlerted = false
    private var lastFocusPoll: Date = .distantPast
    /// Pauses within the tracked Work interval, closed, plus the one in progress. Paused time is
    /// neutral for focus.
    private var pausedSpans: [AwaySpan] = []
    private var pauseStartedAt: Date?
    private var focusPollInFlight = false
    /// Seconds between ActivityWatch polls during Work.
    private static let focusPollSeconds: TimeInterval = 5

    /// Display refresh only. It never advances the timer by itself: every reduction is handed the
    /// date from `dateProvider`, and remaining time is always derived from `phaseEndsAt`.
    private var refreshTimer: Timer?

    /// Settings and history sync through iCloud; nil until `startSync()`.
    private var cloudSync: CloudSync?
    private var syncStatusSubscription: AnyCancellable?

    /// Pushes this Mac's timer to the iPhone's Live Activity.
    let mirror = MirrorPusher()

    /// The iPhone's own timer, shown here display only while this Mac's timer is idle.
    private lazy var phoneTimer = PhoneTimerWatcher(apns: mirror.apns) { [weak self] in self?.mirror.credentials }
    /// What the menu bar and popover show of the iPhone's timer; nil while this Mac's own timer runs.
    @Published private(set) var phoneDisplay: PhoneTimerWatcher.Display?

    /// Reports the front app's open documents to ActivityWatch; independent of the timer.
    private var documentSensor: DocumentSensorService?

    init(
        dateProvider: DateProvider = .system,
        calendar: Calendar = .current,
        intervalStore: any IntervalStore,
        settingsStore: any SettingsStoring,
        soundPlayer: any SoundPlaying = SystemSoundPlayer(),
        soundCatalog: SystemSoundCatalog = SystemSoundCatalog(),
        popupPresenter: any PopupPresenting = NSAlertPopupPresenter(),
        loginItem: any LoginItemControlling = SMAppServiceLoginItem()
    ) {
        self.dateProvider = dateProvider
        self.calendar = calendar
        self.intervalStore = intervalStore
        self.settingsStore = settingsStore
        self.soundPlayer = soundPlayer
        self.soundCatalog = soundCatalog
        self.popupPresenter = popupPresenter
        self.loginItem = loginItem
        let start = dateProvider.now()
        self.displayNow = start
        self.now = start

        var settings = settingsStore.load()
        // A sound that no longer exists on this macOS version falls back rather than going silent.
        let resolved = soundCatalog.resolvedName(for: settings.soundName)
        if resolved != settings.soundName {
            settings.soundName = resolved
            settingsStore.save(settings)
        }
        // The timer always starts idle: in-progress state is deliberately not persisted.
        self.state = PomodoroState(settings: settings)

        reloadHistory()
    }

    var settings: PomodoroSettings { state.settings }

    // MARK: - Wiring

    func attach(presenter: StatusItemPresenter) {
        self.presenter = presenter
        refreshPresentation()
    }

    /// Starts the document sensor for the life of the app. It never consults the timer state, so it
    /// samples while the timer is idle, paused, in Work or in Rest alike.
    func startDocumentSensor() {
        guard documentSensor == nil else { return }
        let sensor = DocumentSensorService(
            settings: { [weak self] in self?.state.settings.focus ?? FocusSettings() },
            onStatus: { [weak self] status in self?.documentSensorStatus = status }
        )
        documentSensor = sensor
        sensor.start()
    }

    func startRefreshing() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.tick) }
        }
        // A tick that lands a fraction of a second late costs nothing — the countdown is derived from
        // `phaseEndsAt`, never accumulated — so allowing slack lets macOS coalesce this wakeup with
        // others instead of forcing the CPU out of idle on its own schedule once a second.
        timer.tolerance = 0.25
        // Common mode, so the countdown keeps updating while a menu or the popover is tracking.
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// Called by `AppDelegate` as the popover opens and closes. While it is closed there is no
    /// SwiftUI view graph to drive, so the per-second `displayNow` republish is skipped entirely.
    func setPopoverVisible(_ visible: Bool) {
        isPopoverVisible = visible
        // Opening: hand SwiftUI the current time up front, so the countdown is right on the first
        // frame rather than showing the stale date until the next tick.
        if visible {
            displayNow = now
            cloudSync?.fetchNow()
            phoneTimer.refreshNow()
        }
    }

    func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.willSleep) }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.send(.didWake)
                // Another device may have logged intervals or changed settings while this Mac slept.
                self?.cloudSync?.fetchNow()
                self?.phoneTimer.refreshNow()
            }
        }
    }

    /// Brings up iCloud sync, honouring the per-device switch in Settings.
    func startSync() {
        let sync = CloudSync(
            intervalStore: intervalStore,
            settingsStore: settingsStore,
            stateURL: CloudSync.defaultStateURL(),
            calendar: calendar
        ) { [weak self] change in
            self?.applySynced(change)
        }
        cloudSync = sync
        syncStatusSubscription = sync.$status.sink { [weak self] status in
            self?.syncStatus = status
        }
        sync.setEnabled(state.settings.cloudSyncEnabled)

        mirror.onForceRepush = { [weak self] in
            guard let self else { return }
            self.mirror.stateDidChange(self.state, at: self.dateProvider.now())
        }
        mirror.setEnabled(state.settings.mirrorEnabled, state: state, at: dateProvider.now())
        phoneTimer.setEnabled(state.settings.mirrorEnabled)
        applyMigrations()
    }

    /// Applies any pending one-time settings migration as an ordinary edit, so it is saved and
    /// synced to the other devices like a change made in Settings.
    private func applyMigrations() {
        guard let migrated = FocusMigrations.migrate(state.settings.focus) else { return }
        var settings = state.settings
        settings.focus = migrated
        update(settings: settings)
    }

    /// On quit, tells the iPhone this Mac's timer has stopped. Bounded, so quitting never hangs.
    func shutdownMirror() async {
        let now = dateProvider.now()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.mirror.shutdown(at: now) }
            group.addTask { try? await Task.sleep(for: .seconds(4)) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Something another device changed, already written to the local stores by `CloudSync`.
    private func applySynced(_ change: CloudSync.Change) {
        switch change {
        case .history(let records):
            history = records
            recomputeAnalytics(at: dateProvider.now())
        case .settings(let settings):
            // Straight to the reducer: routing through `update(settings:)` would stamp it as a local
            // edit and push it straight back.
            send(.settingsChanged(settings))
            // A copy from a device that has not migrated yet gets migrated here (and pushed once).
            applyMigrations()
        }
    }

    // MARK: - Events

    func send(_ event: PomodoroEvent) {
        // The refresh timer keeps firing into the nested run loop a popup's `runModal()` pumps;
        // nothing needs to reduce while that alert is up, and doing so would corrupt the state this
        // very reduction is about to read back out of `handle(effects:)`.
        guard !isPresentingPopup else { return }
        let now = dateProvider.now()
        self.now = now
        if isPopoverVisible { displayNow = now }
        let previousActivity = state.activity
        state = PomodoroReducer.reduce(state, event, now)
        notePause(from: previousActivity, to: state.activity, at: now)
        // The record of a Work interval that just ended takes its focus summary before tracking moves
        // on to whatever phase began, and before a boundary popup wants to quote it.
        let records = attachFocus(to: state.pendingRecords)
        trackFocusInterval()
        handle(effects: state.pendingEffects)
        persist(records: records, at: now)
        pollFocusIfDue(at: now)
        showPhoneTimer(at: now)
        refreshPresentation()
        mirror.stateDidChange(state, at: now)
    }

    /// Moves the iPhone's timer on and, while this Mac's own timer is idle, shows it and sounds its
    /// boundaries. Its history is the iPhone's to log; it reaches here through iCloud sync.
    private func showPhoneTimer(at now: Date) {
        let effects = phoneTimer.tick(settings: state.settings, at: now)
        let shown = state.activity == .idle ? phoneTimer.display : nil
        if shown != phoneDisplay { phoneDisplay = shown }
        if state.activity == .idle, !effects.isEmpty, !isPresentingPopup {
            handle(effects: effects, fromPhone: true)
        }
    }

    func update(settings newSettings: PomodoroSettings) {
        let old = state.settings
        settingsStore.save(newSettings)
        cloudSync?.settingsChanged(from: old, to: newSettings)
        send(.settingsChanged(newSettings))
        if old.cloudSyncEnabled != newSettings.cloudSyncEnabled {
            cloudSync?.setEnabled(newSettings.cloudSyncEnabled)
        }
        if old.mirrorEnabled != newSettings.mirrorEnabled {
            mirror.setEnabled(newSettings.mirrorEnabled, state: state, at: dateProvider.now())
            phoneTimer.setEnabled(newSettings.mirrorEnabled)
        }
        if old.focus.documents != newSettings.focus.documents || old.focus.serverURL != newSettings.focus.serverURL {
            documentSensor?.sampleNow()
        }
    }

    /// Adds a running app to the document sensor's list (PDFs by default; edit the extensions after).
    func addWatchedApp(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        var settings = state.settings
        guard settings.focus.documents.app(bundleID: bundleID) == nil else { return }
        settings.focus.documents.apps.append(
            WatchedApp(name: app.localizedName ?? bundleID, bundleID: bundleID, extensions: ["pdf"])
        )
        update(settings: settings)
    }

    func removeWatchedApp(bundleID: String) {
        var settings = state.settings
        settings.focus.documents.apps.removeAll { $0.bundleID == bundleID }
        update(settings: settings)
    }

    /// Comma-separated extensions of one watched app, as a text field binding.
    func extensionsBinding(bundleID: String) -> Binding<String> {
        Binding(
            get: { self.state.settings.focus.documents.app(bundleID: bundleID)?.extensions.joined(separator: ", ") ?? "" },
            set: { newValue in
                var settings = self.state.settings
                guard let i = settings.focus.documents.apps.firstIndex(where: { $0.bundleID == bundleID }) else { return }
                settings.focus.documents.apps[i].extensions = newValue
                    .split(whereSeparator: { $0 == "," || $0 == " " })
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }
                    .filter { !$0.isEmpty }
                self.update(settings: settings)
            }
        )
    }

    /// `Last sent 4 s ago · PDF Expert · 1 file`, or why it is not sending.
    var documentSensorStatusText: String {
        switch documentSensorStatus {
        case .off: return "Off"
        case .waiting: return "Waiting for a watched app with a document open"
        case .error(let message): return "Not sending — \(message)"
        case .sent(let app, let files, let at):
            let ago = max(0, Int(dateProvider.now().timeIntervalSince(at).rounded()))
            return "Last sent \(ago) s ago · \(app) · \(files) \(files == 1 ? "file" : "files")"
        }
    }

    /// Mutates one field of the settings and persists the result.
    func bind<Value>(_ keyPath: WritableKeyPath<PomodoroSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.state.settings[keyPath: keyPath] },
            set: { newValue in
                var settings = self.state.settings
                settings[keyPath: keyPath] = newValue
                self.update(settings: settings)
            }
        )
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let result = loginItem.setEnabled(enabled)
        loginItemWarning = result.warning
        var settings = state.settings
        settings.launchAtLogin = result.isEnabled
        update(settings: settings)
    }

    func previewSound() {
        soundPlayer.play(named: state.settings.soundName, times: state.settings.dingRepeatCount)
    }

    /// The menu bar text colour, as a SwiftUI binding for the settings picker.
    var menuBarTextColor: Binding<Color> {
        hexBinding(\.menuBarTextColorHex)
    }

    /// The rest-phase colour, as a SwiftUI binding for the settings picker.
    var restColor: Binding<Color> {
        hexBinding(\.restColorHex)
    }

    /// The drift colour, as a SwiftUI binding for the focus settings picker.
    var driftColor: Binding<Color> {
        hexBinding(\.focus.driftColorHex)
    }

    /// A list setting edited as one line per entry. Lines are kept as typed, blanks included, so the
    /// editor never swallows the newline you just entered; every matcher skips blank entries.
    func linesBinding(_ keyPath: WritableKeyPath<PomodoroSettings, [String]>) -> Binding<String> {
        Binding(
            get: { self.state.settings[keyPath: keyPath].joined(separator: "\n") },
            set: { newValue in
                var settings = self.state.settings
                settings[keyPath: keyPath] = newValue.components(separatedBy: "\n")
                self.update(settings: settings)
            }
        )
    }

    /// Bridges a `ColorPicker` to a `#RRGGBB` settings field, so a selection persists as the same
    /// hex the menu bar parses back.
    private func hexBinding(_ keyPath: WritableKeyPath<PomodoroSettings, String>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: Theme.color(hexString: self.state.settings[keyPath: keyPath])) },
            set: { newValue in
                var settings = self.state.settings
                settings[keyPath: keyPath] = Theme.hexString(NSColor(newValue))
                self.update(settings: settings)
            }
        )
    }

    // MARK: - Effects

    /// `fromPhone` when the alerts are the iPhone's timer's. This Mac's own alert settings apply either way.
    private func handle(effects: [PomodoroEffect], fromPhone: Bool = false) {
        for effect in effects {
            guard case .alert = effect else { continue }
            if state.settings.dingEnabled {
                soundPlayer.play(named: state.settings.soundName, times: state.settings.dingRepeatCount)
            }
            if state.settings.flashEnabled {
                presenter?.flash(times: state.settings.flashRepeatCount)
            }
            if state.settings.popupEnabled {
                presentPopup(for: effect, fromPhone: fromPhone)
            }
        }
    }

    private func presentPopup(for effect: PomodoroEffect, fromPhone: Bool = false) {
        guard case .alert(let kind) = effect else { return }
        var (title, message) = popupText(for: kind)
        if fromPhone {
            // `state` is this Mac's idle timer; the phase starting is the iPhone's.
            if kind == .sessionComplete {
                message = "The iPhone's schedule has finished."
            } else if let phone = phoneTimer.display {
                message = "\(phone.state.phase.title) is starting on \(phone.phoneName)."
            }
        }
        isPresentingPopup = true
        let limit = state.settings.popupDismissSeconds
        popupPresenter.present(title: title, message: message, dismissAfter: limit > 0 ? TimeInterval(limit) : nil)
        isPresentingPopup = false
    }

    /// `state.phase` already reflects the phase the reducer just moved *into*, so it names what's
    /// starting rather than what just finished.
    private func popupText(for kind: AlertKind) -> (title: String, message: String) {
        switch kind {
        case .intervalEnd, .cycleEnd, .sessionEnd:
            // Leaving Work, the line says what that pomodoro actually went on.
            if state.phase != .work, let line = lastFocusLine {
                return ("Time's up", "\(state.phase.title) is starting.\n\(line)")
            }
            return ("Time's up", "\(state.phase.title) is starting.")
        case .sessionComplete:
            return ("Session complete", "The full schedule has finished.")
        }
    }

    private func persist(records: [IntervalRecord], at now: Date) {
        guard !records.isEmpty else { return }
        do {
            history = try intervalStore.append(records, now: now, calendar: calendar)
            recomputeAnalytics(at: now)
            cloudSync?.recordsAdded(records)
        } catch {
            // A failed history write must never take the timer down with it.
            NSLog("tech-pomodoro: could not write interval history: \(error.localizedDescription)")
        }
    }

    private func reloadHistory() {
        history = (try? intervalStore.load()) ?? []
        recomputeAnalytics(at: dateProvider.now())
    }

    private func recomputeAnalytics(at now: Date) {
        analytics = AnalyticsAggregator.summarize(records: history, now: now, calendar: calendar)
    }

    /// Refreshes the analytics on demand, so hovering shows current numbers without a timer.
    func refreshAnalytics() {
        recomputeAnalytics(at: dateProvider.now())
    }

    private func refreshPresentation() {
        if let phone = phoneDisplay {
            // The iPhone's timer, drawn like this Mac's own; the hover says whose it is.
            presenter?.apply(MenuBarFormatter.presentation(for: phone.state, at: now, focus: nil))
            presenter?.setTooltip("\(MenuBarFormatter.hoverText(for: phone.state, at: now)) — on \(phone.phoneName)")
            let info = MenuBarFormatter.hoverInfo(for: phone.state, at: now, focus: nil)
            presenter?.setHoverInfo(HoverInfo(title: "\(info.title) · \(phone.phoneName)", detail: info.detail))
            return
        }
        presenter?.apply(MenuBarFormatter.presentation(for: state, at: now, focus: focus))
        presenter?.setTooltip(MenuBarFormatter.hoverText(for: state, at: now))
        presenter?.setHoverInfo(MenuBarFormatter.hoverInfo(for: state, at: now, focus: focus))
    }

    // MARK: - Focus

    /// Projects seen so far this interval, most time first, for the anchor override menu.
    var focusProjects: [FocusProject] {
        guard let focus else { return [] }
        var totals: [FocusProject: TimeInterval] = [:]
        for (project, seconds) in focus.projectSeconds {
            totals[project.at(settings.focus.driftLevel), default: 0] += seconds
        }
        return totals.sorted { $0.value > $1.value }.map(\.key)
    }

    /// Pins the anchor by hand for the rest of this interval; nil goes back to inferring it.
    func setAnchor(_ project: FocusProject?) {
        manualAnchor = project
        driftAlerted = false
        recomputeFocus()
    }

    /// Per-task totals from the history, for the popover.
    func projectTotals(days: Int) -> [ProjectTotal] {
        FocusAnalytics.projectTotals(records: history, now: dateProvider.now(), calendar: calendar, days: days)
    }

    func meanFocusShare(days: Int) -> Double? {
        FocusAnalytics.meanFocusShare(records: history, now: dateProvider.now(), calendar: calendar, days: days)
    }

    private var isTrackingFocus: Bool {
        settings.focus.enabled && state.activity != .idle && state.phase == .work
    }

    /// Hands the tracked interval's summary to its work record. Only the record that starts where the
    /// tracked interval started gets one: a sleep catch-up can close several intervals at once, and
    /// the earlier ones were never watched.
    private func attachFocus(to records: [IntervalRecord]) -> [IntervalRecord] {
        guard let start = focusIntervalStart, let focus else { return records }
        return records.map { record in
            guard record.kind == .work, record.startedAt == start else { return record }
            var record = record
            let summary = focus.summary(level: settings.focus.driftLevel, driftAlerts: driftAlertCount)
            record.focus = summary
            lastFocusLine = summary.lineText
            return record
        }
    }

    /// Records pause spans so focus can treat them as neutral.
    private func notePause(from old: PomodoroState.Activity, to new: PomodoroState.Activity, at now: Date) {
        if new == .paused, old != .paused {
            pauseStartedAt = now
        } else if old == .paused, new != .paused, let start = pauseStartedAt {
            pausedSpans.append(AwaySpan(start: start, end: now))
            pauseStartedAt = nil
        }
    }

    /// The pauses of the tracked interval, the open one running to `now`.
    private func pauses(at now: Date) -> [AwaySpan] {
        guard let open = pauseStartedAt, now > open else { return pausedSpans }
        return pausedSpans + [AwaySpan(start: open, end: now)]
    }

    /// Starts tracking afresh whenever a new Work interval begins, and stops outside Work.
    private func trackFocusInterval() {
        let start = isTrackingFocus ? state.phaseStartedAt : nil
        guard start != focusIntervalStart else { return }
        focusIntervalStart = start
        pausedSpans = []
        if state.activity != .paused { pauseStartedAt = nil }
        focus = nil
        focusActivity = nil
        manualAnchor = nil
        driftAlertCount = 0
        driftAlerted = false
        lastFocusPoll = .distantPast
        if !settings.focus.enabled {
            focusStatus = "Off"
        } else if start == nil {
            focusStatus = "Waiting for Work"
        } else {
            focusStatus = "Connecting…"
        }
    }

    private func pollFocusIfDue(at now: Date) {
        guard isTrackingFocus, state.activity == .running, let start = focusIntervalStart,
              !focusPollInFlight, now.timeIntervalSince(lastFocusPoll) >= Self.focusPollSeconds else { return }
        lastFocusPoll = now
        focusPollInFlight = true
        let server = settings.focus.serverURL
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.focusPollInFlight = false }
            do {
                let activity = try await self.focusSource.fetch(server: server, from: start, to: self.dateProvider.now())
                // The interval may have ended while the request was out.
                guard self.focusIntervalStart == start else { return }
                self.focusActivity = activity
                self.focusStatus = "Live"
                self.recomputeFocus()
            } catch {
                guard self.focusIntervalStart == start else { return }
                self.focusStatus = "Offline — \(error.localizedDescription)"
            }
        }
    }

    private func recomputeFocus() {
        guard let start = focusIntervalStart, let activity = focusActivity else { return }
        let snapshot = FocusTracker.snapshot(
            activity: activity,
            from: start,
            to: dateProvider.now(),
            settings: settings.focus,
            manualAnchor: manualAnchor,
            paused: pauses(at: dateProvider.now())
        )
        focus = snapshot
        checkDrift(snapshot)
        refreshPresentation()
    }

    /// One alert per stretch off the anchor, once it has run `driftAlertSeconds`.
    private func checkDrift(_ snapshot: FocusSnapshot) {
        guard snapshot.isDrifting else {
            driftAlerted = false
            return
        }
        let threshold = settings.focus.driftAlertSeconds
        guard threshold > 0, !driftAlerted, !isPresentingPopup, state.activity == .running,
              snapshot.offAnchorSeconds >= TimeInterval(threshold) else { return }
        driftAlerted = true
        driftAlertCount += 1

        if settings.dingEnabled {
            soundPlayer.play(named: settings.soundName, times: settings.dingRepeatCount)
        }
        if settings.flashEnabled {
            presenter?.flash(times: settings.flashRepeatCount)
        }
        let off = Int(snapshot.offAnchorSeconds.rounded())
        let anchor = snapshot.anchor.map { "Your focus: \($0.displayName)." } ?? "No project yet this interval."
        let message = "\(off) s off task — now on \(snapshot.current.label).\n\(anchor)"
        isPresentingPopup = true
        let limit = settings.popupDismissSeconds
        popupPresenter.present(title: "Drifting", message: message, dismissAfter: limit > 0 ? TimeInterval(limit) : nil)
        isPresentingPopup = false
    }

    // MARK: - Export

    func exportHistory(as format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = format == .csv ? "tech-pomodoro.csv" : "tech-pomodoro.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            switch format {
            case .csv:
                try Data(AnalyticsExporter.csv(records: history).utf8).write(to: url, options: .atomic)
            case .json:
                try AnalyticsExporter.json(records: history).write(to: url, options: .atomic)
            }
        } catch {
            NSLog("tech-pomodoro: export failed: \(error.localizedDescription)")
        }
    }

    enum ExportFormat {
        case csv
        case json
    }
}
