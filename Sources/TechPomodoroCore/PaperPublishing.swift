import Foundation

/// What the publishing Mac writes out: the ActivityWatch events and the vault file. Pure functions of
/// the paper sittings, so both formats are pinned by tests; the shell only moves the bytes.
public enum PaperPublishing {

    /// The ActivityWatch event type of the paper bucket.
    public static let eventType = "app.paper.sitting"

    /// `aw-watcher-paper_MBA24`.
    public static func bucketID(hostname: String) -> String {
        "aw-watcher-paper_\(hostname)"
    }

    /// One ActivityWatch event per span of every sitting.
    public struct AWEvent: Codable, Equatable, Sendable {
        public struct Payload: Codable, Equatable, Hashable, Sendable {
            public var `class`: String
            public var kind: String
            public var note: String
            public var record_id: String
            /// `app` (a paper sitting) or `calendar` (a class meeting).
            public var source: String
        }
        public var timestamp: String
        public var duration: Double
        public var data: Payload
    }

    public static func awEvents(_ sittings: [PaperSittingView]) -> [AWEvent] {
        let iso = isoFormatter()
        var events: [(start: Date, event: AWEvent)] = []
        for sitting in sittings {
            let payload = AWEvent.Payload(
                class: sitting.className,
                kind: sitting.kind.title,
                note: sitting.note ?? "",
                record_id: sitting.id.uuidString,
                source: source(sitting)
            )
            for span in sitting.spans {
                let event = AWEvent(timestamp: iso.string(from: span.start), duration: span.duration, data: payload)
                events.append((span.start, event))
            }
        }
        events.sort { lhs, rhs in
            lhs.start == rhs.start ? lhs.event.data.record_id < rhs.event.data.record_id : lhs.start < rhs.start
        }
        return events.map(\.event)
    }

    public static func awEventsJSON(_ sittings: [PaperSittingView]) throws -> Data {
        try encodeEvents(awEvents(sittings))
    }

    public static func encodeEvents(_ events: [AWEvent]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(events)
    }

    // MARK: - Bucket diff

    /// An event as aw-server holds it, with the id it can be deleted by. `event` is nil for one that
    /// is not a paper sitting at all: the bucket is the app's own, so such an event is deleted.
    public struct StoredAWEvent: Equatable, Sendable {
        public var id: Int
        public var event: AWEvent?

        public init(id: Int, event: AWEvent?) {
            self.id = id
            self.event = event
        }
    }

