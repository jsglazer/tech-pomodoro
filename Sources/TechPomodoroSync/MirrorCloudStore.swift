import CloudKit
import Foundation
import TechPomodoroCore

/// Everything the mirror records hold, read in one query.
public struct MirrorSnapshot: Sendable {
    public var phones: [MirrorPhone] = []
    public var timers: [MirrorTimer] = []
    public var channels: [APNsEnvironment: MirrorChannel] = [:]
    /// Each iPhone's own timer (`iphone-<id>`), for the Macs to show and push boundaries for.
    public var phoneTimers: [MirrorTimer] = []
    /// Each iPhone's own broadcast channel (`ownchannel-<id>`), keyed by the iPhone's device id. A Mac
    /// creates it; the iPhone's own Live Activity listens on it.
    public var ownChannels: [String: MirrorChannel] = [:]

    public init() {}
}

/// The records that hand the Mac timer to the iPhone: one `MirrorRecord` per iPhone (`phone-<id>`),
/// per Mac (`mac-<id>`), and per APNs environment's broadcast channel (`channel-<env>`), each carrying
/// its value as a JSON `payload`. The other way round, each iPhone's own timer (`iphone-<id>`) and the
/// channel its own Live Activity listens on (`ownchannel-<id>`) let a Mac show and push that timer.
///
/// They sit in the same `Pomodoro` zone as settings and history but are read and written directly
/// rather than through the sync engine: the Mac needs the newest tokens the moment before it pushes,
/// and an iPhone launched in the background for a moment must be able to save its token at once. The
/// sync engine sees them in its fetches and ignores them. Works whether or not "Sync via iCloud" is
/// on — mirroring has its own switch.
public final class MirrorCloudStore: Sendable {

    public static let recordType = "MirrorRecord"

    private enum Field {
        static let payload = "payload"
        static let modifiedAt = "modifiedAt"
    }

    private let containerIdentifier: String
    private var zoneID: CKRecordZone.ID { CloudSyncEngineHost.zoneID }

    public init(containerIdentifier: String = CloudSync.containerIdentifier) {
        self.containerIdentifier = containerIdentifier
    }

    /// False in a build without the iCloud entitlement, where any CloudKit call would trap.
    public static var isAvailable: Bool { CloudSyncEntitlement.isPresent }

    private var database: CKDatabase {
        CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    // MARK: - Reading

    public func fetchAll() async throws -> MirrorSnapshot {
        var snapshot = MirrorSnapshot()
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(value: true))
        var cursor: CKQueryOperation.Cursor?
        var results: [(CKRecord.ID, Result<CKRecord, any Error>)] = []
        do {
            let first = try await database.records(matching: query, inZoneWith: zoneID, resultsLimit: 200)
            results = first.matchResults
            cursor = first.queryCursor
            while let next = cursor {
                let page = try await database.records(continuingMatchFrom: next, resultsLimit: 200)
                results += page.matchResults
                cursor = page.queryCursor
            }
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            // No zone yet, or the record type is not in the schema yet: nothing to read.
            return snapshot
        }

        for (id, result) in results {
            guard case .success(let record) = result, let data = record[Field.payload] as? Data else { continue }
            let name = id.recordName
            if name.hasPrefix("phone-"), let phone = try? MirrorCodec.decode(MirrorPhone.self, from: data) {
                snapshot.phones.append(phone)
            } else if name.hasPrefix("mac-"), let timer = try? MirrorCodec.decode(MirrorTimer.self, from: data) {
                snapshot.timers.append(timer)
            } else if name.hasPrefix("channel-"), let channel = try? MirrorCodec.decode(MirrorChannel.self, from: data) {
                snapshot.channels[channel.environment] = channel
            } else if name.hasPrefix("iphone-"), let timer = try? MirrorCodec.decode(MirrorTimer.self, from: data) {
                snapshot.phoneTimers.append(timer)
            } else if name.hasPrefix(Self.ownChannelPrefix), let channel = try? MirrorCodec.decode(MirrorChannel.self, from: data) {
                snapshot.ownChannels[String(name.dropFirst(Self.ownChannelPrefix.count))] = channel
            }
        }
        return snapshot
    }

    // MARK: - Writing

    public func save(phone: MirrorPhone) async throws {
        try await save(name: "phone-\(phone.deviceID)", payload: MirrorCodec.encode(phone))
    }

    public func save(timer: MirrorTimer) async throws {
        try await save(name: "mac-\(timer.deviceID)", payload: MirrorCodec.encode(timer))
    }

    public func save(channel: MirrorChannel) async throws {
        try await save(name: Self.channelName(channel.environment), payload: MirrorCodec.encode(channel))
    }

    /// An iPhone's own timer.
    public func save(phoneTimer: MirrorTimer) async throws {
        try await save(name: "iphone-\(phoneTimer.deviceID)", payload: MirrorCodec.encode(phoneTimer))
    }

    /// The channel an iPhone's own Live Activity listens on.
    public func save(ownChannel: MirrorChannel, phoneID: String) async throws {
        try await save(name: Self.ownChannelPrefix + phoneID, payload: MirrorCodec.encode(ownChannel))
    }

    /// `claim(channel:)` for an iPhone's own channel.
    public func claim(ownChannel: MirrorChannel, phoneID: String) async throws -> MirrorChannel {
        try await claim(channel: ownChannel, name: Self.ownChannelPrefix + phoneID)
    }

    private static let ownChannelPrefix = "ownchannel-"

    /// Stores a freshly created channel unless another Mac got there first, in which case its channel
    /// is returned instead, so every Mac pushes to the one channel the iPhones listen to.
    public func claim(channel: MirrorChannel) async throws -> MirrorChannel {
        try await claim(channel: channel, name: Self.channelName(channel.environment))
    }

    private func claim(channel: MirrorChannel, name: String) async throws -> MirrorChannel {
        let record = CKRecord(recordType: Self.recordType, recordID: recordID(name))
        record[Field.payload] = try MirrorCodec.encode(channel) as NSData
        record[Field.modifiedAt] = Date() as NSDate
        do {
            try await modify(record, policy: .ifServerRecordUnchanged)
            return channel
        } catch let error as CKError where error.code == .serverRecordChanged {
            if let server = error.serverRecord, let data = server[Field.payload] as? Data,
               let existing = try? MirrorCodec.decode(MirrorChannel.self, from: data) {
                return existing
            }
            throw error
        }
    }

    private static func channelName(_ environment: APNsEnvironment) -> String {
        "channel-\(environment.rawValue)"
    }

    private func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    /// Last writer wins: each record has one writer, except the channel, where the newest view of what
    /// was pushed is the right one to keep.
    private func save(name: String, payload: Data) async throws {
        let record = CKRecord(recordType: Self.recordType, recordID: recordID(name))
        record[Field.payload] = payload as NSData
        record[Field.modifiedAt] = Date() as NSDate
        try await modify(record, policy: .allKeys)
    }

    private func modify(_ record: CKRecord, policy: CKModifyRecordsOperation.RecordSavePolicy) async throws {
        do {
            try await saveOnce(record, policy: policy)
        } catch let error as CKError where error.code == .zoneNotFound {
            // First CloudKit use from any device, or sync never ran: make the zone, then retry.
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            try await saveOnce(record, policy: policy)
        }
    }

    private func saveOnce(_ record: CKRecord, policy: CKModifyRecordsOperation.RecordSavePolicy) async throws {
        let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: policy, atomically: false)
        if case .failure(let error) = result.saveResults[record.recordID] {
            throw error
        }
    }
}
