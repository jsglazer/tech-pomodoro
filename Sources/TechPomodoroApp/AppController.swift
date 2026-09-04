import AppKit
import Combine
import SwiftUI
import TechPomodoroCore

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

    /// Republished once a second purely so SwiftUI re-renders the countdown.
    @Published private(set) var displayNow: Date

    let soundCatalog: SystemSoundCatalog

    private let dateProvider: DateProvider
    private let calendar: Calendar
    private let intervalStore: any IntervalStore
    private let settingsStore: any SettingsStoring
    private let soundPlayer: any SoundPlaying
    private let loginItem: any LoginItemControlling
    private weak var presenter: StatusItemPresenter?

    /// Display refresh only. It never advances the timer by itself: every reduction is handed the
    /// date from `dateProvider`, and remaining time is always derived from `phaseEndsAt`.
    private var refreshTimer: Timer?

    init(
        dateProvider: DateProvider = .system,
        calendar: Calendar = .current,
        intervalStore: any IntervalStore,
        settingsStore: any SettingsStoring,
        soundPlayer: any SoundPlaying = SystemSoundPlayer(),
        soundCatalog: SystemSoundCatalog = SystemSoundCatalog(),
        loginItem: any LoginItemControlling = SMAppServiceLoginItem()
    ) {
        self.dateProvider = dateProvider
        self.calendar = calendar
        self.intervalStore = intervalStore
        self.settingsStore = settingsStore
        self.soundPlayer = soundPlayer
        self.soundCatalog = soundCatalog
        self.loginItem = loginItem
        self.displayNow = dateProvider.now()

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

    func startRefreshing() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.tick) }
        }
        // Common mode, so the countdown keeps updating while a menu or the popover is tracking.
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.willSleep) }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.didWake) }
        }
    }

    // MARK: - Events

    func send(_ event: PomodoroEvent) {
        let now = dateProvider.now()
        displayNow = now
        state = PomodoroReducer.reduce(state, event, now)
        handle(effects: state.pendingEffects)
        persist(records: state.pendingRecords, at: now)
        refreshPresentation()
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

    func setLaunchAtLogin(_ enabled: Bool) {
        let result = loginItem.setEnabled(enabled)
        loginItemWarning = result.warning
        var settings = state.settings
        settings.launchAtLogin = result.isEnabled
        update(settings: settings)
    }

    func previewSound() {
        soundPlayer.play(named: state.settings.soundName)
    }

    // MARK: - Effects

    private func handle(effects: [PomodoroEffect]) {
        for effect in effects {
            guard case .alert = effect else { continue }
            if state.settings.dingEnabled {
                soundPlayer.play(named: state.settings.soundName)
            }
            if state.settings.flashEnabled {
                presenter?.flash()
            }
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

    /// Refreshes the analytics on demand, so hovering shows current numbers without a timer.
    func refreshAnalytics() {
        recomputeAnalytics(at: dateProvider.now())
    }

    private func refreshPresentation() {
        presenter?.apply(MenuBarFormatter.presentation(for: state, at: displayNow))
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