    /// `GET buckets/<id>/events`. An event without an id cannot be touched and is skipped; one whose
    /// payload is not a paper sitting is kept with a nil `event`, to be deleted.
    public static func storedEvents(_ data: Data) throws -> [StoredAWEvent] {
        struct Raw: Decodable {
            let id: Int?
            let event: AWEvent?

            enum CodingKeys: String, CodingKey { case id, timestamp, duration, data }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try? c.decode(Int.self, forKey: .id)
                if let timestamp = try? c.decode(String.self, forKey: .timestamp),
                   let duration = try? c.decode(Double.self, forKey: .duration),
                   let payload = try? c.decode(AWEvent.Payload.self, forKey: .data) {
                    event = AWEvent(timestamp: timestamp, duration: duration, data: payload)
                } else {
                    event = nil
                }
            }
        }
        return try JSONDecoder().decode([Raw].self, from: data).compactMap { raw in
            raw.id.map { StoredAWEvent(id: $0, event: raw.event) }
        }
    }

    /// What to post and what to delete so the bucket holds exactly `desired`, touching nothing that
    /// is already right. Replaces delete-the-bucket-and-rebuild, which left aw-server with an empty
    /// paper bucket if publishing failed half way. Events match on start instant (aw-server rewrites
    /// the timestamp's format, and keeps microseconds), duration to the millisecond, and payload;
    /// duplicates match one for one.
    public static func bucketDiff(stored: [StoredAWEvent], desired: [AWEvent]) -> (add: [AWEvent], deleteIDs: [Int]) {
        var unmatched: [EventKey: [Int]] = [:]
        var foreign: [Int] = []
        for item in stored {
            if let event = item.event {
                unmatched[EventKey(event), default: []].append(item.id)
            } else {
                foreign.append(item.id)
            }
        }
        var add: [AWEvent] = []
        for event in desired {
            let key = EventKey(event)
            if var ids = unmatched[key], !ids.isEmpty {
                ids.removeFirst()
                unmatched[key] = ids
            } else {
                add.append(event)
            }
        }
        return (add, (unmatched.values.flatMap { $0 } + foreign).sorted())
    }

    private struct EventKey: Hashable {
        let startMillis: Int64?
        let timestamp: String?
        let durationMillis: Int64
        let data: AWEvent.Payload

        init(_ event: AWEvent) {
            if let date = ActivityWatchParser.date(event.timestamp) {
                startMillis = Int64((date.timeIntervalSince1970 * 1000).rounded())
                timestamp = nil
            } else {
                startMillis = nil
                timestamp = event.timestamp
            }
            durationMillis = Int64((event.duration * 1000).rounded())
            data = event.data
        }
    }

    // MARK: - Vault file

    public struct VaultFile: Codable, Equatable, Sendable {
        public var version: Int
        public var generated: String
        public var sittings: [VaultSitting]
    }

    public struct VaultSitting: Codable, Equatable, Sendable {
        public var id: String
        /// `yyyy-MM-dd`, local.
        public var date: String
        public var `class`: String
        /// `Read`, `Write`, `Practice`, `Watch`, `Class`.
        public var kind: String
        /// `HH:mm`, local.
        public var start: String
        public var end: String
        public var minutes: Int
        public var note: String
        /// `[[startISO, endISO], …]`.
        public var spans: [[String]]
        /// `app` (a paper sitting) or `calendar` (a class meeting). Added in 1.0.30; the format
        /// stays version 1 because the field is only added.
        public var source: String
    }

    public static func vaultFile(_ sittings: [PaperSittingView], generated: Date, calendar: Calendar) -> VaultFile {
        let iso = isoFormatter()
        let day = formatter("yyyy-MM-dd", calendar: calendar)
        let time = formatter("HH:mm", calendar: calendar)
        let rows = sittings
            .sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
            .map { s in
                VaultSitting(
                    id: s.id.uuidString,
                    date: day.string(from: s.start),
                    class: s.className,
                    kind: s.kind.title,
                    start: time.string(from: s.start),
                    end: time.string(from: s.end),
                    minutes: Int((Double(s.seconds) / 60).rounded()),
                    note: s.note ?? "",
                    spans: s.spans.map { [iso.string(from: $0.start), iso.string(from: $0.end)] },
                    source: source(s)
                )
            }
        return VaultFile(version: 1, generated: iso.string(from: generated), sittings: rows)
    }

    public static func vaultJSON(_ sittings: [PaperSittingView], generated: Date, calendar: Calendar) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(vaultFile(sittings, generated: generated, calendar: calendar))
    }

    /// A content key for the published set, so an unchanged history is not rewritten.
    public static func fingerprint(_ sittings: [PaperSittingView]) -> Int {
        var hasher = Hasher()
        for s in sittings {
            hasher.combine(s.id)
            hasher.combine(s.className)
            hasher.combine(s.kind)
            hasher.combine(s.note)
            hasher.combine(s.seconds)
            hasher.combine(s.fromCalendar)
            for span in s.spans {
                hasher.combine(span.start)
                hasher.combine(span.end)
            }
        }
        return hasher.finalize()
    }

    /// `calendar` for a class meeting, `app` otherwise.
    public static func source(_ sitting: PaperSittingView) -> String {
        sitting.fromCalendar ? "calendar" : "app"
    }

    static func isoFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = format
        return f
    }
}
