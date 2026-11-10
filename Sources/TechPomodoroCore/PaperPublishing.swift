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
        public struct Payload: Codable, Equatable, Sendable {
            public var `class`: String
            public var kind: String
            public var note: String
            public var record_id: String
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
                record_id: sitting.id.uuidString
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(awEvents(sittings))
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
        /// `Read`, `Write`, `Practice`, `Watch`.
        public var kind: String
        /// `HH:mm`, local.
        public var start: String
        public var end: String
        public var minutes: Int
        public var note: String
        /// `[[startISO, endISO], …]`.
        public var spans: [[String]]
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
                    spans: s.spans.map { [iso.string(from: $0.start), iso.string(from: $0.end)] }
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
            for span in s.spans {
                hasher.combine(span.start)
                hasher.combine(span.end)
            }
        }
        return hasher.finalize()
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
