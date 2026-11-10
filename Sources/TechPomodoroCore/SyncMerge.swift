import Foundation

/// The rules for combining this device's data with another device's, independent of how the bytes
/// travel. The CloudKit shell only moves records; every decision about who wins lives here, so it is
/// tested headlessly like the reducer.
///
/// - History is append-only and every record carries a UUID, so merging is a union by id — no record
///   is ever overwritten, and the same record arriving twice is harmless.
/// - Settings are one value, resolved last-writer-wins on the instant the user last changed them,
///   except for the fields that describe the device rather than the user (`deviceLocal`).
public enum SyncMerge {

    /// The union of both histories by record id, oldest first, pruned to the retention window.
    /// When both sides hold the same id, the local copy is kept: records are immutable once written,
    /// so the two copies are the same record.
    public static func mergeHistory(
        local: [IntervalRecord],
        remote: [IntervalRecord],
        now: Date,
        calendar: Calendar,
        retentionDays: Int = 30
    ) -> [IntervalRecord] {
        var seen = Set(local.map(\.id))
        var merged = local
        for record in remote where !seen.contains(record.id) {
            seen.insert(record.id)
            merged.append(record)
        }
        merged.sort { lhs, rhs in
            lhs.startedAt == rhs.startedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.startedAt < rhs.startedAt
        }
        return AnalyticsAggregator.prune(merged, now: now, calendar: calendar, retentionDays: retentionDays)
    }

    /// Which side of a settings conflict wins.
    public enum SettingsWinner: Equatable, Sendable {
        case local
        case remote
    }

    /// Last-writer-wins on `modifiedAt`. A tie goes to the remote copy, so a device whose settings
    /// were never touched (`modifiedAt == .distantPast`) adopts whatever the other devices already
    /// agreed on instead of pushing its defaults over them.
    public static func settingsWinner(localModifiedAt: Date, remoteModifiedAt: Date) -> SettingsWinner {
        localModifiedAt > remoteModifiedAt ? .local : .remote
    }

    /// `remote`'s settings with this device's own fields kept from `local`.
    public static func adopt(remote: PomodoroSettings, keepingDeviceFieldsOf local: PomodoroSettings) -> PomodoroSettings {
        var merged = remote
        merged.soundName = local.soundName
        merged.launchAtLogin = local.launchAtLogin
        merged.cloudSyncEnabled = local.cloudSyncEnabled
        merged.mirrorEnabled = local.mirrorEnabled
        merged.focus.enabled = local.focus.enabled
        merged.focus.serverURL = local.focus.serverURL
        merged.focus.documents.enabled = local.focus.documents.enabled
        merged.paperPublishEnabled = local.paperPublishEnabled
        merged.paperLogPath = local.paperLogPath
        return merged
    }

    /// True when the two settings differ in anything that syncs — a change only to a device-local
    /// field must not be pushed to the other devices, nor bump the shared modification time.
    public static func syncedFieldsDiffer(_ a: PomodoroSettings, _ b: PomodoroSettings) -> Bool {
        adopt(remote: a, keepingDeviceFieldsOf: b) != b
    }
}

/// Settings as they travel between devices: the value plus the instant the user last changed it.
public struct SyncedSettings: Codable, Sendable, Equatable {
    public var settings: PomodoroSettings
    public var modifiedAt: Date

    public init(settings: PomodoroSettings, modifiedAt: Date) {
        self.settings = settings
        self.modifiedAt = modifiedAt
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SyncedSettings {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SyncedSettings.self, from: data)
    }
}

extension IntervalRecord {
    /// The record as it travels between devices. ISO-8601 dates, like the history file, so a record
    /// written by an older build still decodes (missing optional fields stay nil).
    public func syncPayload() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func fromSyncPayload(_ data: Data) throws -> IntervalRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(IntervalRecord.self, from: data)
    }
}
