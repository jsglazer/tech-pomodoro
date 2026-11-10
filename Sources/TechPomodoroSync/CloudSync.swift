import CloudKit
import Combine
import Foundation
import TechPomodoroCore

/// What the sync row in Settings shows.
public enum CloudSyncStatus: Equatable, Sendable {
    /// Turned off on this device.
    case off
    /// Can't run here: the build has no iCloud entitlement, or no iCloud account is signed in.
    case unavailable(String)
    case syncing
    case upToDate(Date)
    case error(String)

    public var label: String {
        switch self {
        case .off: return "Off"
        case .unavailable(let why): return why
        case .syncing: return "Syncing…"
        case .upToDate(let date):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "Up to date · \(formatter.localizedString(for: date, relativeTo: Date()))"
        case .error(let message): return "Error: \(message)"
        }
    }

    public var isProblem: Bool {
        switch self {
        case .unavailable, .error: return true
        default: return false
        }
    }
}

/// Settings and interval history, synced through the user's private CloudKit database.
///
/// This is the main-actor face of sync: it owns the local data the sync engine reads and writes, and
/// tells the app controller when something arrived from another device. The `CKSyncEngine` itself
/// lives in `CloudSyncEngineHost`, an actor. Every merge decision is `SyncMerge`'s, in the core.
///
/// Changes are pushed by CloudKit shortly after they are queued. Changes from other devices are
/// pulled when sync starts, whenever the app calls `fetchNow()` (wake, popover open, app foreground),
/// and on a slow poll — no push entitlement is needed.
@MainActor
public final class CloudSync: ObservableObject {

    nonisolated public static let containerIdentifier = "iCloud.com.jsglazer.tech-pomodoro"

    /// Something another device changed, already written to the local stores.
    public enum Change {
        case history([IntervalRecord])
        case settings(PomodoroSettings)
        /// Paper corrections arrived; the full merged list.
        case corrections([PaperCorrection])
    }

    @Published public private(set) var status: CloudSyncStatus = .off

    private let intervalStore: any IntervalStore
    private let settingsStore: any SettingsStoring
    private let correctionStore: (any PaperCorrectionStoring)?
    private let defaults: UserDefaults
    private let stateURL: URL?
    private let calendar: Calendar
    private let pollInterval: TimeInterval
    private let onChange: (Change) -> Void

    private var host: CloudSyncEngineHost?
    private var pollTimer: Timer?

    private enum Key {
        static let settingsModifiedAt = "sync.settingsModifiedAt"
        static let settingsSystemFields = "sync.settingsSystemFields"
        /// Ids of history records known to be on the server, so a start uploads exactly the ones
        /// written while sync was off, or before it came up.
        static let uploadedIntervals = "sync.uploadedIntervals"
        /// The same, for paper corrections.
        static let uploadedCorrections = "sync.uploadedCorrections"
    }

    public init(
        intervalStore: any IntervalStore,
        settingsStore: any SettingsStoring,
        correctionStore: (any PaperCorrectionStoring)? = nil,
        defaults: UserDefaults = .standard,
        stateURL: URL?,
        calendar: Calendar = .current,
        pollInterval: TimeInterval = 10 * 60,
        onChange: @escaping (Change) -> Void
    ) {
        self.intervalStore = intervalStore
        self.settingsStore = settingsStore
        self.correctionStore = correctionStore
        self.defaults = defaults
        self.stateURL = stateURL
        self.calendar = calendar
        self.pollInterval = pollInterval
        self.onChange = onChange
    }

    /// `cloudkit-state.json` beside the interval history.
    public static func defaultStateURL() -> URL? {
        (try? FileIntervalStore.applicationSupportURL())?
            .deletingLastPathComponent()
            .appendingPathComponent("cloudkit-state.json", isDirectory: false)
    }

    // MARK: - Lifecycle

    /// Starts or stops sync to match the setting. Safe to call repeatedly.
    public func setEnabled(_ enabled: Bool) {
        if enabled {
            guard host == nil else { return }
            start()
        } else {
            stop()
            status = .off
        }
    }

    private func start() {
        guard CloudSyncEntitlement.isPresent else {
            status = .unavailable("Not available in this build (no iCloud entitlement)")
            return
        }
        status = .syncing
        let saved = loadState()
        let host = CloudSyncEngineHost(owner: self, containerIdentifier: Self.containerIdentifier)
        self.host = host
        let unsent = unsentIntervalIDs()
        let unsentCorrections = unsentCorrectionIDs()
        // The settings record has never reached the server (first sync, or every earlier attempt
        // failed — say, before the schema was deployed), so offer it again.
        let settingsUnsent = defaults.data(forKey: Key.settingsSystemFields) == nil
        Task {
            let ready = await host.start(
                stateSerialization: saved,
                pendingIntervalIDs: unsent,
                pendingCorrectionIDs: unsentCorrections,
                createZone: saved == nil,
                sendSettings: saved == nil || settingsUnsent
            )
            if ready { self.startPolling() }
        }
    }

