import Foundation

// MARK: - Settings

/// An app whose open documents the sensor reports, matched by bundle identifier.
public struct WatchedApp: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// Display name, also what aw-watcher-window calls the app (`PDF Expert`, `Microsoft Word`).
    public var name: String
    public var bundleID: String
    /// Lower-case extensions without the dot: `pdf`, `docx`, `pages`.
    public var extensions: [String]

    public var id: String { bundleID }

    /// True for a file manager whose current folder is reported instead of its open files (ForkLift).
    public var reportsFolder: Bool { FolderPaths.isFolderApp(bundleID: bundleID) }

    public init(name: String, bundleID: String, extensions: [String]) {
        self.name = name
        self.bundleID = bundleID
        self.extensions = extensions
    }
}

/// The document sensor's configuration, nested in `FocusSettings`. `enabled` is this device's own
/// switch (never synced); the interval and the app list sync with the other settings.
public struct DocumentSensorSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Seconds between samples, `5...120`.
    public var intervalSeconds: Int
    public var apps: [WatchedApp]

    public static let intervalRange = 5...120

    /// The first-run list. RStudio is experimental: its documents live in the `rsession` child
    /// process, which is why descendants are scanned too.
    public static let defaultApps: [WatchedApp] = [
        WatchedApp(name: "PDF Expert", bundleID: "com.readdle.PDFExpert-Mac", extensions: ["pdf"]),
        WatchedApp(name: "Preview", bundleID: "com.apple.Preview", extensions: ["pdf"]),
        WatchedApp(name: "Skim", bundleID: "net.sourceforge.skim-app.skim", extensions: ["pdf"]),
        WatchedApp(name: "Microsoft Word", bundleID: "com.microsoft.Word", extensions: ["doc", "docx"]),
        WatchedApp(name: "Microsoft Excel", bundleID: "com.microsoft.Excel", extensions: ["xls", "xlsx", "csv"]),
        WatchedApp(name: "Pages", bundleID: "com.apple.Pages", extensions: ["pages"]),
        WatchedApp(name: "Numbers", bundleID: "com.apple.iWork.Numbers", extensions: ["numbers"]),
        WatchedApp(name: "RStudio", bundleID: "com.rstudio.desktop", extensions: ["r", "rmd", "qmd", "rproj", "csv"]),
        DocumentSensorSettings.forkLift
    ]

    /// ForkLift reports the folder in its active tab, not open files, so it has no extensions.
    public static let forkLift = WatchedApp(name: "ForkLift", bundleID: FolderPaths.forkLiftBundleID, extensions: [])

    public init(enabled: Bool = true, intervalSeconds: Int = 15, apps: [WatchedApp] = DocumentSensorSettings.defaultApps) {
        self.enabled = enabled
        self.intervalSeconds = min(Self.intervalRange.upperBound, max(Self.intervalRange.lowerBound, intervalSeconds))
        self.apps = apps
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DocumentSensorSettings()
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled,
            intervalSeconds: try c.decodeIfPresent(Int.self, forKey: .intervalSeconds) ?? d.intervalSeconds,
            apps: try c.decodeIfPresent([WatchedApp].self, forKey: .apps) ?? d.apps
        )
    }

    public func app(bundleID: String?) -> WatchedApp? {
        guard let bundleID else { return nil }
        return apps.first { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// True if aw-watcher-window's app name belongs to a watched app.
    public func watches(appName: String) -> Bool {
        apps.contains { $0.name.caseInsensitiveCompare(appName) == .orderedSame }
    }
}

// MARK: - Pure pieces

public enum DocumentPaths {

    /// The open-file paths that are documents of the given types, deduplicated and sorted.
    ///
    /// A file inside a package (`Report.pages/Index/Document.iwa`) is reported as the package
    /// (`Report.pages`): the path is cut after the first component carrying a watched extension.
    public static func documents(in paths: [String], extensions: [String]) -> [String] {
        let wanted = Set(extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) })
        guard !wanted.isEmpty else { return [] }
        var out = Set<String>()
        for path in paths where path.hasPrefix("/") {
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            for (i, component) in components.enumerated() {
                guard let dot = component.lastIndex(of: "."), dot != component.startIndex else { continue }
                let ext = component[component.index(after: dot)...].lowercased()
                if wanted.contains(ext) {
                    out.insert("/" + components.prefix(i + 1).joined(separator: "/"))
                    break
                }
            }
        }
        return out.sorted()
    }

    /// The file name without its extension: `/a/CH03.pdf` → `CH03`.
    public static func stem(_ path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }
}

