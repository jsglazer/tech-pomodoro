import Foundation
import Testing
@testable import TechPomodoroCore

@Suite("Mirroring the Mac timer to the iPhone")
struct MirrorTests {

    // MARK: - Helpers

    private func running(at start: Date = Fixture.start) -> PomodoroState {
        PomodoroState(settings: Fixture.settings()).applying([(.start, start)])
    }

    private func content(_ state: PomodoroState, at now: Date) -> MirrorContent {
        MirrorContentBuilder.content(for: state, at: now)!
    }

    private func timer(_ id: String, _ state: PomodoroState, changedAt: Date) -> MirrorTimer {
        MirrorTimer(
            deviceID: id,
            name: "Mac \(id)",
            activity: state.activity,
            changedAt: changedAt,
            content: MirrorContentBuilder.content(for: state, at: changedAt)
        )
    }

    private func phone(_ id: String = "phone", enabled: Bool = true, token: String? = "abcd", env: APNsEnvironment = .development, endedAt: Date? = nil) -> MirrorPhone {
        MirrorPhone(deviceID: id, name: "iPhone", mirroringEnabled: enabled, pushToStartToken: token, environment: env, mirrorEndedAt: endedAt, updatedAt: Fixture.start)
    }

    private let channel = MirrorChannel(environment: .development, channelID: "chan")

