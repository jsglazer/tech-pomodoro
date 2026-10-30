import Foundation
import TechPomodoroCore

/// Reads the window, AFK and Obsidian buckets from a local aw-server. Only HTTP lives here; turning
/// the JSON into spans is `ActivityWatchParser`'s job, so the wire format stays under test.
@MainActor
final class ActivityWatchSource {

    enum SourceError: LocalizedError {
        case badURL
        case noWindowBucket

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid server URL"
            case .noWindowBucket: return "No aw-watcher-window bucket"
            }
        }
    }

    private struct Buckets {
        let window: String
        let afk: String?
        let notes: String?
    }

    /// How far before the interval to look for the note that was already open when it began.
    static let noteLookback: TimeInterval = 2 * 3600

    private var buckets: Buckets?
    private var cachedServer: String?

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        return URLSession(configuration: config)
    }()

    func fetch(server: String, from start: Date, to end: Date) async throws -> FocusActivity {
        do {
            let buckets = try await resolveBuckets(server: server)
            // A little past `end`, so the event still being extended is included.
            let until = end.addingTimeInterval(60)
            let windows = try ActivityWatchParser.windows(try await events(server, buckets.window, start, until))
            var notes: [NoteSpan] = []
            if let bucket = buckets.notes {
                notes = try ActivityWatchParser.notes(
                    try await events(server, bucket, start.addingTimeInterval(-Self.noteLookback), until)
                )
            }
            var away: [AwaySpan] = []
            if let bucket = buckets.afk {
                away = try ActivityWatchParser.away(try await events(server, bucket, start, until))
            }
            return FocusActivity(windows: windows, notes: notes, away: away)
        } catch {
            // A deleted or recreated bucket must be found again on the next poll.
            buckets = nil
            throw error
        }
    }

    private func resolveBuckets(server: String) async throws -> Buckets {
        if let buckets, cachedServer == server { return buckets }
        let ids = try ActivityWatchParser.bucketIDs(try await get(server, "buckets/", []))
        // Newest-updated first, so a stale bucket from a renamed host loses to the live one.
        guard let window = ids.first(where: { $0.hasPrefix("aw-watcher-window") }) else {
            throw SourceError.noWindowBucket
        }
        let resolved = Buckets(
            window: window,
            afk: ids.first { $0.hasPrefix("aw-watcher-afk") },
            notes: ids.first { $0.hasPrefix("aw-watcher-obsidian_") }
        )
        buckets = resolved
        cachedServer = server
        return resolved
    }

    private func events(_ server: String, _ bucket: String, _ start: Date, _ end: Date) async throws -> Data {
        let formatter = ISO8601DateFormatter()
        return try await get(server, "buckets/\(bucket)/events", [
            URLQueryItem(name: "start", value: formatter.string(from: start)),
            URLQueryItem(name: "end", value: formatter.string(from: end)),
            URLQueryItem(name: "limit", value: "5000")
        ])
    }

    private func get(_ server: String, _ path: String, _ query: [URLQueryItem]) async throws -> Data {
        let base = server.hasSuffix("/") ? String(server.dropLast()) : server
        guard var components = URLComponents(string: "\(base)/api/0/\(path)") else { throw SourceError.badURL }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw SourceError.badURL }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