    private func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        host = nil
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fetchNow() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Pulls whatever the other devices have pushed since the last fetch.
    public func fetchNow() {
        guard let host else { return }
        Task { await host.fetch() }
    }

    // MARK: - Local changes going out

    /// New history records were written locally.
    public func recordsAdded(_ records: [IntervalRecord]) {
        guard let host, !records.isEmpty else { return }
        let ids = records.map(\.id)
        Task { await host.enqueue(intervalIDs: ids) }
    }

    /// Paper corrections were written locally.
    public func correctionsAdded(_ corrections: [PaperCorrection]) {
        guard let host, !corrections.isEmpty else { return }
        let ids = corrections.map(\.id)
        Task { await host.enqueue(correctionIDs: ids) }
    }

    /// The user changed a setting. Only a change to a field that syncs is stamped and pushed.
    public func settingsChanged(from old: PomodoroSettings, to new: PomodoroSettings, at now: Date = Date()) {
        guard SyncMerge.syncedFieldsDiffer(old, new) else { return }
        defaults.set(now, forKey: Key.settingsModifiedAt)
        guard let host else { return }
        Task { await host.enqueueSettings() }
    }

    // MARK: - Called by the engine host

    func setStatus(_ newStatus: CloudSyncStatus) {
        // Once stopped, a late callback from the old host must not overwrite `.off`.
        guard host != nil else { return }
        status = newStatus
    }

    /// Everything the engine needs to build the records it is about to send.
    func outgoing(intervalIDs: [UUID], correctionIDs: [UUID] = [], includeSettings: Bool) -> CloudSyncOutgoing {
        let wanted = Set(intervalIDs)
        var intervals: [UUID: CloudSyncOutgoing.Interval] = [:]
        if !wanted.isEmpty, let history = try? intervalStore.load() {
            for record in history where wanted.contains(record.id) {
                if let payload = try? record.syncPayload() {
                    intervals[record.id] = .init(payload: payload, startedAt: record.startedAt)
                }
            }
        }
        var corrections: [UUID: CloudSyncOutgoing.Interval] = [:]
        let wantedCorrections = Set(correctionIDs)
        if !wantedCorrections.isEmpty, let correctionStore {
            for correction in correctionStore.load() where wantedCorrections.contains(correction.id) {
                if let payload = try? correction.syncPayload() {
                    corrections[correction.id] = .init(payload: payload, startedAt: correction.modifiedAt)
                }
            }
        }
        var settings: CloudSyncOutgoing.Settings?
        if includeSettings {
            let synced = SyncedSettings(settings: settingsStore.load(), modifiedAt: localSettingsModifiedAt)
            if let payload = try? synced.encoded() {
                settings = .init(payload: payload, modifiedAt: synced.modifiedAt, systemFields: defaults.data(forKey: Key.settingsSystemFields))
            }
        }
        return CloudSyncOutgoing(intervals: intervals, corrections: corrections, settings: settings)
    }

    /// Every record id in the local history, for a fresh upload after the zone or account reset.
    func allIntervalIDs() -> [UUID] {
        ((try? intervalStore.load()) ?? []).map(\.id)
    }

    /// Every local paper correction id.
    func allCorrectionIDs() -> [UUID] {
        (correctionStore?.load() ?? []).map(\.id)
    }

    private func unsentCorrectionIDs() -> [UUID] {
        let uploaded = Set(defaults.stringArray(forKey: Key.uploadedCorrections) ?? [])
        return allCorrectionIDs().filter { !uploaded.contains($0.uuidString) }
    }

    func markCorrectionsUploaded(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let local = Set(allCorrectionIDs().map(\.uuidString))
        var uploaded = Set(defaults.stringArray(forKey: Key.uploadedCorrections) ?? [])
        uploaded.formUnion(ids.map(\.uuidString))
        uploaded.formIntersection(local)
        defaults.set(Array(uploaded).sorted(), forKey: Key.uploadedCorrections)
    }

