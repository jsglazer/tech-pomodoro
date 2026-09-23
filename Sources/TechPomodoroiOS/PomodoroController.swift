import Combine
import SwiftUI
import TechPomodoroCore
import UIKit

/// The iOS shell around the pure core — the counterpart of the Mac's `AppController`, kept the same
/// shape so the two stay recognisable side by side.
///
/// Every decision about *what* the timer does is delegated to `PomodoroReducer`. What differs is how
/// the shell survives suspension: the running session is snapshotted to disk, every upcoming boundary
/// is pre-scheduled as a local notification, and a Live Activity carries the countdown on the lock
/// screen. Nothing here needs to run in the background for any of it to stay correct, because
/// remaining time is always derived from `phaseEndsAt`.
@MainActor
final class PomodoroController: ObservableObject {

    /// One controller per process. The app's scene and the Live Activity intents — which the system
    /// may run with no scene at all, in a freshly launched background process — both go through it.
    static let shared = PomodoroController.live()

    @Published private(set) var state: PomodoroState
    @Published private(set) var analytics: AnalyticsSummary = .empty
    @Published private(set) var history: [IntervalRecord] = []
    /// The in-app stand-in for the Mac's alert dialog, shown only while the app is open.
    @Published var popup: PopupMessage?
    @Published private(set) var notificationAuthorization: NotificationScheduler.Authorization = .notDetermined

    let soundCatalog: BundledSoundCatalog

    private let dateProvider: DateProvider
    private let calendar: Calendar
    private let intervalStore: any IntervalStore
    private let settingsStore: any SettingsStoring
    private let snapshotStore: SessionSnapshotStore?
    private let soundPlayer: any SoundPlaying
    private let scheduler = NotificationScheduler()
    private let liveActivity = LiveActivityController()
    private let haptics = UINotificationFeedbackGenerator()
    private var pendingHaptics: [DispatchWorkItem] = []

    /// Foreground only. It crosses boundaries on time while the app is open; with the app in the
    /// background the notifications and the Live Activity take over and this is stopped.
    private var refreshTimer: Timer?

    init(
        dateProvider: DateProvider = .system,
        calendar: Calendar = .current,
        intervalStore: any IntervalStore,
        settingsStore: any SettingsStoring,
        snapshotStore: SessionSnapshotStore?,
        soundPlayer: any SoundPlaying = BundledSoundPlayer(),
        soundCatalog: BundledSoundCatalog = BundledSoundCatalog()
    ) {
        self.dateProvider = dateProvider
        self.calendar = calendar
        self.intervalStore = intervalStore
        self.settingsStore = settingsStore
        self.snapshotStore = snapshotStore
        self.soundPlayer = soundPlayer
        self.soundCatalog = soundCatalog

        // Unlike the Mac, an unknown sound name is not rewritten into the stored settings: a name
        // that is only a Mac system sound resolves to a bundled tone at playback instead.
        let settings = settingsStore.load()
        let now = dateProvider.now()

        // Unlike the Mac, a running session is restored: iOS may have killed the app mid-phase while
        // its notifications went on firing. A `.tick` at `now` then fast-forwards through any phases
        // that ended meanwhile and logs them. Their alert is dropped — the notification already gave it.
        if let restored = snapshotStore?.load()?.restore(settings: settings) {
            let caughtUp = PomodoroReducer.reduce(restored, .tick, now)
            self.state = caughtUp
            reloadHistory()
            persist(records: caughtUp.pendingRecords, at: now)
        } else {
            self.state = PomodoroState(settings: settings)
            reloadHistory()
        }
        scheduleDidChange(at: now)
    }

    static func live() -> PomodoroController {
        let intervalStore: any IntervalStore
        if let url = try? FileIntervalStore.applicationSupportURL() {
            intervalStore = FileIntervalStore(url: url)
        } else {
            intervalStore = MemoryIntervalStore()
        }
        return PomodoroController(
            intervalStore: intervalStore,
            settingsStore: UserDefaultsSettingsStore(defaults: .standard),
            snapshotStore: (try? SessionSnapshotStore.applicationSupportURL()).map(SessionSnapshotStore.init)
        )
    }

    var settings: PomodoroSettings { state.settings }

    // MARK: - Scene lifecycle

    /// The app came to the foreground. Catch up to the clock, restart the ticker, and re-plan: the
    /// planning window slides forward, and the Live Activity snaps back to exact.
    ///
    /// This sends `.tick` rather than `.didWake`. On iOS "the app was in the background" is not "the
    /// Mac slept": under `pauseOnSleep`, `.didWake` deliberately does not advance, which would leave a
    /// timer that kept running (its notifications firing) stuck on a stale phase. `.willSleep` is
    /// never sent on iOS for the same reason — it would pause the timer on every app switch.
    func sceneDidBecomeActive() {
        send(.tick)
        startRefreshing()
        scheduleDidChange(at: dateProvider.now())
        refreshAnalytics()
        Task { await refreshNotificationAuthorization() }
    }

