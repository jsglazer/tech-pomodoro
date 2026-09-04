import Foundation

/// Where the interval history lives. Injected everywhere, so tests never touch the real history file.
public protocol IntervalStore: Sendable {
    func load() throws -> [IntervalRecord]
    func replace(with records: [IntervalRecord]) throws
    /// Appends and returns the pruned history that was actually written.
    @discardableResult
    func append(_ records: [IntervalRecord], now: Date, calendar: Calendar) throws -> [IntervalRecord]
}

extension IntervalStore {
    @discardableResult
    public func append(_ records: [IntervalRecord], now: Date, calendar: Calendar = .current) throws -> [IntervalRecord] {
        try append(records, now: now, calendar: calendar)
    }
}

/// An append-only JSON document at an injected URL, written atomically.
///
/// The URL is a parameter, never a constant: the app passes its Application Support path, tests pass
/// a temporary directory.
public struct FileIntervalStore: IntervalStore {
    public let url: URL
    public let retentionDays: Int

    public init(url: URL, retentionDays: Int = 30) {
        self.url = url
        self.retentionDays = retentionDays
    }

    /// `~/Library/Application Support/tech-pomodoro/intervals.json` for the running app. Resolved
    /// through `FileManager`, so it is still not a hardcoded path string.
    public static func applicationSupportURL(
        fileManager: FileManager = .default,
        folderName: String = "tech-pomodoro"
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("intervals.json", isDirectory: false)
    }

    public func load() throws -> [IntervalRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }
        return try Self.decoder.decode([IntervalRecord].self, from: data)
    }

    public func replace(with records: [IntervalRecord]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(records)
        // Atomic, so a crash mid-write cannot leave a truncated history behind.
        try data.write(to: url, options: .atomic)
    }

    @discardableResult
    public func append(_ records: [IntervalRecord], now: Date, calendar: Calendar) throws -> [IntervalRecord] {
        guard !records.isEmpty else { return try load() }
        let combined = try load() + records
        let pruned = AnalyticsAggregator.prune(
            combined,
            now: now,
            calendar: calendar,
            retentionDays: retentionDays
        )
        try replace(with: pruned)
        return pruned
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// An in-memory store for tests and previews.
public final class MemoryIntervalStore: IntervalStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [IntervalRecord]
    public let retentionDays: Int

    public init(records: [IntervalRecord] = [], retentionDays: Int = 30) {
        self.records = records
        self.retentionDays = retentionDays
    }

    public func load() throws -> [IntervalRecord] {
        lock.withLock { records }
    }

    public func replace(with newRecords: [IntervalRecord]) throws {
        lock.withLock { records = newRecords }
    }

    @discardableResult
    public func append(_ newRecords: [IntervalRecord], now: Date, calendar: Calendar) throws -> [IntervalRecord] {
        lock.withLock {
            records = AnalyticsAggregator.prune(
                records + newRecords,
                now: now,
                calendar: calendar,
                retentionDays: retentionDays
            )
            return records
        }
    }
}