    /// Corrections fetched from other devices: merged into the local list.
    func applyFetched(corrections: [PaperCorrection]) {
        guard !corrections.isEmpty, let correctionStore else { return }
        let local = correctionStore.load()
        let merged = PaperHistory.mergeCorrections(local: local, remote: corrections, now: Date(), calendar: calendar)
        if merged != local {
            do {
                try correctionStore.replace(with: merged)
                onChange(.corrections(merged))
            } catch {
                NSLog("tech-pomodoro: could not write synced paper corrections: \(error.localizedDescription)")
                return
            }
        }
        markCorrectionsUploaded(corrections.map(\.id))
    }

    /// Local records not yet known to be on the server.
    private func unsentIntervalIDs() -> [UUID] {
        let uploaded = Set(defaults.stringArray(forKey: Key.uploadedIntervals) ?? [])
        return allIntervalIDs().filter { !uploaded.contains($0.uuidString) }
    }

    /// These records are on the server (sent from here, or fetched from it). The set is trimmed to
    /// the local history, so it shrinks as old records are pruned.
    func markUploaded(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let local = Set(allIntervalIDs().map(\.uuidString))
        var uploaded = Set(defaults.stringArray(forKey: Key.uploadedIntervals) ?? [])
        uploaded.formUnion(ids.map(\.uuidString))
        uploaded.formIntersection(local)
        defaults.set(Array(uploaded).sorted(), forKey: Key.uploadedIntervals)
    }

    /// Records fetched from other devices: merged into the local history.
    func applyFetched(records: [IntervalRecord]) {
        guard !records.isEmpty else { return }
        let local = (try? intervalStore.load()) ?? []
        let merged = SyncMerge.mergeHistory(local: local, remote: records, now: Date(), calendar: calendar)
        guard merged != local else {
            markUploaded(records.map(\.id))
            return
        }
        do {
            try intervalStore.replace(with: merged)
            markUploaded(records.map(\.id))
            onChange(.history(merged))
        } catch {
            NSLog("tech-pomodoro: could not write synced history: \(error.localizedDescription)")
        }
    }

    /// The settings record as the server holds it. Adopted when it is newer; returns true when the
    /// local copy is newer and should be pushed over it instead.
    @discardableResult
    func applyServerSettings(_ remote: SyncedSettings, systemFields: Data?) -> Bool {
        if let systemFields { defaults.set(systemFields, forKey: Key.settingsSystemFields) }
        switch SyncMerge.settingsWinner(localModifiedAt: localSettingsModifiedAt, remoteModifiedAt: remote.modifiedAt) {
        case .local:
            return true
        case .remote:
            let local = settingsStore.load()
            let adopted = SyncMerge.adopt(remote: remote.settings, keepingDeviceFieldsOf: local)
            defaults.set(remote.modifiedAt, forKey: Key.settingsModifiedAt)
            if adopted != local {
                settingsStore.save(adopted)
                onChange(.settings(adopted))
            }
            return false
        }
    }

    func storeSettingsSystemFields(_ data: Data?) {
        if let data {
            defaults.set(data, forKey: Key.settingsSystemFields)
        } else {
            defaults.removeObject(forKey: Key.settingsSystemFields)
        }
    }

    /// The iCloud account went away or changed: forget everything tied to the old one. Local data
    /// stays; a new account gets it all uploaded afresh.
    func resetForAccountChange() {
        storeSettingsSystemFields(nil)
        defaults.removeObject(forKey: Key.uploadedIntervals)
        defaults.removeObject(forKey: Key.uploadedCorrections)
        if let stateURL { try? FileManager.default.removeItem(at: stateURL) }
    }

    func saveState(_ serialization: CKSyncEngine.State.Serialization) {
        guard let stateURL else { return }
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(serialization).write(to: stateURL, options: .atomic)
        } catch {
            NSLog("tech-pomodoro: could not save sync state: \(error.localizedDescription)")
        }
    }

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let stateURL, let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    /// Never edited on this device means `.distantPast`, so the first sync adopts the other devices'
    /// settings rather than overwriting them with this one's defaults.
    private var localSettingsModifiedAt: Date {
        (defaults.object(forKey: Key.settingsModifiedAt) as? Date) ?? .distantPast
    }
}

/// A snapshot of local data, handed across to the engine actor as plain values.
struct CloudSyncOutgoing: Sendable {
    struct Interval: Sendable {
        let payload: Data
        let startedAt: Date
    }

    struct Settings: Sendable {
        let payload: Data
        let modifiedAt: Date
        let systemFields: Data?
    }

    let intervals: [UUID: Interval]
    /// Paper corrections, keyed by correction id; same shape as an interval.
    var corrections: [UUID: Interval] = [:]
    let settings: Settings?
}