/// File managers that report the folder they show rather than files they hold open.
public enum FolderPaths {

    public static let forkLiftBundleID = "com.binarynights.ForkLift"

    public static func isFolderApp(bundleID: String?) -> Bool {
        bundleID?.caseInsensitiveCompare(forkLiftBundleID) == .orderedSame
    }

    /// The AppleScript that asks ForkLift for its active tab's folder, as a URL.
    public static let forkLiftScript = #"""
        with timeout of 3 seconds
            tell application id "com.binarynights.ForkLift" to get displayedUrl of activeTab of front window
        end timeout
        """#

    /// The absolute folder path in a `file://` URL, always ending in `/`:
    /// `file:///a/RD%20-%20POGO%20801/` → `/a/RD - POGO 801/`. Nil for anything that isn't a local
    /// folder URL (sftp, smb, search results, an empty answer).
    public static func path(fromDisplayedURL text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.isFileURL else { return nil }
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix("/") else { return nil }
        return path.hasSuffix("/") ? path : path + "/"
    }
}

public enum ProcessTree {

    /// `root` and every process descended from it, given each process's parent.
    public static func descendants(of root: Int32, parents: [Int32: Int32]) -> Set<Int32> {
        var children: [Int32: [Int32]] = [:]
        for (pid, parent) in parents where pid != parent {
            children[parent, default: []].append(pid)
        }
        var out: Set<Int32> = [root]
        var queue = [root]
        while let pid = queue.popLast() {
            for child in children[pid] ?? [] where out.insert(child).inserted {
                queue.append(child)
            }
        }
        return out
    }
}

/// One sample of the front app's documents.
public struct DocumentReading: Sendable, Equatable {
    public let app: String
    public let bundleID: String
    public let paths: [String]

    public init(app: String, bundleID: String, paths: [String]) {
        self.app = app
        self.bundleID = bundleID
        self.paths = paths
    }
}

/// The ActivityWatch side of the sensor: bucket naming and the heartbeat payload.
public enum DocumentHeartbeat {
    public static let bucketPrefix = "aw-watcher-documents_"
    public static let bucketType = "app.documents.open"
    public static let client = "tech-pomodoro"

    public static func bucketID(hostname: String) -> String { bucketPrefix + hostname }

    public static func pulsetime(intervalSeconds: Int) -> Int { intervalSeconds + 15 }

    /// The heartbeat `data` object. `JSONEncoder` with sorted keys gives a fixed key order
    /// (`app`, `bundle_id`, `count`, `paths`) and nothing in it varies with time, so an unchanged
    /// reading encodes byte-identically and aw-server merges it into the running event.
    public static func data(for reading: DocumentReading) -> Data {
        let payload = Payload(app: reading.app, bundle_id: reading.bundleID, count: reading.paths.count, paths: reading.paths)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(payload)) ?? Data("{}".utf8)
    }

    /// A whole heartbeat event: `{"data":…,"duration":0,"timestamp":…}`.
    public static func event(for reading: DocumentReading, at date: Date) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out = Data("{\"data\":".utf8)
        out.append(data(for: reading))
        out.append(Data(",\"duration\":0,\"timestamp\":\"\(formatter.string(from: date))\"}".utf8))
        return out
    }

    private struct Payload: Encodable {
        let app: String
        let bundle_id: String
        let count: Int
        let paths: [String]
    }
}

/// Only an aw-server on this Mac is ever written to.
public enum LoopbackURL {
    public static func isLoopback(_ raw: String) -> Bool {
        guard let host = URLComponents(string: raw.trimmingCharacters(in: .whitespaces))?.host?.lowercased() else {
            return false
        }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }
}

/// Retry spacing while aw-server is unreachable: 15 s, doubling, capped at 5 min.
public struct SensorBackoff: Sendable, Equatable {
    public static let start: TimeInterval = 15
    public static let cap: TimeInterval = 300

    public private(set) var delay: TimeInterval = 0
    public private(set) var retryAt: Date = .distantPast

    public init() {}

    public func allowsAttempt(at now: Date) -> Bool { now >= retryAt }

    public mutating func failed(at now: Date) {
        delay = delay == 0 ? Self.start : min(delay * 2, Self.cap)
        retryAt = now.addingTimeInterval(delay)
    }

    public mutating func succeeded() {
        delay = 0
        retryAt = .distantPast
    }
}

// MARK: - Engine

/// What the engine needs from the outside world. The app supplies the real ones; tests supply fakes.
public protocol DocumentSensorPort: Sendable {
    /// The front app's documents, or nil when the front app is not watched or shows none.
    func read(settings: DocumentSensorSettings) async -> DocumentReading?
    /// Resolves the hostname and creates the bucket; returns the bucket id.
    func prepareBucket(server: String) async throws -> String
    func sendHeartbeat(server: String, bucket: String, pulsetime: Int, event: Data) async throws
}

/// One sample per `tick()`: read the front app's documents and send them as a heartbeat. It knows
/// nothing about the Pomodoro timer, so it samples the same whether the timer is idle, running,
/// paused, in Work or in Rest.
public actor DocumentSensorEngine {
    public enum Status: Sendable, Equatable {
        case off
        case waiting
        case sent(app: String, files: Int, at: Date)
        case error(String)
    }

    private let port: any DocumentSensorPort
    private var bucket: String?
    private var bucketServer: String?
    private var backoff = SensorBackoff()
    public private(set) var status: Status = .waiting
    public private(set) var heartbeatsSent = 0

    public init(port: any DocumentSensorPort) {
        self.port = port
    }

    public func tick(settings: DocumentSensorSettings, server: String, now: Date) async {
        guard settings.enabled else {
            status = .off
            return
        }
        guard LoopbackURL.isLoopback(server) else {
            status = .error("Server must be on this Mac (127.0.0.1 or localhost)")
            return
        }
        guard let reading = await port.read(settings: settings), !reading.paths.isEmpty else {
            if case .error = status {} else if case .sent = status {} else { status = .waiting }
            return
        }
        guard backoff.allowsAttempt(at: now) else { return }
        do {
            if bucket == nil || bucketServer != server {
                bucket = try await port.prepareBucket(server: server)
                bucketServer = server
            }
            try await port.sendHeartbeat(
                server: server,
                bucket: bucket ?? "",
                pulsetime: DocumentHeartbeat.pulsetime(intervalSeconds: settings.intervalSeconds),
                event: DocumentHeartbeat.event(for: reading, at: now)
            )
            backoff.succeeded()
            heartbeatsSent += 1
            status = .sent(app: reading.app, files: reading.paths.count, at: now)
        } catch {
            // The bucket may be gone or the server restarted: resolve it again next time.
            bucket = nil
            backoff.failed(at: now)
            status = .error(error.localizedDescription)
        }
    }

    public func currentBackoff() -> SensorBackoff { backoff }
}

// MARK: - Focus: documents

/// One span of the front app's open documents, read back from the documents bucket.
public struct DocumentSpan: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let app: String
    public let paths: [String]

    public init(start: Date, end: Date, app: String, paths: [String]) {
        self.start = start
        self.end = end
        self.app = app
        self.paths = paths
    }
}

extension FocusRules {

    /// The project of a document at an absolute path, by the same folder rules as notes, matched on
    /// the path from whichever folder an area rule starts at (`…/Dropbox/_Schar/Classes/2026-B/…` and
    /// the vault's `Classes/2026-B/…` land on the same project). Nil when no area rule matches.
    /// A folder (a path ending in `/`, as ForkLift reports it) counts as a file inside that folder, so a
    /// class folder itself matches the class: `.` stands in for the file name.
    public static func project(forDocument path: String, settings: FocusSettings) -> FocusProject? {
        var segments = path.split(separator: "/").map(String.init)
        if path.hasSuffix("/") { segments.append(".") }
        for i in segments.indices {
            let tail = Array(segments[i...])
            if firstMatch(settings.areaRules, tail) != nil {
                return project(forFile: tail.joined(separator: "/"), settings: settings)
            }
        }
        return nil
    }

    /// The document shown in `window`, from the documents reported for that app at that moment:
    /// the one whose file name the window title starts with, or the only one. A folder path's name is
    /// its last folder (`/a/Data/` → `Data`).
    public static func document(for window: WindowSpan, among paths: [String]) -> String? {
        guard !paths.isEmpty else { return nil }
        let title = window.title.lowercased()
        let named = paths.filter {
            let stem = DocumentPaths.stem($0).lowercased()
            return !stem.isEmpty && title.hasPrefix(stem)
        }
        // Longest stem first, so `Ch07 notes` beats `Ch07` for a window titled `Ch07 notes`.
        if let best = named.max(by: { DocumentPaths.stem($0).count < DocumentPaths.stem($1).count }) {
            return best
        }
        return paths.count == 1 ? paths[0] : nil
    }
}
