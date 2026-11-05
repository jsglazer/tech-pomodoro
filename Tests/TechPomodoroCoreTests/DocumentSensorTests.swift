import Foundation
import Testing
@testable import TechPomodoroCore

private let classPDF = "/Users/josh/Library/CloudStorage/Dropbox/_Schar/Classes/2026-B/Data - POGO 511/Chapters/CH03.pdf"
private let rdPDF = "/Users/josh/Library/CloudStorage/Dropbox/_Schar/Classes/2026-B/RD - POGO 801/Read/2026-11-11/GentzkowShapiro-CodeData-2014.pdf"
private let assignDoc = "/Users/josh/Library/CloudStorage/Dropbox/_Schar/Classes/2026-B/RD - POGO 801/Assign/Asgn04-Measurement/Draft.docx"
private let manual = "/Users/josh/Downloads/Suunto Core UserGuide EN.pdf"

@Suite("Document sensor: paths")
struct DocumentPathTests {

    @Test("Keeps only watched extensions, case-insensitively, deduplicated and sorted")
    func filtersExtensions() {
        let open = [rdPDF, "/usr/lib/libSystem.B.dylib", classPDF, classPDF, "/tmp/x.PDF", "/Users/j/notes.txt"]
        #expect(DocumentPaths.documents(in: open, extensions: ["pdf"]) == ["/tmp/x.PDF", classPDF, rdPDF].sorted())
    }

    @Test("A file inside a package is reported as the package")
    func packages() {
        let open = ["/Users/j/Docs/Report.pages/Index/Document.iwa", "/Users/j/Docs/Report.pages/Data/image.png",
                    "/Users/j/Sheets/Budget.numbers/Index/Tables/Data.iwa"]
        #expect(DocumentPaths.documents(in: open, extensions: ["pages"]) == ["/Users/j/Docs/Report.pages"])
        #expect(DocumentPaths.documents(in: open, extensions: ["numbers"]) == ["/Users/j/Sheets/Budget.numbers"])
    }

    @Test("Extensions written with a dot or spaces still match; empty list matches nothing")
    func extensionSpelling() {
        #expect(DocumentPaths.documents(in: [assignDoc], extensions: [" .DOCX "]) == [assignDoc])
        #expect(DocumentPaths.documents(in: [assignDoc], extensions: []).isEmpty)
        #expect(DocumentPaths.documents(in: ["relative/x.pdf", "/.pdf"], extensions: ["pdf"]).isEmpty)
    }

    @Test("Stem drops the directory and the extension")
    func stem() {
        #expect(DocumentPaths.stem(classPDF) == "CH03")
        #expect(DocumentPaths.stem("/a/b/archive.tar.gz") == "archive.tar")
        #expect(DocumentPaths.stem("/a/.hidden") == ".hidden")
    }
}

@Suite("Document sensor: process tree")
struct ProcessTreeTests {

    @Test("Root plus every descendant, nothing else")
    func descendants() {
        // 100 RStudio → 200 rsession → 300 R child; 400 unrelated; 1 launchd parents 100 and 400.
        let parents: [Int32: Int32] = [100: 1, 200: 100, 300: 200, 400: 1, 1: 0]
        #expect(ProcessTree.descendants(of: 100, parents: parents) == [100, 200, 300])
        #expect(ProcessTree.descendants(of: 400, parents: parents) == [400])
    }

    @Test("A self-parented entry or a cycle cannot loop forever")
    func cycles() {
        let parents: [Int32: Int32] = [5: 5, 6: 7, 7: 6]
        #expect(ProcessTree.descendants(of: 5, parents: parents) == [5])
        #expect(ProcessTree.descendants(of: 6, parents: parents) == [6, 7])
    }
}

@Suite("Document sensor: heartbeat")
struct DocumentHeartbeatTests {
    let reading = DocumentReading(app: "PDF Expert", bundleID: "com.readdle.PDFExpert-Mac", paths: [classPDF, rdPDF])

    @Test("Data has a fixed key order and no time in it")
    func fixedKeys() {
        let text = String(decoding: DocumentHeartbeat.data(for: reading), as: UTF8.self)
        #expect(text == #"{"app":"PDF Expert","bundle_id":"com.readdle.PDFExpert-Mac","count":2,"paths":["\#(classPDF)","\#(rdPDF)"]}"#)
    }