    func sceneDidEnterBackground() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        snapshotStore?.save(state)
    }

    private func startRefreshing() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.tick) }
        }
        // A tick that lands a fraction of a second late costs nothing — the countdown is derived from
        // `phaseEndsAt`, never accumulated — so allow the system to coalesce the wakeup.
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: - Events

    func send(_ event: PomodoroEvent) {
        let now = dateProvider.now()
        let before = ScheduleKey(state)
        let next = PomodoroReducer.reduce(state, event, now)
        // Most ticks change nothing; skipping the assignment keeps SwiftUI from re-rendering the
        // whole tree once a second for no reason.
        if next != state { state = next }
        handle(effects: next.pendingEffects)
        persist(records: next.pendingRecords, at: now)
        if ScheduleKey(next) != before {
            scheduleDidChange(at: now)
        }
        if before.activity == .idle, next.activity == .running {
            Task { await requestNotificationAuthorization() }
        }
    }

    func update(settings newSettings: PomodoroSettings) {
        settingsStore.save(newSettings)
        send(.settingsChanged(newSettings))
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

    /// The sound picker shows the tone that will actually play, even when the stored name is a Mac
    /// system sound this device does not have.
    var soundSelection: Binding<String> {
        Binding(
            get: { self.soundCatalog.resolvedName(for: self.state.settings.soundName) },
            set: { newValue in
                var settings = self.state.settings
                settings.soundName = newValue
                self.update(settings: settings)
            }
        )
    }

    var countdownColor: Binding<Color> { hexBinding(\.menuBarTextColorHex) }
    var restColor: Binding<Color> { hexBinding(\.restColorHex) }

    private func hexBinding(_ keyPath: WritableKeyPath<PomodoroSettings, String>) -> Binding<Color> {
        Binding(
            get: { Color(hexString: self.state.settings[keyPath: keyPath]) },
            set: { newValue in
                var settings = self.state.settings
                settings[keyPath: keyPath] = Theme.hexString(UIColor(newValue))
                self.update(settings: settings)
            }
        )
    }

    func previewSound() {
        soundPlayer.play(
            named: soundCatalog.resolvedName(for: settings.soundName),
            times: settings.dingRepeatCount
        )
    }

    /// Waits for the notification plan and the Live Activity update in flight. An intent performed
    /// in a background launch awaits this, so the process is not suspended before they land.
    func settle() async {
        await scheduler.settle()
        await liveActivity.settle()
    }

    // MARK: - Schedule side effects

    /// Everything that must follow a change to when the next boundary falls.
    private func scheduleDidChange(at now: Date) {
        snapshotStore?.save(state)
        scheduler.replan(for: state)
        liveActivity.sync(with: state, at: now)
    }

    private func requestNotificationAuthorization() async {
        await scheduler.requestAuthorizationIfNeeded()
        notificationAuthorization = scheduler.authorization
        // A plan made before permission was granted added nothing; make it again.
        scheduler.replan(for: state)
    }

    private func refreshNotificationAuthorization() async {
        await scheduler.refreshAuthorization()
        notificationAuthorization = scheduler.authorization
    }

    // MARK: - Effects

    /// Foreground alerts. With the app open the notification for the same boundary is suppressed
    /// (see `NotificationDelegate`), so each boundary sounds exactly once.
    private func handle(effects: [PomodoroEffect]) {
        for effect in effects {
            guard case .alert(let kind) = effect else { continue }
            if settings.dingEnabled {
                soundPlayer.play(named: soundCatalog.resolvedName(for: settings.soundName), times: settings.dingRepeatCount)
            }
            // The menu bar flash becomes a haptic pulse on iOS.
            if settings.flashEnabled {
                pulse(times: settings.flashRepeatCount)
            }
            if settings.popupEnabled {
                popup = PopupMessage(kind: kind, startingPhase: state.phase)
            }
        }
    }

    private func pulse(times: Int) {
        pendingHaptics.forEach { $0.cancel() }
        pendingHaptics.removeAll()
        haptics.prepare()
        for index in 0..<max(1, times) {
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.haptics.notificationOccurred(.warning) }
            }
            pendingHaptics.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35 * Double(index), execute: item)
        }
    }

    private func persist(records: [IntervalRecord], at now: Date) {
        guard !records.isEmpty else { return }
        do {
            history = try intervalStore.append(records, now: now, calendar: calendar)
            recomputeAnalytics(at: now)
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

    func refreshAnalytics() {
        recomputeAnalytics(at: dateProvider.now())
    }

    // MARK: - Export

    enum ExportFormat {
        case csv
        case json
    }

    /// Writes the history to a temporary file for the share sheet, which replaces the Mac's save panel.
    func exportFile(as format: ExportFormat) -> URL? {
        let name = format == .csv ? "tech-pomodoro.csv" : "tech-pomodoro.json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            switch format {
            case .csv:
                try Data(AnalyticsExporter.csv(records: history).utf8).write(to: url, options: .atomic)
            case .json:
                try AnalyticsExporter.json(records: history).write(to: url, options: .atomic)
            }
            return url
        } catch {
            NSLog("tech-pomodoro: export failed: \(error.localizedDescription)")
            return nil
        }
    }
}

/// The fields whose change moves a boundary, so notifications, the snapshot and the Live Activity are
/// refreshed on a real change and not on every tick.
private struct ScheduleKey: Equatable {
    let activity: PomodoroState.Activity
    let phase: Phase
    let phaseEndsAt: Date?
    let remainingWhenPaused: TimeInterval?
    let completedRepsInCycle: Int
    let completedCyclesInSession: Int
    let settings: PomodoroSettings

    init(_ state: PomodoroState) {
        activity = state.activity
        phase = state.phase
        phaseEndsAt = state.phaseEndsAt
        remainingWhenPaused = state.remainingWhenPaused
        completedRepsInCycle = state.completedRepsInCycle
        completedCyclesInSession = state.completedCyclesInSession
        settings = state.settings
    }
}

/// An in-app alert, worded like the Mac's dialog: it names what is starting, not what ended.
struct PopupMessage: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String

    init(kind: AlertKind, startingPhase: Phase) {
        switch kind {
        case .intervalEnd, .cycleEnd, .sessionEnd:
            title = "Time's up"
            message = "\(startingPhase.title) is starting."
        case .sessionComplete:
            title = "Session complete"
            message = "The full schedule has finished."
        }
    }
}