    private func json(_ data: Data) throws -> [String: Any] {
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["aps"] as? [String: Any])
    }

    // MARK: - Content

    @Test("Idle has no content; running content spans the phase and lists what comes next")
    func runningContent() {
        #expect(MirrorContentBuilder.content(for: PomodoroState(settings: Fixture.settings()), at: Fixture.start) == nil)

        let state = running()
        let c = content(state, at: Fixture.start.plus(minutes: 10))
        #expect(c.phaseTitle == "Work")
        #expect(!c.isPaused)
        #expect(c.phaseStartedAt == Fixture.start)
        #expect(c.phaseEndsAt == Fixture.start.plus(minutes: 25))
        #expect(c.pausedRemaining == nil)
        #expect(c.progressLine == "Rep 1 of 3 · Cycle 1 of 2")
        #expect(c.upcoming.first == MirrorUpcoming(title: "Rest", startsAt: Fixture.start.plus(minutes: 25)))
        #expect(c.upcoming.count == 3)
        #expect(c.tintHex == MirrorContentBuilder.primaryHex)
        #expect(c.remaining(at: Fixture.start.plus(minutes: 10)) == 15 * 60)
        #expect(MirrorContentBuilder.staleDate(for: c) == Fixture.start.plus(minutes: 25, seconds: MirrorContentBuilder.staleGrace))
    }

    @Test("Paused content holds its remaining time and is never stale")
    func pausedContent() {
        let paused = running().applying([(.toggleRunning, Fixture.start.plus(minutes: 10))])
        let c = content(paused, at: Fixture.start.plus(minutes: 12))
        #expect(c.isPaused)
        #expect(c.pausedRemaining == TimeInterval(15 * 60))
        #expect(c.upcoming.isEmpty)
        #expect(MirrorContentBuilder.staleDate(for: c) == nil)
        #expect(abs(c.progress(at: Fixture.start.plus(minutes: 40)) - 0.4) < 0.0001)
    }

    @Test("Rest phases carry the rest colour")
    func restTint() {
        let resting = running().applying([(.skip, Fixture.start.plus(minutes: 1))])
        #expect(content(resting, at: Fixture.start.plus(minutes: 2)).tintHex == Fixture.settings().restColorHex)
    }

    @Test("Content round-trips through the CloudKit payload unchanged, so a stored copy compares equal")
    func codecRoundTrip() throws {
        var c = content(running(), at: Fixture.start.plus(seconds: 0.123))
        c.mirroredFrom = "Studio"
        let back = try MirrorCodec.decode(MirrorContent.self, from: MirrorCodec.encode(c))
        #expect(back == c)
    }

    // MARK: - Change key: push on change only

    @Test("A plain tick inside a phase does not change what the iPhone must hear")
    func tickDoesNotChangeKey() {
        let state = running()
        let ticked = PomodoroReducer.reduce(state, .tick, Fixture.start.plus(minutes: 3))
        #expect(MirrorChangeKey(ticked) == MirrorChangeKey(state))
    }

    @Test("Pause, resume, skip, a boundary, stop and a schedule change all do")
    func changesChangeKey() {
        let state = running()
        let key = MirrorChangeKey(state)
        let at = Fixture.start.plus(minutes: 5)
        #expect(MirrorChangeKey(PomodoroReducer.reduce(state, .toggleRunning, at)) != key)
        #expect(MirrorChangeKey(PomodoroReducer.reduce(state, .skip, at)) != key)
        #expect(MirrorChangeKey(PomodoroReducer.reduce(state, .stop, at)) != key)
        #expect(MirrorChangeKey(PomodoroReducer.reduce(state, .tick, Fixture.start.plus(minutes: 25))) != key)
        let paused = PomodoroReducer.reduce(state, .toggleRunning, at)
        #expect(MirrorChangeKey(PomodoroReducer.reduce(paused, .toggleRunning, at.plus(minutes: 1))) != MirrorChangeKey(paused))
        var settings = state.settings
        settings.restMinutes = 7
        #expect(MirrorChangeKey(PomodoroReducer.reduce(state, .settingsChanged(settings), at)) != key)
    }

    @Test("A change to a setting the iPhone never shows does not")
    func unrelatedSettingDoesNotChangeKey() {
        let state = running()
        var settings = state.settings
        settings.soundName = "Ping"
        settings.menuBarMode = .clockIcon
        #expect(MirrorChangeKey(PomodoroReducer.reduce(state, .settingsChanged(settings), Fixture.start.plus(minutes: 1))) == MirrorChangeKey(state))
    }

    // MARK: - Which timer wins

    @Test("No active Mac timer: the iPhone shows its own")
    func noWinnerWhenIdle() {
        let idle = MirrorTimer(deviceID: "a", name: "A", activity: .idle, changedAt: Fixture.start, content: nil)
        #expect(MirrorArbiter.winner([idle], now: Fixture.start) == nil)
        #expect(MirrorArbiter.winner([], now: Fixture.start) == nil)
    }

    @Test("Of several active Macs, the one that changed most recently wins")
    func mostRecentWins() {
        let a = timer("a", running(), changedAt: Fixture.start)
        let b = timer("b", running(at: Fixture.start.plus(minutes: 2)), changedAt: Fixture.start.plus(minutes: 2))
        let now = Fixture.start.plus(minutes: 3)
        #expect(MirrorArbiter.winner([a, b], now: now)?.deviceID == "b")
        #expect(MirrorArbiter.winner([b, a], now: now)?.deviceID == "b")
        #expect(MirrorArbiter.displayed([a, b], now: now)?.mirroredFrom == "Mac b")
    }

    @Test("An idle Mac that changed last does not beat a Mac still running")
    func idleNeverWins() {
        let a = timer("a", running(), changedAt: Fixture.start)
        let b = MirrorTimer(deviceID: "b", name: "B", activity: .idle, changedAt: Fixture.start.plus(minutes: 5), content: nil)
        #expect(MirrorArbiter.winner([a, b], now: Fixture.start.plus(minutes: 6))?.deviceID == "a")
    }

    @Test("A running Mac that went quiet past its phase end drops out; a paused one lasts 12 hours")
    func staleTimersDropOut() {
        let a = timer("a", running(), changedAt: Fixture.start)
        #expect(MirrorArbiter.winner([a], now: Fixture.start.plus(minutes: 29)) != nil)
        #expect(MirrorArbiter.winner([a], now: Fixture.start.plus(minutes: 31)) == nil)

        let pausedAt = Fixture.start.plus(minutes: 5)
        let p = timer("p", running().applying([(.toggleRunning, pausedAt)]), changedAt: pausedAt)
        #expect(MirrorArbiter.winner([p], now: pausedAt.plus(minutes: 11 * 60)) != nil)
        #expect(MirrorArbiter.winner([p], now: pausedAt.plus(minutes: 13 * 60)) == nil)
    }

    // MARK: - Push planning

    @Test("A Mac start sends one push-to-start and no broadcast")
    func firstStart() {
        let desired = content(running(), at: Fixture.start)
        let plan = MirrorPushPlanner.plan(desired: desired, channel: channel, phones: [phone()], now: Fixture.start)
        #expect(plan.starts.map(\.deviceID) == ["phone"])
        #expect(plan.broadcast == nil)
        #expect(plan.channel.startedPhones["phone"] == Fixture.start)
        #expect(plan.channel.lastContent == desired)
    }

    @Test("Once started, a change is one broadcast update")
    func changeBroadcasts() {
        let started = MirrorPushPlanner.plan(desired: content(running(), at: Fixture.start), channel: channel, phones: [phone()], now: Fixture.start).channel
        let pausedAt = Fixture.start.plus(minutes: 4)
        let paused = content(running().applying([(.toggleRunning, pausedAt)]), at: pausedAt)
        let plan = MirrorPushPlanner.plan(desired: paused, channel: started, phones: [phone()], now: pausedAt)
        #expect(plan.starts.isEmpty)
        #expect(plan.broadcast == .update(paused))
        #expect(plan.channel.lastContent == paused)
    }

    @Test("The same content twice pushes nothing")
    func noDuplicatePush() {
        let desired = content(running(), at: Fixture.start)
        let started = MirrorPushPlanner.plan(desired: desired, channel: channel, phones: [phone()], now: Fixture.start).channel
        let again = MirrorPushPlanner.plan(desired: desired, channel: started, phones: [phone()], now: Fixture.start.plus(minutes: 1))
        #expect(again.isEmpty)
        #expect(again.channel == started)
    }

    @Test("Going idle ends the activity once, then pushes nothing")
    func stopEnds() {
        let desired = content(running(), at: Fixture.start)
        let started = MirrorPushPlanner.plan(desired: desired, channel: channel, phones: [phone()], now: Fixture.start).channel
        let stop = MirrorPushPlanner.plan(desired: nil, channel: started, phones: [phone()], now: Fixture.start.plus(minutes: 2))
        #expect(stop.broadcast == .end(desired))
        #expect(stop.channel.startedPhones.isEmpty)
        let again = MirrorPushPlanner.plan(desired: nil, channel: stop.channel, phones: [phone()], now: Fixture.start.plus(minutes: 3))
        #expect(again.isEmpty)
    }

    @Test("An activity swiped away on the iPhone is started again on the next change")
    func restartAfterDismissal() {
        let started = MirrorPushPlanner.plan(desired: content(running(), at: Fixture.start), channel: channel, phones: [phone()], now: Fixture.start).channel
        let swiped = phone(endedAt: Fixture.start.plus(minutes: 1))
        let skipped = content(running().applying([(.skip, Fixture.start.plus(minutes: 2))]), at: Fixture.start.plus(minutes: 2))
        let plan = MirrorPushPlanner.plan(desired: skipped, channel: started, phones: [swiped], now: Fixture.start.plus(minutes: 2))
        #expect(plan.starts.map(\.deviceID) == ["phone"])
        #expect(plan.broadcast == nil)
    }

    @Test("A second iPhone joining gets a start while the first gets the update")
    func secondPhone() {
        let started = MirrorPushPlanner.plan(desired: content(running(), at: Fixture.start), channel: channel, phones: [phone("one")], now: Fixture.start).channel
        let skipped = content(running().applying([(.skip, Fixture.start.plus(minutes: 2))]), at: Fixture.start.plus(minutes: 2))
        let plan = MirrorPushPlanner.plan(desired: skipped, channel: started, phones: [phone("one"), phone("two")], now: Fixture.start.plus(minutes: 2))
        #expect(plan.starts.map(\.deviceID) == ["two"])
        #expect(plan.broadcast == .update(skipped))
    }

    @Test("No push goes to an iPhone with mirroring off, without a token, or on the other APNs environment")
    func ineligiblePhones() {
        let desired = content(running(), at: Fixture.start)
        let phones = [phone("off", enabled: false), phone("none", token: nil), phone("prod", env: .production)]
        let plan = MirrorPushPlanner.plan(desired: desired, channel: channel, phones: phones, now: Fixture.start)
        #expect(plan.isEmpty)
    }

    // MARK: - APNs payloads

    @Test("Push-to-start payload: start event, mirror attributes, channel, alert, dates as ActivityKit decodes them")
    func startPayload() throws {
        let c = content(running(), at: Fixture.start)
        let aps = try json(APNsPayload.start(content: c, timestamp: 1_000, channelID: "chan", alertTitle: "Work", alertBody: "On Studio"))
        #expect(aps["event"] as? String == "start")
        #expect(aps["timestamp"] as? Int == 1_000)
        #expect(aps["attributes-type"] as? String == "PomodoroActivityAttributes")
        #expect((aps["attributes"] as? [String: String])?["mirrorSource"] == "mac")
        #expect(aps["input-push-channel"] as? String == "chan")
        #expect((aps["alert"] as? [String: String])?["title"] == "Work")
        #expect(aps["stale-date"] as? Int == Int(MirrorContentBuilder.staleDate(for: c)!.timeIntervalSince1970))
        let state = try #require(aps["content-state"] as? [String: Any])
        #expect(state["phaseTitle"] as? String == "Work")
        // ActivityKit decodes content-state with Foundation's default date strategy.
        #expect(state["phaseEndsAt"] as? Double == c.phaseEndsAt.timeIntervalSinceReferenceDate)
    }

    @Test("Update and end payloads")
    func updateAndEndPayloads() throws {
        let c = content(running(), at: Fixture.start)
        let update = try json(APNsPayload.update(content: c, timestamp: 5))
        #expect(update["event"] as? String == "update")
        #expect(update["content-state"] != nil)
        #expect(update["input-push-channel"] == nil)

        let end = try json(APNsPayload.end(content: nil, timestamp: 6))
        #expect(end["event"] as? String == "end")
        #expect(end["dismissal-date"] as? Int == 6)
        #expect(end["content-state"] == nil)
    }

    @Test("Push timestamps only grow, even two pushes in one second")
    func monotonicTimestamps() {
        var ch = channel
        let now = Date(timeIntervalSince1970: 2_000)
        let first = ch.nextTimestamp(at: now)
        ch.lastTimestamp = first
        #expect(first == 2_000)
        #expect(ch.nextTimestamp(at: now) == 2_001)
    }

    // MARK: - Settings

    @Test("Mirroring is a per-device switch: never synced, never adopted from another device")
    func mirrorSwitchIsDeviceLocal() {
        var local = PomodoroSettings()
        local.mirrorEnabled = false
        var remote = PomodoroSettings()
        remote.mirrorEnabled = true
        #expect(SyncMerge.adopt(remote: remote, keepingDeviceFieldsOf: local).mirrorEnabled == false)
        #expect(!SyncMerge.syncedFieldsDiffer(local, PomodoroSettings()))
    }

    @Test("Settings stored before mirroring existed decode with it on")
    func legacySettingsDecode() throws {
        let data = Data(#"{"workMinutes": 30}"#.utf8)
        let decoded = try JSONDecoder().decode(PomodoroSettings.self, from: data)
        #expect(decoded.mirrorEnabled)
        #expect(decoded.workMinutes == 30)
    }
}