    @Test("Identical readings encode byte-identically, whenever they are taken")
    func deterministic() {
        let copy = DocumentReading(app: reading.app, bundleID: reading.bundleID, paths: reading.paths)
        #expect(DocumentHeartbeat.data(for: reading) == DocumentHeartbeat.data(for: copy))
        let a = DocumentHeartbeat.event(for: reading, at: Fixture.start)
        let b = DocumentHeartbeat.event(for: reading, at: Fixture.start.plus(seconds: 15))
        #expect(a != b) // only the timestamp differs …
        let strip = { (d: Data) in String(decoding: d, as: UTF8.self).components(separatedBy: ",\"duration\"")[0] }
        #expect(strip(a) == strip(b)) // … the data part does not
    }

    @Test("Bucket naming and pulsetime")
    func naming() {
        #expect(DocumentHeartbeat.bucketID(hostname: "MBA24.local") == "aw-watcher-documents_MBA24.local")
        #expect(DocumentHeartbeat.pulsetime(intervalSeconds: 15) == 30)
    }

    @Test("Only loopback servers are accepted")
    func loopback() {
        #expect(LoopbackURL.isLoopback("http://127.0.0.1:5600"))
        #expect(LoopbackURL.isLoopback("http://localhost:5600/"))
        #expect(LoopbackURL.isLoopback("http://[::1]:5600"))
        #expect(!LoopbackURL.isLoopback("http://192.168.1.4:5600"))
        #expect(!LoopbackURL.isLoopback("http://127.0.0.1.example.com:5600"))
        #expect(!LoopbackURL.isLoopback("not a url"))
    }
}

@Suite("Document sensor: backoff")
struct SensorBackoffTests {

    @Test("15 s, doubling, capped at 5 min; success resets")
    func growthAndCap() {
        var b = SensorBackoff()
        var delays: [TimeInterval] = []
        for _ in 0..<8 {
            b.failed(at: Fixture.start)
            delays.append(b.delay)
        }
        #expect(delays == [15, 30, 60, 120, 240, 300, 300, 300])
        #expect(!b.allowsAttempt(at: Fixture.start.plus(seconds: 299)))
        #expect(b.allowsAttempt(at: Fixture.start.plus(seconds: 300)))
        b.succeeded()
        #expect(b.delay == 0 && b.allowsAttempt(at: Fixture.start))
    }
}

/// A fake world: a scripted front-app reading and an in-memory aw-server.
private final class FakePort: DocumentSensorPort, @unchecked Sendable {
    var reading: DocumentReading?
    var serverUp = true
    var bucketsPrepared = 0
    var sent: [(bucket: String, pulsetime: Int, event: String)] = []

    func read(settings: DocumentSensorSettings) async -> DocumentReading? { reading }

    func prepareBucket(server: String) async throws -> String {
        guard serverUp else { throw URLError(.cannotConnectToHost) }
        bucketsPrepared += 1
        return DocumentHeartbeat.bucketID(hostname: "MBA24.local")
    }

    func sendHeartbeat(server: String, bucket: String, pulsetime: Int, event: Data) async throws {
        guard serverUp else { throw URLError(.cannotConnectToHost) }
        sent.append((bucket, pulsetime, String(decoding: event, as: UTF8.self)))
    }
}

@Suite("Document sensor: engine")
struct DocumentSensorEngineTests {
    let settings = DocumentSensorSettings()
    let server = "http://127.0.0.1:5600"

    @Test("Samples on every tick whatever the timer is doing: idle, Work, paused, Rest")
    func independentOfTimer() async {
        let port = FakePort()
        port.reading = DocumentReading(app: "PDF Expert", bundleID: "com.readdle.PDFExpert-Mac", paths: [classPDF])
        let engine = DocumentSensorEngine(port: port)

        // Drive a real timer through its states alongside the sensor; the engine is never told.
        var timer = PomodoroState(settings: Fixture.settings())
        let steps: [(PomodoroEvent?, Double)] = [
            (nil, 0),              // idle
            (.start, 10),          // Work running
            (.pause, 20),          // paused
            (.resume, 30),         // Work again
            (.skip, 40),           // Rest
            (.stop, 50),           // idle again
        ]
        var phases: [String] = []
        for (event, seconds) in steps {
            let now = Fixture.start.plus(seconds: seconds)
            if let event { timer = PomodoroReducer.reduce(timer, event, now) }
            phases.append("\(timer.activity)/\(timer.phase)")
            await engine.tick(settings: settings, server: server, now: now)
        }
        #expect(Set(phases).count >= 4) // the timer really went through different states
        #expect(port.sent.count == steps.count)
        #expect(port.bucketsPrepared == 1)
        #expect(port.sent.allSatisfy { $0.bucket == "aw-watcher-documents_MBA24.local" && $0.pulsetime == 30 })
    }

