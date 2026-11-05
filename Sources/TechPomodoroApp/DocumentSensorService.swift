import AppKit
import Darwin
import Foundation
import TechPomodoroCore

/// Lists the files a process (and its descendants) has open, through `libproc` — the same data
/// `lsof` shows, without a shell-out and without any permission prompt. Only processes of the same
/// user are readable, which is all the sensor needs.
enum OpenFiles {

    /// Every open vnode path of `pid` and of every process descended from it.
    static func paths(rootPID: pid_t) -> [String] {
        let pids = ProcessTree.descendants(of: rootPID, parents: parentTable())
        return pids.flatMap(paths(of:))
    }

    /// pid → parent pid for every process on the system.
    static func parentTable() -> [Int32: Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard filled > 0 else { return [:] }
        var table: [Int32: Int32] = [:]
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
                table[pid] = Int32(info.pbi_ppid)
            }
        }
        return table
    }

    static func paths(of pid: pid_t) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard filled > 0 else { return [] }
        var out: [String] = []
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !path.isEmpty { out.append(path) }
        }
        return out
    }
}

/// The real world for `DocumentSensorEngine`: the front app via `NSWorkspace`, its files via
/// `OpenFiles`, and aw-server over loopback HTTP.
struct LiveDocumentSensorPort: DocumentSensorPort {

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        return URLSession(configuration: config)
    }()

    func read(settings: DocumentSensorSettings) async -> DocumentReading? {
        let front = await MainActor.run { () -> (pid_t, String?, String?)? in
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return (app.processIdentifier, app.bundleIdentifier, app.localizedName)
        }
        guard let (pid, bundleID, name) = front, let watched = settings.app(bundleID: bundleID) else { return nil }
        // libproc walks every process: keep it off the main thread.
        let paths = await Task.detached(priority: .utility) {
            DocumentPaths.documents(in: OpenFiles.paths(rootPID: pid), extensions: watched.extensions)
        }.value
        return DocumentReading(app: name ?? watched.name, bundleID: watched.bundleID, paths: paths)
    }

    func prepareBucket(server: String) async throws -> String {
        struct Info: Decodable { let hostname: String }
        let info = try JSONDecoder().decode(Info.self, from: try await request(server, "info", method: "GET"))
        let bucket = DocumentHeartbeat.bucketID(hostname: info.hostname)
        let body = try JSONSerialization.data(withJSONObject: [
            "client": DocumentHeartbeat.client, "type": DocumentHeartbeat.bucketType, "hostname": info.hostname
        ])
        // 200 = created, 304 = already there; both are fine.
        _ = try await request(server, "buckets/\(bucket)", method: "POST", body: body, accept: [304])
        return bucket
    }

    func sendHeartbeat(server: String, bucket: String, pulsetime: Int, event: Data) async throws {
        _ = try await request(server, "buckets/\(bucket)/heartbeat?pulsetime=\(pulsetime)", method: "POST", body: event)
    }

    private func request(_ server: String, _ path: String, method: String, body: Data? = nil, accept: Set<Int> = []) async throws -> Data {
        let base = server.hasSuffix("/") ? String(server.dropLast()) : server
        guard LoopbackURL.isLoopback(base), let url = URL(string: "\(base)/api/0/\(path)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await Self.session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode), !accept.contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// Drives the engine on its own timer, from launch to quit. Deliberately independent of the
/// Pomodoro timer: it samples while the timer is idle, paused, in Work or in Rest alike.
@MainActor
final class DocumentSensorService {

    private let engine = DocumentSensorEngine(port: LiveDocumentSensorPort())
    private var loop: Task<Void, Never>?
    private let settings: () -> FocusSettings
    private let onStatus: (DocumentSensorEngine.Status) -> Void

    init(settings: @escaping () -> FocusSettings, onStatus: @escaping (DocumentSensorEngine.Status) -> Void) {
        self.settings = settings
        self.onStatus = onStatus
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let focus = self.settings()
                await self.engine.tick(settings: focus.documents, server: focus.serverURL, now: Date())
                self.onStatus(await self.engine.status)
                try? await Task.sleep(for: .seconds(focus.documents.intervalSeconds))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Samples right away, e.g. after a settings change.
    func sampleNow() {
        let focus = settings()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.engine.tick(settings: focus.documents, server: focus.serverURL, now: Date())
            self.onStatus(await self.engine.status)
        }
    }
}
