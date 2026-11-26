import CloudKit
import Foundation
import TechPomodoroCore

/// Owns the `CKSyncEngine` and translates between CloudKit records and the app's data.
///
/// Layout in the private database: one custom zone, `Pomodoro`, holding
/// - one `IntervalRecord` per history record (record name `iv-<uuid>`), immutable once written, and
/// - a single `Settings` record (record name `settings`), and
/// - one record per paper correction (record name `pc-<uuid>`), stored as the `IntervalRecord` type
///   with the correction's JSON as its payload, so no schema change is needed. An older build reads
///   the payload as an interval, fails to decode it, and skips it; its history is unaffected.
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
    private let connector: Connector
    /// Nil until `start()` has the engine up.
    private var driver: (any SyncEngineDriving)?
    /// Changes queued before the engine exists. `start()` awaits the iCloud account first, and actor
    /// reentrancy lets an enqueue run in that gap; without this it would be a silent no-op.
    private(set) var buffered: [CKSyncEngine.PendingRecordZoneChange] = []

    /// How the host gets its engine: checks the account and builds a `CKSyncEngine` with the host as
    /// its delegate. Injected so the start-up path can be tested without iCloud.
    typealias Connector = @Sendable (CloudSyncEngineHost, CKSyncEngine.State.Serialization?) async -> Connection

    enum Connection: Sendable {
        case ready(any SyncEngineDriving)
        case unavailable(CloudSyncStatus)
    }

    init(owner: CloudSync, containerIdentifier: String, connector: Connector? = nil) {
        self.owner = owner
        self.containerIdentifier = containerIdentifier
        self.connector = connector ?? { host, state in await Self.connectToCloudKit(host: host, containerIdentifier: containerIdentifier, state: state) }
    }

    // MARK: - Lifecycle

    /// Checks the iCloud account, then brings the engine up and queues every local record not yet on
    /// the server, plus anything enqueued while it was coming up. With no saved state this is the
    /// first sync from this device (or a fresh account), so the zone is queued too. Settings resolve
    /// by `modifiedAt`, never by who happened to send first.
    func start(
        stateSerialization: CKSyncEngine.State.Serialization?,
        pendingIntervalIDs: [UUID],
        pendingCorrectionIDs: [UUID] = [],
        createZone: Bool,
        sendSettings: Bool
    ) async -> Bool {
        let driver: any SyncEngineDriving
        switch await connector(self, stateSerialization) {
        case .unavailable(let status):
            await owner?.setStatus(status, from: self)
            return false
        case .ready(let ready):
            driver = ready
        }
        self.driver = driver

        if createZone {
            driver.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        }
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        if sendSettings { changes.append(.saveRecord(Self.settingsRecordID)) }
        changes += pendingIntervalIDs.map { .saveRecord(Self.recordID(for: $0)) }
        changes += pendingCorrectionIDs.map { .saveRecord(Self.correctionRecordID(for: $0)) }
        changes += buffered
        buffered = []
        if !changes.isEmpty { driver.add(pendingRecordZoneChanges: changes) }
        await fetch()
        return true
    }

    /// The real connection: the account check, then a `CKSyncEngine` delegating to `host`.
    private static func connectToCloudKit(host: CloudSyncEngineHost, containerIdentifier: String, state: CKSyncEngine.State.Serialization?) async -> Connection {
        let container = CKContainer(identifier: containerIdentifier)
        do {
            let account = try await container.accountStatus()
            guard account == .available else { return .unavailable(.unavailable(describe(account))) }
        } catch {
            return .unavailable(.error(error.localizedDescription))
        }
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: state,
            delegate: host
        )
        configuration.automaticallySync = true
        return .ready(LiveSyncEngine(engine: CKSyncEngine(configuration)))
    }

    private func seed(_ engine: CKSyncEngine) async {
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        let ids = await owner?.allIntervalIDs() ?? []
        var changes = ids.map { CKSyncEngine.PendingRecordZoneChange.saveRecord(Self.recordID(for: $0)) }
        let corrections = await owner?.allCorrectionIDs() ?? []
        changes += corrections.map { .saveRecord(Self.correctionRecordID(for: $0)) }
        changes.append(.saveRecord(Self.settingsRecordID))
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    func fetch() async {
        guard let driver else { return }
        do {
            try await driver.fetchChanges()
            await owner?.setStatus(.upToDate(Date()), from: self)
        } catch {
            await report(error)
        }
    }

    func enqueue(intervalIDs: [UUID]) {
        add(intervalIDs.map { .saveRecord(Self.recordID(for: $0)) })
    }

    func enqueue(correctionIDs: [UUID]) {
        add(correctionIDs.map { .saveRecord(Self.correctionRecordID(for: $0)) })
    }

    func enqueueSettings() {
        add([.saveRecord(Self.settingsRecordID)])
    }

    /// To the engine, or held until `start()` has one.
    private func add(_ changes: [CKSyncEngine.PendingRecordZoneChange]) {
        guard !changes.isEmpty else { return }
        if let driver {
            driver.add(pendingRecordZoneChanges: changes)
        } else {
            buffered += changes
        }
    }

    // MARK: - CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            await owner?.saveState(update.stateSerialization, from: self)

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
                await owner?.storeSettingsSystemFields(Self.systemFields(of: record), uploadedModifiedAt: record[Field.modifiedAt] as? Date)
            }
            await owner?.markUploaded(sent.savedRecords.compactMap { Self.intervalID(from: $0.recordID) })
            await owner?.markCorrectionsUploaded(sent.savedRecords.compactMap { Self.correctionID(from: $0.recordID) })
            await handleFailedSaves(sent.failedRecordSaves, engine: syncEngine)

        case .willFetchChanges, .willSendChanges:
            await owner?.setStatus(.syncing, from: self)

        case .didFetchChanges, .didSendChanges:
            await owner?.setStatus(.upToDate(Date()), from: self)

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
        var correctionIDs: [UUID] = []
        var wantsSettings = false
        for change in pending {
            guard case .saveRecord(let id) = change else { continue }
            if id == Self.settingsRecordID {
                wantsSettings = true
            } else if let uuid = Self.intervalID(from: id) {
                intervalIDs.append(uuid)
            } else if let uuid = Self.correctionID(from: id) {
                correctionIDs.append(uuid)
            }
        }
        guard let outgoing = await owner?.outgoing(intervalIDs: intervalIDs, correctionIDs: correctionIDs, includeSettings: wantsSettings) else {
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
        var corrections: [PaperCorrection] = []
        for record in records {
            switch record.recordType {
            case RecordType.interval where Self.correctionID(from: record.recordID) != nil:
                if let data = record[Field.payload] as? Data,
                   let correction = try? PaperCorrection.fromSyncPayload(data) {
                    corrections.append(correction)
                }
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
        await owner?.applyFetched(corrections: corrections)
    }

    /// What to do about one record CloudKit refused to save.
    enum FailedSaveAction: Equatable {
        /// Someone else wrote it: merge (settings) or count it uploaded (immutable records).
        case resolveConflict
        /// The zone is gone: recreate it, then save again.
        case recreateZone
        /// The server forgot the record we had a change tag for: save it fresh.
        case saveFresh
        /// Transient: the engine keeps it pending and retries by itself.
        case engineRetries
        /// The batch failed as a whole because of another record in it: this one is innocent, so
        /// put it back in the queue.
        case requeue
        case quotaExceeded
        /// Anything else: report it; the next launch's unsent set offers it again.
        case report
    }

    static func action(for code: CKError.Code) -> FailedSaveAction {
        switch code {
        case .serverRecordChanged: return .resolveConflict
        case .zoneNotFound: return .recreateZone
        case .unknownItem: return .saveFresh
        case .batchRequestFailed: return .requeue
        case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
             .notAuthenticated, .operationCancelled, .requestRateLimited:
            return .engineRetries
        case .quotaExceeded: return .quotaExceeded
        default: return .report
        }
    }

    private func handleFailedSaves(_ failures: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave], engine: CKSyncEngine) async {
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        var needsZone = false

        for failure in failures {
            let id = failure.record.recordID
            switch Self.action(for: failure.error.code) {
            case .resolveConflict:
                if id == Self.settingsRecordID, let server = failure.error.serverRecord,
                   let data = server[Field.payload] as? Data, let remote = try? SyncedSettings.decode(data) {
                    // Someone else wrote the settings since we last saw them: newer edit wins.
                    let localIsNewer = await owner?.applyServerSettings(remote, systemFields: Self.systemFields(of: server)) ?? false
                    if localIsNewer { retry.append(.saveRecord(id)) }
                }
                // An interval that already exists is the same immutable record: it is uploaded.
                if let uuid = Self.intervalID(from: id) { await owner?.markUploaded([uuid]) }
                if let uuid = Self.correctionID(from: id) { await owner?.markCorrectionsUploaded([uuid]) }

            case .recreateZone:
                needsZone = true
                retry.append(.saveRecord(id))

            case .saveFresh:
                if id == Self.settingsRecordID { await owner?.storeSettingsSystemFields(nil) }
                retry.append(.saveRecord(id))

            case .requeue:
                retry.append(.saveRecord(id))

            case .engineRetries:
                break

            case .quotaExceeded:
                await owner?.setStatus(.error("iCloud storage is full"), from: self)

            case .report:
                await owner?.setStatus(.error(failure.error.localizedDescription), from: self)
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
            await owner?.setStatus(.unavailable("Signed out of iCloud"), from: self)
        @unknown default:
            break
        }
    }

    private func report(_ error: Error) async {
        if let ck = error as? CKError {
            switch ck.code {
            case .networkFailure, .networkUnavailable:
                await owner?.setStatus(.error("Offline — will retry"), from: self)
                return
            case .notAuthenticated:
                await owner?.setStatus(.unavailable("Not signed in to iCloud"), from: self)
                return
            default:
                break
            }
        }
        await owner?.setStatus(.error(error.localizedDescription), from: self)
    }

    // MARK: - Record mapping

    static func recordID(for intervalID: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "iv-\(intervalID.uuidString)", zoneID: zoneID)
    }

    static func intervalID(from recordID: CKRecord.ID) -> UUID? {
        guard recordID.recordName.hasPrefix("iv-") else { return nil }
        return UUID(uuidString: String(recordID.recordName.dropFirst(3)))
    }

    static func correctionRecordID(for correctionID: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "pc-\(correctionID.uuidString)", zoneID: zoneID)
    }

    static func correctionID(from recordID: CKRecord.ID) -> UUID? {
        guard recordID.recordName.hasPrefix("pc-") else { return nil }
        return UUID(uuidString: String(recordID.recordName.dropFirst(3)))
    }

    private static func makeRecord(for recordID: CKRecord.ID, from outgoing: CloudSyncOutgoing) -> CKRecord? {
        if let uuid = correctionID(from: recordID) {
            guard let correction = outgoing.corrections[uuid] else { return nil }
            let record = CKRecord(recordType: RecordType.interval, recordID: recordID)
            record[Field.payload] = correction.payload as NSData
            record[Field.startedAt] = correction.startedAt as NSDate
            return record
        }
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

/// The part of `CKSyncEngine` the host drives directly; a seam so start-up can be tested.
protocol SyncEngineDriving: Sendable {
    func add(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
    func add(pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange])
    func fetchChanges() async throws
}

struct LiveSyncEngine: SyncEngineDriving {
    let engine: CKSyncEngine

    func add(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange]) {
        engine.state.add(pendingRecordZoneChanges: pendingRecordZoneChanges)
    }

    func add(pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange]) {
        engine.state.add(pendingDatabaseChanges: pendingDatabaseChanges)
    }

    func fetchChanges() async throws {
        try await engine.fetchChanges()
    }
}
