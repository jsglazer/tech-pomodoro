import CloudKit
import Foundation
import Testing
import TechPomodoroCore
@testable import TechPomodoroSync

// The sync host's start-up path, driven through a fake engine (no iCloud needed). Regression tests
// for the 2026-11-11 audit's Medium and the host-identity Low (Update016).

/// Records what the host queues on the "engine".
final class FakeDriver: SyncEngineDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var _recordNames: [String] = []
    private var _zoneSaves = 0

    var recordNames: [String] { lock.withLock { _recordNames } }
    var zoneSaves: Int { lock.withLock { _zoneSaves } }

    func add(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange]) {
        let names = pendingRecordZoneChanges.compactMap { change -> String? in
            if case .saveRecord(let id) = change { return id.recordName }
            return nil
        }
        lock.withLock { _recordNames += names }
    }

    func add(pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange]) {
        lock.withLock { _zoneSaves += pendingDatabaseChanges.count }
    }

    func fetchChanges() async throws {}
}

/// Holds a connection open until the test lets it through, like `accountStatus()` still pending.
actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private(set) var isWaiting = false

    func wait() async {
        guard !opened else { return }
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func makeSync(defaults: UserDefaults) -> CloudSync {
    let sync = CloudSync(
        intervalStore: MemoryIntervalStore(),
        settingsStore: MemorySettingsStore(),
        defaults: defaults,
        stateURL: nil,
        onChange: { _ in }
    )
    sync.requiresEntitlement = false
    return sync
}

private func freshDefaults() -> UserDefaults {
    let name = "tech-pomodoro.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
private func waitUntilWaiting(_ gate: Gate) async {
    for _ in 0..<1000 where !(await gate.isWaiting) {
        await Task.yield()
    }
}

@Suite("Sync host start-up")
@MainActor
struct CloudSyncStartupTests {

    @Test func enqueuesDuringStartUpAreFlushedToTheEngine() async {
        let sync = makeSync(defaults: freshDefaults())
        let driver = FakeDriver()
        let gate = Gate()
        let host = CloudSyncEngineHost(owner: sync, containerIdentifier: "iCloud.test", connector: { _, _ in
            await gate.wait()
            return .ready(driver)
        })
        let interval = UUID()
        let correction = UUID()
        let start = Task {
            await host.start(stateSerialization: nil, pendingIntervalIDs: [], createZone: true, sendSettings: false)
        }
        await waitUntilWaiting(gate)

        // In the gap while the account check is still out: before the fix these were no-ops.
        await host.enqueueSettings()
        await host.enqueue(intervalIDs: [interval])
        await host.enqueue(correctionIDs: [correction])
        #expect(driver.recordNames.isEmpty)
        #expect(await host.buffered.count == 3)

        await gate.open()
        #expect(await start.value)
        #expect(Set(driver.recordNames) == ["settings", "iv-\(interval.uuidString)", "pc-\(correction.uuidString)"])
        #expect(driver.zoneSaves == 1)
        #expect(await host.buffered.isEmpty)
    }

    @Test func afterStartEnqueuesGoStraightToTheEngine() async {
        let sync = makeSync(defaults: freshDefaults())
        let driver = FakeDriver()
        let host = CloudSyncEngineHost(owner: sync, containerIdentifier: "iCloud.test", connector: { _, _ in .ready(driver) })
        #expect(await host.start(stateSerialization: nil, pendingIntervalIDs: [], createZone: false, sendSettings: true))
        await host.enqueueSettings()
        #expect(driver.recordNames == ["settings", "settings"])
        #expect(await host.buffered.isEmpty)
    }

    @Test func anUnavailableAccountReportsAndDoesNotStart() async {
        let sync = makeSync(defaults: freshDefaults())
        let host = CloudSyncEngineHost(owner: sync, containerIdentifier: "iCloud.test", connector: { _, _ in .unavailable(.unavailable("No account")) })
        #expect(!(await host.start(stateSerialization: nil, pendingIntervalIDs: [], createZone: false, sendSettings: false)))
    }

    @Test func aReplacedHostCannotPollOrOverwriteStatus() async {
        let sync = makeSync(defaults: freshDefaults())
        final class Box { var gates: [Gate] = [] }
        let box = Box()
        sync.makeHost = { owner in
            let gate = Gate()
            box.gates.append(gate)
            return CloudSyncEngineHost(owner: owner, containerIdentifier: "iCloud.test", connector: { _, _ in
                await gate.wait()
                return .ready(FakeDriver())
            })
        }

        sync.setEnabled(true)
        let first = sync.startTask
        // A quick off/on toggle while the first host is still waiting on the account.
        sync.setEnabled(false)
        sync.setEnabled(true)
        let second = sync.startTask
        #expect(box.gates.count == 2)

        await box.gates[0].open()
        await first?.value
        #expect(!sync.isPolling)
        #expect(sync.status == .syncing)

        await box.gates[1].open()
        await second?.value
        #expect(sync.isPolling)
        if case .upToDate = sync.status {} else { Issue.record("expected upToDate, got \(sync.status)") }
        sync.setEnabled(false)
    }
}

@Suite("Sync: settings upload bookkeeping")
@MainActor
struct SettingsUploadStampTests {

    @Test func anEditWithSyncOffIsOfferedAtTheNextStart() {
        let defaults = freshDefaults()
        let sync = makeSync(defaults: defaults)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        sync.storeSettingsSystemFields(Data([1]), uploadedModifiedAt: t0)
        defaults.set(t0, forKey: "sync.settingsModifiedAt")
        #expect(!sync.shouldOfferSettings(hasSavedState: true))

        var changed = PomodoroSettings()
        changed.workMinutes = 50
        // Sync is off: nothing is queued, but the edit is stamped.
        sync.settingsChanged(from: PomodoroSettings(), to: changed, at: t0.addingTimeInterval(30))
        #expect(sync.shouldOfferSettings(hasSavedState: true))
    }

    @Test func adoptingTheServerCopyMeansNothingIsPending() {
        let defaults = freshDefaults()
        let sync = makeSync(defaults: defaults)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        defaults.set(t0, forKey: "sync.settingsModifiedAt")
        sync.storeSettingsSystemFields(Data([1]), uploadedModifiedAt: nil)
        var remote = PomodoroSettings()
        remote.workMinutes = 40
        sync.applyServerSettings(SyncedSettings(settings: remote, modifiedAt: t0.addingTimeInterval(60)), systemFields: Data([2]))
        #expect(!sync.shouldOfferSettings(hasSavedState: true))
    }

    @Test func forgettingTheRecordForgetsTheStamp() {
        let defaults = freshDefaults()
        let sync = makeSync(defaults: defaults)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        defaults.set(t0, forKey: "sync.settingsModifiedAt")
        sync.storeSettingsSystemFields(Data([1]), uploadedModifiedAt: t0)
        sync.storeSettingsSystemFields(nil)
        #expect(sync.shouldOfferSettings(hasSavedState: true))
    }
}

@Suite("Sync: failed saves")
struct FailedSaveActionTests {
    @Test func aBatchFailedByAnotherRecordIsRequeued() {
        #expect(CloudSyncEngineHost.action(for: .batchRequestFailed) == .requeue)
    }

    @Test func otherCodesKeepTheirHandling() {
        #expect(CloudSyncEngineHost.action(for: .serverRecordChanged) == .resolveConflict)
        #expect(CloudSyncEngineHost.action(for: .zoneNotFound) == .recreateZone)
        #expect(CloudSyncEngineHost.action(for: .unknownItem) == .saveFresh)
        #expect(CloudSyncEngineHost.action(for: .networkFailure) == .engineRetries)
        #expect(CloudSyncEngineHost.action(for: .quotaExceeded) == .quotaExceeded)
        #expect(CloudSyncEngineHost.action(for: .permissionFailure) == .report)
    }
}