    @Test("Nothing is sent when the front app is not watched, shows no document, or the sensor is off")
    func nothingToSend() async {
        let port = FakePort()
        let engine = DocumentSensorEngine(port: port)
        await engine.tick(settings: settings, server: server, now: Fixture.start)
        port.reading = DocumentReading(app: "PDF Expert", bundleID: "com.readdle.PDFExpert-Mac", paths: [])
        await engine.tick(settings: settings, server: server, now: Fixture.start)
        #expect(port.sent.isEmpty)
        #expect(await engine.status == .waiting)

        port.reading = DocumentReading(app: "PDF Expert", bundleID: "com.readdle.PDFExpert-Mac", paths: [classPDF])
        var off = settings
        off.enabled = false
        await engine.tick(settings: off, server: server, now: Fixture.start)
        #expect(port.sent.isEmpty)
        #expect(await engine.status == .off)
    }

    @Test("A non-loopback server is refused without a request")
    func refusesRemote() async {
        let port = FakePort()
        port.reading = DocumentReading(app: "Preview", bundleID: "com.apple.Preview", paths: [classPDF])
        let engine = DocumentSensorEngine(port: port)
        await engine.tick(settings: settings, server: "http://example.com:5600", now: Fixture.start)
        #expect(port.sent.isEmpty && port.bucketsPrepared == 0)
        if case .error = await engine.status {} else { Issue.record("expected an error status") }
    }

    @Test("While the server is down, attempts back off; it recovers and re-prepares the bucket")
    func backoffAndRecovery() async {
        let port = FakePort()
        port.reading = DocumentReading(app: "PDF Expert", bundleID: "com.readdle.PDFExpert-Mac", paths: [classPDF])
        port.serverUp = false
        let engine = DocumentSensorEngine(port: port)
        await engine.tick(settings: settings, server: server, now: Fixture.start)               // fails, retry at +15
        await engine.tick(settings: settings, server: server, now: Fixture.start.plus(seconds: 10)) // skipped
        #expect(await engine.currentBackoff().delay == 15)
        await engine.tick(settings: settings, server: server, now: Fixture.start.plus(seconds: 15)) // fails, retry at +45
        #expect(await engine.currentBackoff().delay == 30)
        port.serverUp = true
        await engine.tick(settings: settings, server: server, now: Fixture.start.plus(seconds: 44)) // still backing off
        #expect(port.sent.isEmpty)
        await engine.tick(settings: settings, server: server, now: Fixture.start.plus(seconds: 45))
        #expect(port.sent.count == 1 && port.bucketsPrepared == 1)
        #expect(await engine.currentBackoff().delay == 0)
    }
}

@Suite("Document sensor: Focus")
struct DocumentFocusTests {
    let settings = FocusSettings()

    @Test("A class document maps to the same project as the class's notes")
    func classDocument() {
        let p = FocusRules.project(forDocument: classPDF, settings: settings)
        #expect(p?.area == "Classes/2026-B/Data - POGO 511")
        #expect(p?.task == "Classes/2026-B/Data - POGO 511/Chapters")
        let note = FocusRules.project(forFile: "/Classes/2026-B/Data - POGO 511/Chapters/CH03 notes.md", settings: settings)
        #expect(p == note)
    }

    @Test("An assignment document maps to its assignment task")
    func assignment() {
        let p = FocusRules.project(forDocument: assignDoc, settings: settings)
        #expect(p?.task == "Classes/2026-B/RD - POGO 801/Assign/Asgn04-Measurement")
    }

