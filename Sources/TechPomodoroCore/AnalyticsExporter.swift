import Foundation

/// Serialises the interval history for export. Pure functions over the records, with no persistence
/// of their own: the shell decides where the returned bytes go.
public enum AnalyticsExporter {

    public static let csvHeader = "id,kind,started_at,elapsed_seconds,completed,focus_area,focus_task,focus_share,focus_switches,focus_distraction_seconds,focus_drift_alerts,paper_class,paper_kind,paper_note,paper_seconds,paper_overlap_seconds,manual"

    public static func csv(records: [IntervalRecord]) -> String {
        let formatter = ISO8601DateFormatter()
        let rows: [String] = records.map { record -> String in
            csvRow(record, formatter: formatter)
        }
        return ([csvHeader] + rows).joined(separator: "\n") + "\n"
    }

    /// One CSV line per record. Built as three typed groups rather than one array literal: a single
    /// 17-element literal mixing optional chains and `??` was too much for the Swift type checker
    /// on the CI runner ("unable to type-check this expression in reasonable time").
    static func csvRow(_ record: IntervalRecord, formatter: ISO8601DateFormatter) -> String {
        let base: [String] = [
            record.id.uuidString,
            record.kind.rawValue,
            formatter.string(from: record.startedAt),
            String(record.elapsedSeconds),
            record.completed ? "true" : "false"
        ]
        return (base + focusColumns(record.focus) + paperColumns(record)).joined(separator: ",")
    }

    static func focusColumns(_ focus: FocusSummary?) -> [String] {
        guard let focus else { return ["", "", "", "", "", ""] }
        let share: String = focus.focusShare.map { String(format: "%.3f", $0) } ?? ""
        return [
            field(focus.anchorArea),
            field(focus.anchorTask),
            share,
            String(focus.switches),
            String(focus.distractionSeconds),
            String(focus.driftAlerts)
        ]
    }

    static func paperColumns(_ record: IntervalRecord) -> [String] {
        let paper = record.paper
        let seconds: String = paper.map { String(Int($0.seconds.rounded())) } ?? ""
        let overlap: String = record.focus?.paperOverlapSeconds.map { String($0) } ?? ""
        return [
            field(paper?.className),
            paper?.kind.title ?? "",
            field(paper?.note),
            seconds,
            overlap,
            record.isManual ? "true" : ""
        ]
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
