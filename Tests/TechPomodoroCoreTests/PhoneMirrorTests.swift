import Foundation
import Testing
@testable import TechPomodoroCore

@Suite("Mirroring the iPhone timer to the Mac, and moving its Live Activity on")
struct PhoneMirrorTests {

    private func running(_ settings: PomodoroSettings = Fixture.settings(), at start: Date = Fixture.start) -> PomodoroState {
        PomodoroState(settings: settings).applying([(.start, start)])
    }

    private func phoneTimer(_ id: String, _ state: PomodoroState, changedAt: Date) -> MirrorTimer {
        MirrorTimer(
            deviceID: id,
            name: "iPhone \(id)",
            activity: state.activity,
            changedAt: changedAt,
            content: MirrorContentBuilder.content(for: state, at: changedAt),
            state: state.activity == .idle ? nil : MirrorTimerState(state)
        )
    }

    // MARK: - nextPhase

    @Test("Running content carries the next phase in full")
    func nextPhaseOfWork() throws {
        let c = try #require(MirrorContentBuilder.content(for: running(), at: Fixture.start.plus(minutes: 3)))
        let next = try #require(c.nextPhase)
        #expect(next.title == "Rest")
        #expect(next.startsAt == Fixture.start.plus(minutes: 25))
        #expect(next.endsAt == Fixture.start.plus(minutes: 30))
        #expect(next.progressLine == "Rep 2 of 3 · Cycle 1 of 2")
        // Rest takes the rest colour, which is on by default.
        #expect(next.tintHex == Fixture.settings().restColorHex)
    }

    @Test("The next phase follows the reducer into a long break, with the rest tint")
    func nextPhaseIsLongBreak() throws {
        var settings = Fixture.settings()
        settings.useRestColor = true
        settings.restColorHex = "#00FF00"
        // Third work rep: after 25+5+25+5 minutes.
        let state = running(settings).applying([(.tick, Fixture.start.plus(minutes: 60))])
        #expect(state.phase == .work)
        let next = try #require(MirrorContentBuilder.content(for: state, at: Fixture.start.plus(minutes: 61))?.nextPhase)
        #expect(next.title == Phase.longBreak.title)
        #expect(next.startsAt == Fixture.start.plus(minutes: 85))
        #expect(next.endsAt == Fixture.start.plus(minutes: 100))
        #expect(next.tintHex == "#00FF00")
    }

    @Test("No next phase while paused, or when the session ends at this boundary")
    func noNextPhase() throws {
        let paused = running().applying([(.pause, Fixture.start.plus(minutes: 5))])
        #expect(MirrorContentBuilder.content(for: paused, at: Fixture.start.plus(minutes: 6))?.nextPhase == nil)

        // One rep, one cycle, no repeat: Work → Long Break → Session Rest → idle.
        let short = Fixture.settings(reps: 1, cycles: 1)
        let sessionRest = running(short).applying([(.tick, Fixture.start.plus(minutes: 40))])
        #expect(sessionRest.phase == .sessionRest)
        #expect(MirrorContentBuilder.content(for: sessionRest, at: Fixture.start.plus(minutes: 41))?.nextPhase == nil)
    }

    @Test("Content without nextPhase, as an older Mac pushes it, still decodes")
    func olderContentDecodes() throws {
        var c = try #require(MirrorContentBuilder.content(for: running(), at: Fixture.start))
        c.nextPhase = nil
        var object = try #require(try JSONSerialization.jsonObject(with: MirrorCodec.encode(c)) as? [String: Any])
        object.removeValue(forKey: "nextPhase")
        let decoded = try MirrorCodec.decode(MirrorContent.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == c)
    }