    @Test("A document outside every rule has no project")
    func noMatch() {
        #expect(FocusRules.project(forDocument: manual, settings: settings) == nil)
    }

    @Test("The window title picks the document; a single document is taken as is")
    func titleMatch() {
        let w = WindowSpan(start: Fixture.start, end: Fixture.start.plus(seconds: 60), app: "PDF Expert", title: "CH03")
        #expect(FocusRules.document(for: w, among: [rdPDF, classPDF]) == classPDF)
        let preview = WindowSpan(start: Fixture.start, end: Fixture.start, app: "Preview", title: "CH03.pdf – Page 2 of 40")
        #expect(FocusRules.document(for: preview, among: [classPDF, rdPDF]) == classPDF)
        let other = WindowSpan(start: Fixture.start, end: Fixture.start, app: "PDF Expert", title: "Something else")
        #expect(FocusRules.document(for: other, among: [rdPDF]) == rdPDF)
        #expect(FocusRules.document(for: other, among: [rdPDF, classPDF]) == nil)
    }

    @Test("Classifier: class document counts toward its project; other documents keep today's rules")
    func classifier() {
        let w = WindowSpan(start: Fixture.start, end: Fixture.start, app: "PDF Expert", title: "CH03")
        let c = FocusClassifier.category(window: w, note: nil, documents: [classPDF], settings: settings)
        #expect(c == .project(FocusProject(area: "Classes/2026-B/Data - POGO 511", task: "Classes/2026-B/Data - POGO 511/Chapters")))
        let m = WindowSpan(start: Fixture.start, end: Fixture.start, app: "PDF Expert", title: "Suunto Core UserGuide EN")
        #expect(FocusClassifier.category(window: m, note: nil, documents: [manual], settings: settings) == .support("PDF Expert"))
        let word = WindowSpan(start: Fixture.start, end: Fixture.start, app: "Microsoft Word", title: "Notes")
        #expect(FocusClassifier.category(window: word, note: nil, documents: ["/Users/j/Notes.docx"], settings: settings) == .distraction("Microsoft Word"))
    }

    @Test("Tracker: PDF Expert time with the sensor's documents counts toward the class project")
    func tracker() {
        let activity = FocusActivity(
            windows: [WindowSpan(start: Fixture.start, end: Fixture.start.plus(seconds: 120), app: "PDF Expert", title: "CH03")],
            documents: [DocumentSpan(start: Fixture.start.plus(seconds: -30), end: Fixture.start.plus(seconds: 110), app: "PDF Expert", paths: [classPDF])]
        )
        let snap = FocusTracker.snapshot(activity: activity, from: Fixture.start, to: Fixture.start.plus(seconds: 120), settings: settings)
        let project = FocusProject(area: "Classes/2026-B/Data - POGO 511", task: "Classes/2026-B/Data - POGO 511/Chapters")
        #expect(snap.projectSeconds[project] == 120)
        #expect(snap.supportSeconds == 0)
    }

    @Test("Parser reads documents-bucket events")
    func parser() throws {
        let json = #"[{"id":1,"timestamp":"2026-03-10T09:00:00.000000+00:00","duration":45.5,"data":{"app":"PDF Expert","bundle_id":"com.readdle.PDFExpert-Mac","count":1,"paths":["\#(classPDF)"]}}]"#
        let spans = try ActivityWatchParser.documents(Data(json.utf8))
        #expect(spans == [DocumentSpan(start: Fixture.start, end: Fixture.start.plus(seconds: 45.5), app: "PDF Expert", paths: [classPDF])])
    }

    @Test("Settings: old blobs decode with the default sensor; the on/off switch stays on this device")
    func settingsCompat() throws {
        let old = try JSONDecoder().decode(FocusSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(old.documents == DocumentSensorSettings())
        #expect(old.documents.apps.map(\.name).contains("RStudio"))

        var local = PomodoroSettings()
        local.focus.documents.enabled = false
        var remote = PomodoroSettings()
        remote.focus.documents.enabled = true
        remote.focus.documents.intervalSeconds = 30
        let merged = SyncMerge.adopt(remote: remote, keepingDeviceFieldsOf: local)
        #expect(merged.focus.documents.enabled == false)
        #expect(merged.focus.documents.intervalSeconds == 30)
    }
}
