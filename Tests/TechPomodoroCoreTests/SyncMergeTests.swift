import Foundation
import Testing
@testable import TechPomodoroCore

@Suite("Sync merge rules")
struct SyncMergeTests {

    private func work(_ minutesAfterStart: Double, id: UUID = UUID()) -> IntervalRecord {
        IntervalRecord(id: id, kind: .work, startedAt: Fixture.start.plus(minutes: minutesAfterStart), elapsedSeconds: 1500, completed: true)
    }

    @Test("History merges as a union by id, oldest first")
    func historyUnion() {
        let shared = UUID()
        let local = [work(0, id: shared), work(60)]
        let remote = [work(0, id: shared), work(30)]

        let merged = SyncMerge.mergeHistory(local: local, remote: remote, now: Fixture.start.plus(minutes: 120), calendar: Fixture.calendar)

        #expect(merged.count == 3)
        #expect(merged.map(\.startedAt) == [0, 30, 60].map { Fixture.start.plus(minutes: $0) })
        #expect(Set(merged.map(\.id)).count == 3)
    }

    @Test("Merging is idempotent: the same remote batch twice changes nothing")
    func historyIdempotent() {
        let local = [work(0)]
        let remote = [work(30), work(90)]
        let now = Fixture.start.plus(minutes: 120)
        let once = SyncMerge.mergeHistory(local: local, remote: remote, now: now, calendar: Fixture.calendar)
        let twice = SyncMerge.mergeHistory(local: once, remote: remote, now: now, calendar: Fixture.calendar)
        #expect(once == twice)
    }

    @Test("Remote records older than the retention window are dropped")
    func historyPrunes() {
        let old = IntervalRecord(kind: .work, startedAt: Fixture.start.plus(minutes: -60 * 24 * 40), elapsedSeconds: 1500, completed: true)
        let merged = SyncMerge.mergeHistory(local: [], remote: [old, work(0)], now: Fixture.start, calendar: Fixture.calendar)
        #expect(merged.count == 1)
    }

    @Test("Settings: the later edit wins; a tie goes to the remote copy")
    func settingsLastWriterWins() {
        let t = Fixture.start
        #expect(SyncMerge.settingsWinner(localModifiedAt: t.plus(minutes: 1), remoteModifiedAt: t) == .local)
        #expect(SyncMerge.settingsWinner(localModifiedAt: t, remoteModifiedAt: t.plus(minutes: 1)) == .remote)
        #expect(SyncMerge.settingsWinner(localModifiedAt: .distantPast, remoteModifiedAt: .distantPast) == .remote)
    }

    @Test("Adopting remote settings keeps this device's own fields")
    func adoptKeepsDeviceFields() {
        var local = PomodoroSettings()
        local.soundName = "Submarine"
        local.launchAtLogin = true
        local.cloudSyncEnabled = true
        local.focus.enabled = false
        local.focus.serverURL = "http://localhost:9999"

        var remote = PomodoroSettings(workMinutes: 50)
        remote.soundName = "Chime"
        remote.launchAtLogin = false
        remote.focus.enabled = true
        remote.focus.driftAlertSeconds = 90

        let merged = SyncMerge.adopt(remote: remote, keepingDeviceFieldsOf: local)

        #expect(merged.workMinutes == 50)
        #expect(merged.focus.driftAlertSeconds == 90)
        #expect(merged.soundName == "Submarine")
        #expect(merged.launchAtLogin == true)
        #expect(merged.focus.enabled == false)
        #expect(merged.focus.serverURL == "http://localhost:9999")
    }

    @Test("A change to a device-only field is not a synced change")
    func deviceOnlyChangeDoesNotSync() {
        let a = PomodoroSettings()
        var b = a
        b.soundName = "Submarine"
        b.launchAtLogin = true
        #expect(SyncMerge.syncedFieldsDiffer(a, b) == false)
        b.workMinutes = 40
        #expect(SyncMerge.syncedFieldsDiffer(a, b) == true)
    }

    @Test("Records and settings survive the sync payload roundtrip")
    func payloadRoundtrip() throws {
        let record = work(15)
        #expect(try IntervalRecord.fromSyncPayload(record.syncPayload()) == record)

        let synced = SyncedSettings(settings: PomodoroSettings(workMinutes: 45), modifiedAt: Fixture.start)
        #expect(try SyncedSettings.decode(synced.encoded()) == synced)
    }

    @Test("Settings without the sync key decode with sync on")
    func cloudSyncDefaultsOn() throws {
        let decoded = try JSONDecoder().decode(PomodoroSettings.self, from: Data(#"{"workMinutes":42}"#.utf8))
        #expect(decoded.cloudSyncEnabled == true)
    }
}
