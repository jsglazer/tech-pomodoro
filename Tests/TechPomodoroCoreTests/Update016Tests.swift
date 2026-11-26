import Foundation
import Testing
@testable import TechPomodoroCore

// Regression tests for the fixes from the 2026-11-11 audit (Update016).

@Suite("Sync: settings offered on start")
struct SettingsOfferOnStartTests {
    let t0 = Fixture.start
    let t1 = Fixture.start.addingTimeInterval(60)

    @Test func firstSyncAlwaysOffers() {
        #expect(SyncMerge.shouldOfferSettingsOnStart(hasSavedState: false, hasSystemFields: true, localModifiedAt: nil, uploadedModifiedAt: t0))
        #expect(SyncMerge.shouldOfferSettingsOnStart(hasSavedState: true, hasSystemFields: false, localModifiedAt: nil, uploadedModifiedAt: t0))
    }

    @Test func editMadeWhileSyncWasOffIsOffered() {
        // The Medium: settings edited after the last upload were never re-sent on start.
        #expect(SyncMerge.shouldOfferSettingsOnStart(hasSavedState: true, hasSystemFields: true, localModifiedAt: t1, uploadedModifiedAt: t0))
    }

    @Test func uploadedSettingsAreNotOfferedAgain() {
        #expect(!SyncMerge.shouldOfferSettingsOnStart(hasSavedState: true, hasSystemFields: true, localModifiedAt: t0, uploadedModifiedAt: t0))
        #expect(!SyncMerge.shouldOfferSettingsOnStart(hasSavedState: true, hasSystemFields: true, localModifiedAt: t0, uploadedModifiedAt: t1))
    }

    @Test func neverEditedIsNotOffered() {
        #expect(!SyncMerge.shouldOfferSettingsOnStart(hasSavedState: true, hasSystemFields: true, localModifiedAt: nil, uploadedModifiedAt: nil))
    }

    @Test func noUploadStampFromAnOlderBuildOffersOnce() {
        #expect(SyncMerge.shouldOfferSettingsOnStart(hasSavedState: true, hasSystemFields: true, localModifiedAt: t0, uploadedModifiedAt: nil))
    }
}

@Suite("Mirror: shared channel record merge")
struct ChannelResolveTests {
    let started = ["phone-a": Fixture.start]

    @Test func laterPushWinsAndTimestampNeverRegresses() {
        let mine = MirrorChannel(environment: .production, channelID: "c1", startedPhones: [:], lastTimestamp: 100)
        let server = MirrorChannel(environment: .production, channelID: "c1", startedPhones: started, lastTimestamp: 105)
        let stored = MirrorChannel.resolve(mine: mine, server: server)
        #expect(stored == server)
        #expect(stored.lastTimestamp == 105)
    }

    @Test func minePushedLastWins() {
        let mine = MirrorChannel(environment: .production, channelID: "c1", startedPhones: started, lastTimestamp: 110)
        let server = MirrorChannel(environment: .production, channelID: "c1", startedPhones: [:], lastTimestamp: 105)
        #expect(MirrorChannel.resolve(mine: mine, server: server) == mine)
    }

    @Test func tieGoesToMine() {
        let mine = MirrorChannel(environment: .production, channelID: "c1", startedPhones: started, lastTimestamp: 100)
        let server = MirrorChannel(environment: .production, channelID: "c1", startedPhones: [:], lastTimestamp: 100)
        #expect(MirrorChannel.resolve(mine: mine, server: server) == mine)
    }

    @Test func aReplacedChannelOnTheServerStands() {
        let mine = MirrorChannel(environment: .production, channelID: "old", startedPhones: started, lastTimestamp: 200)
        let server = MirrorChannel(environment: .production, channelID: "new", lastTimestamp: 0)
        #expect(MirrorChannel.resolve(mine: mine, server: server) == server)
    }
}

@Suite("Mirror: own-channel snapshot merge")
struct OwnChannelMergeTests {
    @Test func aChannelStoredDuringTheReadIsKept() {
        // The read went out before the channel was claimed, so it comes back without it.
        let readStartedAt = Fixture.start
        let claimed = MirrorChannel(environment: .production, channelID: "own-1")
        let merged = OwnChannelMerge.merge(fresh: [:], localWrites: ["phone-a": (claimed, readStartedAt.addingTimeInterval(2))], readStartedAt: readStartedAt)
        #expect(merged["phone-a"] == claimed)
    }

    @Test func aWriteOlderThanTheReadDefersToIt() {
        let readStartedAt = Fixture.start
        let local = MirrorChannel(environment: .production, channelID: "own-1", lastTimestamp: 1)
        let server = MirrorChannel(environment: .production, channelID: "own-1", lastTimestamp: 9)
        let merged = OwnChannelMerge.merge(fresh: ["phone-a": server], localWrites: ["phone-a": (local, readStartedAt.addingTimeInterval(-5))], readStartedAt: readStartedAt)
        #expect(merged["phone-a"] == server)
    }
}

@Suite("Focus: incremental ActivityWatch polling")
struct IncrementalSpansTests {
    let base = Fixture.start

    private func window(_ start: TimeInterval, _ end: TimeInterval, _ app: String) -> WindowSpan {
        WindowSpan(start: base.addingTimeInterval(start), end: base.addingTimeInterval(end), app: app, title: app)
    }

    @Test func firstPollReadsFromTheEarliestPoint() {
        #expect(IncrementalSpans.fetchStart(earliest: base, lastFetchedUntil: nil) == base)
    }

