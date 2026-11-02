import CloudKit
import Foundation
import TechPomodoroCore

/// Owns the `CKSyncEngine` and translates between CloudKit records and the app's data.
///
/// Layout in the private database: one custom zone, `Pomodoro`, holding
/// - one `IntervalRecord` per history record (record name `iv-<uuid>`), immutable once written, and
/// - a single `Settings` record (record name `settings`).
/// Both carry their value as a JSON `payload`, so a field added to the app's types later needs no
/// CloudKit schema change.
actor CloudSyncEngineHost: CKSyncEngineDelegate {

    static let zoneID = CKRecordZone.ID(zoneName: "Pomodoro", ownerName: CKCurrentUserDefaultName)
    static let settingsRecordID = CKRecord.ID(recordName: "settings", zoneID: zoneID)

    enum RecordType {
        static let interval = "IntervalRecord"
        static let settings = "Settings"
    }

    enum Field {
        static let payload = "payload"
        static let startedAt = "startedAt"
        static let modifiedAt = "modifiedAt"
    }

    private weak var owner: CloudSync?
    private let containerIdentifier: String
    private var engine: CKSyncEngine?

    init(owner: CloudSync, containerIdentifier: String) {
        self.owner = owner
        self.containerIdentifier = containerIdentifier
    }

    // MARK: - Lifecycle

    /// Checks the iCloud account, then brings the engine up and queues every local record not yet on
    /// the server. With no saved state this is the first sync from this device (or a fresh account),
    /// so the zone and the settings are queued too. Settings resolve by `modifiedAt`, never by who
    /// happened to send first.
    func start(
        stateSerialization: CKSyncEngine.State.Serialization?,
        pendingIntervalIDs: [UUID],
        createZone: Bool,
        sendSettings: Bool
    ) async -> Bool {
        let container = CKContainer(identifier: containerIdentifier)
        do {
            let account = try await container.accountStatus()
            guard account == .available else {
                await owner?.setStatus(.unavailable(Self.describe(account)))
                return false
            }
        } catch {
            await owner?.setStatus(.error(error.localizedDescription))
            return false
        }

        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: stateSerialization,
            delegate: self
        )
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine

        if createZone {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        }
        if sendSettings {
            enqueueSettings()
        }
        enqueue(intervalIDs: pendingIntervalIDs)
        await fetch()
        return true
    }

    private func seed(_ engine: CKSyncEngine) async {
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        let ids = await owner?.allIntervalIDs() ?? []
        var changes = ids.map { CKSyncEngine.PendingRecordZoneChange.saveRecord(Self.recordID(for: $0)) }
        changes.append(.saveRecord(Self.settingsRecordID))
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    func fetch() async {
        guard let engine else { return }
        do {
            try await engine.fetchChanges()
            await owner?.setStatus(.upToDate(Date()))
        } catch {
            await report(error)
        }
    }

    func enqueue(intervalIDs: [UUID]) {
        engine?.state.add(pendingRecordZoneChanges: intervalIDs.map { .saveRecord(Self.recordID(for: $0)) })
    }

    func enqueueSettings() {
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(Self.settingsRecordID)])
    }

    // MARK: - CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            await owner?.saveState(update.stateSerialization)

        case .accountChange(let change):
            await handleAccountChange(change, engine: syncEngine)

        case .fetchedDatabaseChanges(let changes):
            // Our zone deleted elsewhere (e.g. "Delete data" in iCloud settings): recreate it and
            // upload everything again, since the local copy is now the only one.
            if changes.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
                await owner?.storeSettingsSystemFields(nil)
                await seed(syncEngine)
            }

        case .fetchedRecordZoneChanges(let changes):
            await applyFetched(changes.modifications.map(\.record), engine: syncEngine)

        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords where record.recordType == RecordType.settings {
                await owner?.storeSettingsSystemFields(Self.systemFields(of: record))
            }
            await owner?.markUploaded(sent.savedRecords.compactMap { Self.intervalID(from: $0.recordID) })
            await handleFailedSaves(sent.failedRecordSaves, engine: syncEngine)

        case .willFetchChanges, .willSendChanges:
            await owner?.setStatus(.syncing)

        case .didFetchChanges, .didSendChanges:
            await owner?.setStatus(.upToDate(Date()))

        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }

        var intervalIDs: [UUID] = []
        var wantsSettings = false
        for change in pending {
            guard case .saveRecord(let id) = change else { continue }
            if id == Self.settingsRecordID {
                wantsSettings = true
            } else if let uuid = Self.intervalID(from: id) {
                intervalIDs.append(uuid)
            }
        }
        guard let outgoing = await owner?.outgoing(intervalIDs: intervalIDs, includeSettings: wantsSettings) else {
            return nil
        }

        // A record the provider returns nil for (pruned locally since it was queued) is dropped from
        // the pending list by the engine.
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            Self.makeRecord(for: recordID, from: outgoing)
        }
    }

    // MARK: - Incoming

    private func applyFetched(_ records: [CKRecord], engine: CKSyncEngine) async {
        var intervals: [IntervalRecord] = []
        for record in records {
            switch record.recordType {
            case RecordType.interval:
                if let data = record[Field.payload] as? Data,
                   let interval = try? IntervalRecord.fromSyncPayload(data) {
                    intervals.append(interval)
                }
            case RecordType.settings:
                if let data = record[Field.payload] as? Data,
                   let remote = try? SyncedSettings.decode(data) {
                    let localIsNewer = await owner?.applyServerSettings(remote, systemFields: Self.systemFields(of: record)) ?? false
                    if localIsNewer {
                        engine.state.add(pendingRecordZoneChanges: [.saveRecord(Self.settingsRecordID)])
                    }
                }
            default:
                break
            }
        }
        await owner?.applyFetched(records: intervals)
    }

    private func handleFailedSaves(_ failures: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave], engine: CKSyncEngine) async {
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        var needsZone = false

        for failure in failures {
            let id = failure.record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                if id == Self.settingsRecordID, let server = failure.error.serverRecord,
                   let data = server[Field.payload] as? Data, let remote = try? SyncedSettings.decode(data) {
                    // Someone else wrote the settings since we last saw them: newer edit wins.
                    let localIsNewer = await owner?.applyServerSettings(remote, systemFields: Self.systemFields(of: server)) ?? false
                    if localIsNewer { retry.append(.saveRecord(id)) }
                }
                // An interval that already exists is the same immutable record: it is uploaded.
                if let uuid = Self.intervalID(from: id) { await owner?.markUploaded([uuid]) }

            case .zoneNotFound:
                needsZone = true
                retry.append(.saveRecord(id))

            case .unknownItem:
                // The record we had a change tag for was deleted on the server: save it fresh.
                if id == Self.settingsRecordID { await owner?.storeSettingsSystemFields(nil) }
                retry.append(.saveRecord(id))

            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                 .notAuthenticated, .operationCancelled, .requestRateLimited:
                // The engine keeps these pending and retries on its own.
                break

            case .quotaExceeded:
                await owner?.setStatus(.error("iCloud storage is full"))

            default:
                await owner?.setStatus(.error(failure.error.localizedDescription))
            }
        }

        if needsZone {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        }
        if !retry.isEmpty {
            engine.state.add(pendingRecordZoneChanges: retry)
        }
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange, engine: CKSyncEngine) async {
        switch change.changeType {
        case .signIn:
            await seed(engine)
        case .switchAccounts:
            await owner?.resetForAccountChange()
            await seed(engine)
        case .signOut:
            await owner?.resetForAccountChange()
            await owner?.setStatus(.unavailable("Signed out of iCloud"))
        @unknown default:
            break
        }
    }

    private func report(_ error: Error) async {
        if let ck = error as? CKError {
            switch ck.code {
            case .networkFailure, .networkUnavailable:
                await owner?.setStatus(.error("Offline — will retry"))
                return
            case .notAuthenticated:
                await owner?.setStatus(.unavailable("Not signed in to iCloud"))
                return
            default:
                break
            }
        }
        await owner?.setStatus(.error(error.localizedDescription))
    }

    // MARK: - Record mapping

    static func recordID(for intervalID: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "iv-\(intervalID.uuidString)", zoneID: zoneID)
    }

    static func intervalID(from recordID: CKRecord.ID) -> UUID? {
        guard recordID.recordName.hasPrefix("iv-") else { return nil }
        return UUID(uuidString: String(recordID.recordName.dropFirst(3)))
    }

    private static func makeRecord(for recordID: CKRecord.ID, from outgoing: CloudSyncOutgoing) -> CKRecord? {
        if recordID == settingsRecordID {
            guard let settings = outgoing.settings else { return nil }
            let record = settings.systemFields.flatMap(record(fromSystemFields:))
                ?? CKRecord(recordType: RecordType.settings, recordID: recordID)
            record[Field.payload] = settings.payload as NSData
            record[Field.modifiedAt] = settings.modifiedAt as NSDate
            return record
        }
        guard let uuid = intervalID(from: recordID), let interval = outgoing.intervals[uuid] else { return nil }
        let record = CKRecord(recordType: RecordType.interval, recordID: recordID)
        record[Field.payload] = interval.payload as NSData
        record[Field.startedAt] = interval.startedAt as NSDate
        return record
    }

    /// Just the server bookkeeping (change tag etc.), so the next save of the settings record is an
    /// update of the server's version rather than a conflicting create.
    private static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    private static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .noAccount: return "Not signed in to iCloud"
        case .restricted: return "iCloud is restricted on this device"
        case .temporarilyUnavailable: return "iCloud is temporarily unavailable"
        case .couldNotDetermine: return "Couldn't reach iCloud"
        default: return "iCloud unavailable"
        }
    }
}