    @Test("The own activity's push goes stale right at the phase end")
    func ownStaleDate() throws {
        let c = try #require(MirrorContentBuilder.content(for: running(), at: Fixture.start))
        let data = try APNsPayload.update(content: c, timestamp: 100, staleGrace: 0)
        let aps = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])["aps"] as? [String: Any]
        #expect(aps?["stale-date"] as? Int == Int(Fixture.start.plus(minutes: 25).timeIntervalSince1970))
    }

    // MARK: - The timer as JSON

    @Test("The timer round-trips with its schedule, onto a reader whose settings differ")
    func timerStateRoundTrip() throws {
        let phoneSettings = Fixture.settings(work: 50, rest: 10)
        let state = running(phoneSettings).applying([(.pause, Fixture.start.plus(minutes: 7))])
        let encoded = try MirrorCodec.encode(MirrorTimerState(state))
        let decoded = try MirrorCodec.decode(MirrorTimerState.self, from: encoded)

        var macSettings = Fixture.settings()
        macSettings.dingRepeatCount = 4
        let restored = try #require(decoded.restore(onto: macSettings))
        #expect(restored.activity == .paused)
        #expect(abs((restored.remainingWhenPaused ?? 0) - 43 * 60) < 0.001)
        #expect(restored.settings.workMinutes == 50)
        #expect(restored.settings.restMinutes == 10)
        // The reader's own alert settings are kept.
        #expect(restored.settings.dingRepeatCount == 4)
    }

    @Test("An inconsistent timer does not restore")
    func inconsistentTimer() {
        var dto = MirrorTimerState(running())
        dto.phaseEndsAt = nil
        #expect(dto.restore(onto: Fixture.settings()) == nil)
    }

    // MARK: - Which iPhone timer a Mac shows

    @Test("A Mac runs the iPhone's timer forward through boundaries the iPhone never wrote")
    func caughtUp() throws {
        let record = phoneTimer("a", running(), changedAt: Fixture.start)
        let shown = try #require(PhoneTimerArbiter.shown([record], settings: Fixture.settings(), now: Fixture.start.plus(minutes: 27)))
        #expect(shown.state.phase == .rest)
        #expect(shown.state.phaseEndsAt == Fixture.start.plus(minutes: 30))
        #expect(shown.state.pendingEffects.isEmpty)
        #expect(shown.state.pendingRecords.isEmpty)
    }

    @Test("Idle, finished, long-paused and abandoned iPhone timers are not shown")
    func notShown() {
        let settings = Fixture.settings()
        let idle = phoneTimer("a", PomodoroState(settings: settings), changedAt: Fixture.start)
        #expect(PhoneTimerArbiter.shown([idle], settings: settings, now: Fixture.start) == nil)

        let short = Fixture.settings(reps: 1, cycles: 1)
        let finishing = phoneTimer("b", running(short), changedAt: Fixture.start)
        #expect(PhoneTimerArbiter.shown([finishing], settings: settings, now: Fixture.start.plus(minutes: 101)) == nil)

        let paused = phoneTimer("c", running().applying([(.pause, Fixture.start.plus(minutes: 1))]), changedAt: Fixture.start.plus(minutes: 1))
        #expect(PhoneTimerArbiter.shown([paused], settings: settings, now: Fixture.start.plus(minutes: 2)) != nil)
        #expect(PhoneTimerArbiter.shown([paused], settings: settings, now: Fixture.start.plus(minutes: 1).addingTimeInterval(PhoneTimerArbiter.pausedLifetime)) == nil)

        let repeating = phoneTimer("d", running(Fixture.settings(repeatSession: true)), changedAt: Fixture.start)
        #expect(PhoneTimerArbiter.shown([repeating], settings: settings, now: Fixture.start.addingTimeInterval(PhoneTimerArbiter.runningLifetime)) == nil)
    }

    @Test("Of two iPhones, the one that changed last is shown")
    func newestWins() {
        let a = phoneTimer("a", running(), changedAt: Fixture.start)
        let b = phoneTimer("b", running(at: Fixture.start.plus(minutes: 2)), changedAt: Fixture.start.plus(minutes: 2))
        #expect(PhoneTimerArbiter.shown([a, b], settings: Fixture.settings(), now: Fixture.start.plus(minutes: 3))?.timer.deviceID == "b")
    }

    // MARK: - Pushing the iPhone's boundaries

    @Test("A boundary is pushed once, and the session's end is pushed as an end")
    func ownBroadcast() throws {
        let boundary = Fixture.start.plus(minutes: 25)
        let next = running().applying([(.tick, boundary)])
        let desired = try #require(MirrorContentBuilder.content(for: next, at: boundary))
        let channel = MirrorChannel(environment: .development, channelID: "own")

        #expect(MirrorPushPlanner.ownBroadcast(desired: desired, boundary: boundary, channel: channel) == .update(desired))

        var pushed = channel
        pushed.lastBoundary = boundary
        pushed.lastContent = desired
        #expect(MirrorPushPlanner.ownBroadcast(desired: desired, boundary: boundary, channel: pushed) == nil)
        // An older boundary arriving late (a Mac that slept) is not pushed over a newer one.
        #expect(MirrorPushPlanner.ownBroadcast(desired: desired, boundary: boundary.plus(minutes: -5), channel: pushed) == nil)

        #expect(MirrorPushPlanner.ownBroadcast(desired: nil, boundary: boundary.plus(minutes: 5), channel: pushed) == .end(desired))
    }
}