    @Test func laterPollsReadOnlyTheOverlap() {
        let until = base.addingTimeInterval(3600)
        #expect(IncrementalSpans.fetchStart(earliest: base, lastFetchedUntil: until) == until.addingTimeInterval(-IncrementalSpans.overlap))
        // Never earlier than the full range.
        #expect(IncrementalSpans.fetchStart(earliest: base, lastFetchedUntil: base.addingTimeInterval(10)) == base)
    }

    @Test func mergeMatchesAFullReRead() {
        // Full read at minute 20: three windows, the last still being extended.
        let cached = [window(900, 1200, "C"), window(300, 900, "B"), window(0, 300, "A")]
        // The next poll reads from minute 15: the extended C plus a new D.
        let from = base.addingTimeInterval(900)
        let fresh = [window(1300, 1320, "D"), window(900, 1300, "C")]
        let merged = IncrementalSpans.merge(cached: cached, fresh: fresh, from: from)
        let full = [window(1300, 1320, "D"), window(900, 1300, "C"), window(300, 900, "B"), window(0, 300, "A")]
        #expect(merged == full)
    }

    @Test func anEventExtendedPastTheCutIsNotDuplicated() {
        // B ended just before `from` when cached, but has since been extended across it.
        let cached = [window(300, 899, "B")]
        let fresh = [window(300, 1000, "B")]
        let merged = IncrementalSpans.merge(cached: cached, fresh: fresh, from: base.addingTimeInterval(900))
        #expect(merged == [window(300, 1000, "B")])
    }
}

@Suite("Paper: bucket published by diff")
struct PaperBucketDiffTests {
    private func event(_ start: String, _ duration: Double, _ record: String, class className: String = "Data") -> PaperPublishing.AWEvent {
        .init(timestamp: start, duration: duration, data: .init(class: className, kind: "Read", note: "", record_id: record, source: "app"))
    }

    @Test func unchangedEventsAreLeftAlone() {
        let desired = [event("2026-03-10T09:00:00.000Z", 1500, "a")]
        // aw-server hands the timestamp back in its own format, microseconds included.
        let stored = [PaperPublishing.StoredAWEvent(id: 7, event: event("2026-03-10T09:00:00.000000+00:00", 1500, "a"))]
        let diff = PaperPublishing.bucketDiff(stored: stored, desired: desired)
        #expect(diff.add.isEmpty)
        #expect(diff.deleteIDs.isEmpty)
    }

    @Test func anEditAddsTheNewEventAndDeletesTheOld() {
        let stored = [
            PaperPublishing.StoredAWEvent(id: 1, event: event("2026-03-10T09:00:00.000Z", 1500, "a")),
            PaperPublishing.StoredAWEvent(id: 2, event: event("2026-03-10T10:00:00.000Z", 600, "b"))
        ]
        let edited = event("2026-03-10T10:00:00.000Z", 600, "b", class: "Econ")
        let diff = PaperPublishing.bucketDiff(stored: stored, desired: [event("2026-03-10T09:00:00.000Z", 1500, "a"), edited])
        #expect(diff.add == [edited])
        #expect(diff.deleteIDs == [2])
    }

    @Test func duplicatesMatchOneForOne() {
        let same = event("2026-03-10T09:00:00.000Z", 60, "a")
        let stored = [PaperPublishing.StoredAWEvent(id: 1, event: same), PaperPublishing.StoredAWEvent(id: 2, event: same)]
        let diff = PaperPublishing.bucketDiff(stored: stored, desired: [same])
        #expect(diff.add.isEmpty)
        #expect(diff.deleteIDs.count == 1)
    }

    @Test func storedEventsParseAwServerJSON() throws {
        let json = #"[{"id": 12, "timestamp": "2026-03-10T09:00:00.117000+00:00", "duration": 1500.0, "data": {"class": "Data", "kind": "Read", "note": "", "record_id": "a", "source": "app"}}, {"id": 13, "timestamp": "2026-03-10T09:00:00Z", "duration": 1.0, "data": {"other": 1}}]"#
        let stored = try PaperPublishing.storedEvents(Data(json.utf8))
        #expect(stored.map(\.id) == [12, 13])
        #expect(stored[0].event?.data.record_id == "a")
        // Not a paper sitting: the app owns the bucket, so it goes.
        #expect(stored[1].event == nil)
        #expect(PaperPublishing.bucketDiff(stored: stored, desired: []).deleteIDs == [12, 13])
    }
}

@Suite("Settings: commit on end of editing")
struct SettingsDraftTests {
    @Test func manyEditsCommitOnceAgainstTheFirstBaseline() {
        var draft = SettingsDraft()
        let a = PomodoroSettings()
        var b = a
        b.menuBarTextColorHex = "#111111"
        var c = b
        c.menuBarTextColorHex = "#222222"
        draft.edit(replacing: a)
        draft.edit(replacing: b)
        #expect(draft.isPending)
        let change = draft.commit(current: c)
        #expect(change?.old == a)
        #expect(change?.new == c)
        #expect(!draft.isPending)
        #expect(draft.commit(current: c) == nil)
    }

    @Test func editsThatReturnToTheStartCommitNothing() {
        var draft = SettingsDraft()
        let a = PomodoroSettings()
        draft.edit(replacing: a)
        #expect(draft.commit(current: a) == nil)
    }

    @Test func discardDropsTheDraft() {
        var draft = SettingsDraft()
        draft.edit(replacing: PomodoroSettings())
        draft.discard()
        var other = PomodoroSettings()
        other.workMinutes = 50
        #expect(draft.commit(current: other) == nil)
    }
}

@Suite("Settings: no machine paths in the core")
struct DefaultPathTests {
    @Test func paperLogPathDefaultsToEmpty() {
        #expect(PomodoroSettings.defaultPaperLogPath.isEmpty)
        #expect(PomodoroSettings().paperLogPath.isEmpty)
    }
}
