import Foundation

/// Serialises the interval history for export. Pure functions over the records, with no persistence
/// of their own: the shell decides where the returned bytes go.
public enum AnalyticsExporter {

    public static let csvHeader = "id,kind,started_at,elapsed_seconds,completed,focus_area,focus_task,focus_share,focus_switches,focus_distraction_seconds,focus_drift_alerts"

    public static func csv(records: [IntervalRecord]) -> String {
        let formatter = ISO8601DateFormatter()
        let rows = records.map { record in
            [
                record.id.uuidString,
                record.kind.rawValue,
                formatter.string(from: record.startedAt),
                String(record.elapsedSeconds),
                record.completed ? "true" : "false",
                field(record.focus?.anchorArea),
                field(record.focus?.anchorTask),
                record.focus?.focusShare.map { String(format: "%.3f", $0) } ?? "",
                record.focus.map { String($0.switches) } ?? "",
                record.focus.map { String($0.distractionSeconds) } ?? "",
                record.focus.map { String($0.driftAlerts) } ?? ""
            ].joined(separator: ",")
        }
        return ([csvHeader] + rows).joined(separator: "\n") + "\n"
    }

    /// Folder names can hold commas and quotes, so text fields are quoted per RFC 4180.
    static func field(_ value: String?) -> String {
        guard let value else { return "" }
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func json(records: [IntervalRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(records)
    }

    /// The inverse of `json(records:)`, so the export can be proven lossless by a roundtrip test.
    public static func records(fromJSON data: Data) throws -> [IntervalRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([IntervalRecord].self, from: data)
    }
}
