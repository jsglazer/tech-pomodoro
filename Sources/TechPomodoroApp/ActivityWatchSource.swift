import Foundation
import TechPomodoroCore

/// Reads the window, AFK and Obsidian buckets from a local aw-server. Only HTTP lives here; turning
/// the JSON into spans is `ActivityWatchParser`'s job, so the wire format stays under test.
@MainActor
final class ActivityWatchSource {

    enum SourceError: LocalizedError {
        case badURL
        case notLoopback
        case noWindowBucket

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid server URL"
            case .notLoopback: return "The server URL must be on this Mac (localhost or 127.0.0.1)"
            case .noWindowBucket: return "No aw-watcher-window bucket"
            }
        }
    }

    private struct Buckets {
        let window: String
        let afk: String?
        let notes: String?
        let documents: String?
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

    /// What the polls of one Work interval have read so far.
    private struct Cache {
        let server: String
        let intervalStart: Date
        /// The `end` of the previous request.
        var until: Date
        var activity: FocusActivity
    }

    private var cache: Cache?

    /// Everything from `start` (and the note/document lookback before it) to `end`. The first poll of
    /// an interval reads it all; later polls read only from just before the previous poll's end and
    /// fold the result in (`IncrementalSpans`).
    func fetch(server: String, from start: Date, to end: Date) async throws -> FocusActivity {
        do {
            let buckets = try await resolveBuckets(server: server)
            let previous = (cache?.server == server && cache?.intervalStart == start) ? cache : nil
            // A little past `end`, so the event still being extended is included.
            let until = end.addingTimeInterval(60)
            let windowFrom = IncrementalSpans.fetchStart(earliest: start, lastFetchedUntil: previous?.until)
            let lookbackFrom = IncrementalSpans.fetchStart(earliest: start.addingTimeInterval(-Self.noteLookback), lastFetchedUntil: previous?.until)
            var activity = previous?.activity ?? FocusActivity()

            activity.windows = IncrementalSpans.merge(
                cached: activity.windows,
                fresh: try ActivityWatchParser.windows(try await events(server, buckets.window, windowFrom, until)),
                from: windowFrom
            )
            if let bucket = buckets.notes {
                activity.notes = IncrementalSpans.merge(
                    cached: activity.notes,
                    fresh: try ActivityWatchParser.notes(try await events(server, bucket, lookbackFrom, until)),
                    from: lookbackFrom
                )
            }
            if let bucket = buckets.afk {
                activity.away = IncrementalSpans.merge(
                    cached: activity.away,
                    fresh: try ActivityWatchParser.away(try await events(server, bucket, windowFrom, until)),
                    from: windowFrom
                )
            }
            if let bucket = buckets.documents {
                // Merged events can start well before the interval, like notes.
                activity.documents = IncrementalSpans.merge(
                    cached: activity.documents,
                    fresh: try ActivityWatchParser.documents(try await events(server, bucket, lookbackFrom, until)),
                    from: lookbackFrom
                )
            }
            cache = Cache(server: server, intervalStart: start, until: until, activity: activity)
            return activity
        } catch {
            // A deleted or recreated bucket must be found again on the next poll, and read in full.
            buckets = nil
            cache = nil
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
            notes: ids.first { $0.hasPrefix("aw-watcher-obsidian_") },
            // This Mac's own sensor bucket (synced copies from other Macs carry a `-synced-from` suffix).
            documents: ids.first { $0.hasPrefix(DocumentHeartbeat.bucketPrefix) && !$0.contains("-synced-from") }
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
        // Only an aw-server on this Mac is ever read, as only one is ever written to.
        guard LoopbackURL.isLoopback(base) else { throw SourceError.notLoopback }
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
