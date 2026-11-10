import Foundation
import TechPomodoroCore

/// Publishes the paper sittings from the one Mac whose "Publish paper time" switch is on: an
/// ActivityWatch bucket rebuilt from the history, and one app-owned JSON file in the vault, rewritten
/// whole and atomically. Debounced to at most one write a minute, and once at launch. Nothing else in
/// the vault is ever written.
@MainActor
final class PaperPublisher: ObservableObject {

    struct Status: Equatable {
        var enabled = false
        var lastWrite: Date?
        var sittingsWritten = 0
        var lastError: String?
    }

    @Published private(set) var status = Status()

    /// Minimum seconds between two publishes.
    static let debounce: TimeInterval = 60

    private struct Request {
        let sittings: [PaperSittingView]
        let server: String
        let path: String
        let calendar: Calendar
    }

    private var latest: Request?
    private var scheduled: Task<Void, Never>?
    private var lastAttempt: Date = .distantPast
    private var awPublished: Int?
    private var vaultPublished: (path: String, fingerprint: Int)?
    private var backoff = SensorBackoff()

    /// Hands over the current sittings. Publishes now if a minute has passed since the last write,
    /// else once the minute is up.
    func update(sittings: [PaperSittingView], settings: PomodoroSettings, calendar: Calendar) {
        guard settings.paperPublishEnabled else {
            scheduled?.cancel()
            scheduled = nil
            latest = nil
            awPublished = nil
            vaultPublished = nil
            status = Status()
            return
        }
        status.enabled = true
        latest = Request(sittings: sittings, server: settings.focus.serverURL, path: settings.paperLogPath, calendar: calendar)
        schedule()
    }

    private func schedule() {
        guard scheduled == nil else { return }
        let now = Date()
        let due = max(lastAttempt.addingTimeInterval(Self.debounce), backoff.retryAt)
        let delay = max(0, due.timeIntervalSince(now))
        scheduled = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, !Task.isCancelled else { return }
            self.scheduled = nil
            await self.publish()
        }
    }

    private func publish() async {
        guard let request = latest else { return }
        lastAttempt = Date()
        let fingerprint = PaperPublishing.fingerprint(request.sittings)
        var errors: [String] = []
        var wrote = false

        if !(vaultPublished?.path == request.path && vaultPublished?.fingerprint == fingerprint) {
            do {
                try writeVaultFile(request)
                vaultPublished = (request.path, fingerprint)
                wrote = true
            } catch {
                errors.append("Vault file: \(error.localizedDescription)")
            }
        }

        if awPublished != fingerprint {
            do {
                try await writeBucket(request)
                awPublished = fingerprint
                backoff.succeeded()
                wrote = true
            } catch {
                backoff.failed(at: Date())
                errors.append("ActivityWatch: \(error.localizedDescription)")
            }
        }

        if wrote {
            status.lastWrite = Date()
            status.sittingsWritten = request.sittings.count
        }
        status.lastError = errors.isEmpty ? nil : errors.joined(separator: " · ")
        // Anything that failed is tried again on the debounce (or the ActivityWatch backoff).
        if !errors.isEmpty { schedule() }
    }

    /// The whole file, written to a temporary file beside it and renamed over it. The folder must
    /// already exist: the app creates nothing else in the vault.
    private func writeVaultFile(_ request: Request) throws {
        let url = URL(fileURLWithPath: (request.path as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.deletingLastPathComponent().path])
        }
        let data = try PaperPublishing.vaultJSON(request.sittings, generated: Date(), calendar: request.calendar)
        try data.write(to: url, options: .atomic)
    }

    /// Deletes and recreates the bucket, then posts every span as an event.
    private func writeBucket(_ request: Request) async throws {
        let host = try await ActivityWatchHTTP.hostname(server: request.server)
        let bucket = PaperPublishing.bucketID(hostname: host)
        let path = bucket.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? bucket
        // 404: there was no bucket yet.
        _ = try await ActivityWatchHTTP.request(request.server, "buckets/\(path)?force=1", method: "DELETE", accept: [404])
        let create = try JSONSerialization.data(withJSONObject: [
            "client": DocumentHeartbeat.client, "type": PaperPublishing.eventType, "hostname": host
        ])
        _ = try await ActivityWatchHTTP.request(request.server, "buckets/\(path)", method: "POST", body: create, accept: [304])
        let events = try PaperPublishing.awEventsJSON(request.sittings)
        if !request.sittings.isEmpty {
            _ = try await ActivityWatchHTTP.request(request.server, "buckets/\(path)/events", method: "POST", body: events)
        }
    }
}
