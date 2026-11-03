import Foundation

// Mirroring a Mac's timer onto the iPhone's Live Activity and timer screen (display only).
//
// Transport: the Mac sends Live Activity pushes to APNs itself. A start goes to each iPhone's
// push-to-start token and subscribes the new activity to one broadcast channel; every later change
// (pause, resume, skip, phase boundary, stop) is a single broadcast on that channel. The countdown
// runs on the phone from `phaseStartedAt`/`phaseEndsAt`, so nothing is pushed per second.
//
// Hand-off: the iPhone's push-to-start token, the Macs' timers and the channel all live as records in
// the existing CloudKit zone. Every rule about what to show and what to push lives here, in the core,
// so it is tested headlessly; the shells only move bytes.

// MARK: - What the Live Activity shows

/// The Live Activity's content, as plain values. Field for field the same shape — and the same JSON
/// keys — as `PomodoroActivityAttributes.ContentState`, which the widget extension decodes from a
/// push's `content-state`. Dates use Foundation's default `Codable` form (seconds since 2001-01-01),
/// which is what ActivityKit expects in a push payload.
public struct MirrorContent: Codable, Hashable, Sendable {
    public var phaseTitle: String
    public var isPaused: Bool
    public var phaseStartedAt: Date
    public var phaseEndsAt: Date
    public var pausedRemaining: TimeInterval?
    public var progressLine: String
    public var upcoming: [MirrorUpcoming]
    public var tintHex: String
    /// The Mac this content came from; nil for the iPhone's own timer.
    public var mirroredFrom: String?

    public init(
        phaseTitle: String,
        isPaused: Bool,
        phaseStartedAt: Date,
        phaseEndsAt: Date,
        pausedRemaining: TimeInterval?,
        progressLine: String,
        upcoming: [MirrorUpcoming],
        tintHex: String,
        mirroredFrom: String? = nil
    ) {
        self.phaseTitle = phaseTitle
        self.isPaused = isPaused
        self.phaseStartedAt = phaseStartedAt
        self.phaseEndsAt = phaseEndsAt
        self.pausedRemaining = pausedRemaining
        self.progressLine = progressLine
        self.upcoming = upcoming
        self.tintHex = tintHex
        self.mirroredFrom = mirroredFrom
    }

    /// Paused content holds a still readout; running content counts down to `phaseEndsAt`.
    public func remaining(at now: Date) -> TimeInterval {
        if let pausedRemaining { return max(0, pausedRemaining) }
        return max(0, phaseEndsAt.timeIntervalSince(now))
    }

    /// `0...1` through the phase.
    public func progress(at now: Date) -> Double {
        let total = phaseEndsAt.timeIntervalSince(phaseStartedAt)
        guard total > 0 else { return 1 }
        return min(1, max(0, (total - remaining(at: now)) / total))
    }
}

public struct MirrorUpcoming: Codable, Hashable, Sendable {
    public var title: String
    public var startsAt: Date

    public init(title: String, startsAt: Date) {
        self.title = title
        self.startsAt = startsAt
    }
}

public enum MirrorContentBuilder {

    /// The primary cyan, the tint of every non-rest phase.
    public static let primaryHex = "#22D3EE"

    /// Seconds past a running phase's end before the Live Activity is marked stale. The Mac pushes at
    /// every boundary, so this only shows when the Mac went quiet (asleep, quit, offline).
    public static let staleGrace: TimeInterval = 90

    /// Flattens the core state into the values the Live Activity draws. Nil when idle.
    public static func content(
        for state: PomodoroState,
        at now: Date,
        primaryHex: String = MirrorContentBuilder.primaryHex,
        mirroredFrom: String? = nil
    ) -> MirrorContent? {
        guard state.activity != .idle else { return nil }
        let settings = state.settings
        let isPaused = state.activity == .paused
        let remaining = state.remaining(at: now)
        // Paused, the end is where it would land if resumed this instant, so the bar holds its place.
        let end = isPaused ? now.addingTimeInterval(remaining) : (state.phaseEndsAt ?? now)
        // Measured back from the end rather than read from `phaseStartedAt`, which a pause does not
        // move: after a resume the bar must still span exactly one phase length.
        let start = end.addingTimeInterval(-state.phaseDuration)
        let upcoming = BoundaryPlanner.upcoming(from: state, now: now, limit: 3)
            .compactMap { boundary in
                boundary.nextPhase.map { MirrorUpcoming(title: $0.title, startsAt: boundary.fireAt) }
            }
        let tint = settings.useRestColor && state.phase != .work ? settings.restColorHex : primaryHex

        return MirrorContent(
            phaseTitle: state.phase.title,
            isPaused: isPaused,
            phaseStartedAt: start,
            phaseEndsAt: end,
            pausedRemaining: isPaused ? remaining : nil,
            progressLine: "Rep \(state.currentRep) of \(settings.repsPerCycle) · Cycle \(state.currentCycle) of \(settings.cyclesPerSession)",
            upcoming: upcoming,
            tintHex: tint,
            mirroredFrom: mirroredFrom
        )
    }

    /// When the activity should be marked out of date: a little after a running phase ends, never
    /// while paused.
    public static func staleDate(for content: MirrorContent) -> Date? {
        content.isPaused ? nil : content.phaseEndsAt.addingTimeInterval(staleGrace)
    }
}

/// The fields whose change the iPhone must hear about. A Mac pushes only when this changes, never on
/// a plain tick.
public struct MirrorChangeKey: Equatable, Sendable {
    let activity: PomodoroState.Activity
    let phase: Phase
    let phaseEndsAt: Date?
    let remainingWhenPaused: TimeInterval?
    let completedRepsInCycle: Int
    let completedCyclesInSession: Int
    let completedSessions: Int
    let schedule: [Int]
    let repeatSession: Bool
    let useRestColor: Bool
    let restColorHex: String

    public init(_ state: PomodoroState) {
        let s = state.settings
        activity = state.activity
        phase = state.phase
        phaseEndsAt = state.phaseEndsAt
        remainingWhenPaused = state.remainingWhenPaused
        completedRepsInCycle = state.completedRepsInCycle
        completedCyclesInSession = state.completedCyclesInSession
        completedSessions = state.completedSessions
        schedule = [s.workMinutes, s.restMinutes, s.repsPerCycle, s.longBreakMinutes, s.cyclesPerSession, s.sessionRestMinutes]
        repeatSession = s.repeatSession
        useRestColor = s.useRestColor
        restColorHex = s.restColorHex
    }
}

// MARK: - Records exchanged through CloudKit

/// Which APNs host a token belongs to. A development-signed iPhone build gets sandbox tokens.
public enum APNsEnvironment: String, Codable, Sendable, CaseIterable {
    case development
    case production
}

/// An iPhone, as the Macs see it: whether it wants the Mac's timer, and where to push a start.
public struct MirrorPhone: Codable, Equatable, Sendable {
    public var deviceID: String
    public var name: String
    /// The iPhone's own "Show Mac timer" switch.
    public var mirroringEnabled: Bool
    /// Hex push-to-start token for `PomodoroActivityAttributes`.
    public var pushToStartToken: String?
    public var environment: APNsEnvironment
    /// The last time the iPhone saw a mirrored activity end or be swiped away. A start sent before
    /// this no longer has an activity behind it, so the next change starts a fresh one.
    public var mirrorEndedAt: Date?
    public var updatedAt: Date

    public init(
        deviceID: String,
        name: String,
        mirroringEnabled: Bool,
        pushToStartToken: String?,
        environment: APNsEnvironment,
        mirrorEndedAt: Date? = nil,
        updatedAt: Date
    ) {
        self.deviceID = deviceID
        self.name = name
        self.mirroringEnabled = mirroringEnabled
        self.pushToStartToken = pushToStartToken
        self.environment = environment
        self.mirrorEndedAt = mirrorEndedAt
        self.updatedAt = updatedAt
    }

    /// Can be sent a start at all.
    public var canReceive: Bool {
        mirroringEnabled && !(pushToStartToken ?? "").isEmpty
    }
}

/// A Mac's timer, as it last changed. Written on every change the iPhone must hear about.
public struct MirrorTimer: Codable, Equatable, Sendable {
    public var deviceID: String
    public var name: String
    public var activity: PomodoroState.Activity
    public var changedAt: Date
    /// Nil when idle.
    public var content: MirrorContent?

    public init(deviceID: String, name: String, activity: PomodoroState.Activity, changedAt: Date, content: MirrorContent?) {
        self.deviceID = deviceID
        self.name = name
        self.activity = activity
        self.changedAt = changedAt
        self.content = content
    }
}

/// The broadcast channel every mirrored activity in one APNs environment listens to, plus what the
/// Macs have already told it, so no Mac repeats a push another already made.
public struct MirrorChannel: Codable, Equatable, Sendable {
    public var environment: APNsEnvironment
    public var channelID: String
    /// iPhones sent a start, and when. Empty means no mirrored activity is believed to be up.
    public var startedPhones: [String: Date]
    /// The content the channel last carried.
    public var lastContent: MirrorContent?
    /// APNs ignores an update whose `timestamp` is not newer than the one before, so it only grows.
    public var lastTimestamp: Int

    public init(environment: APNsEnvironment, channelID: String, startedPhones: [String: Date] = [:], lastContent: MirrorContent? = nil, lastTimestamp: Int = 0) {
        self.environment = environment
        self.channelID = channelID
        self.startedPhones = startedPhones
        self.lastContent = lastContent
        self.lastTimestamp = lastTimestamp
    }

    /// The next push timestamp: now in whole seconds, but always past the previous one.
    public func nextTimestamp(at now: Date) -> Int {
        max(Int(now.timeIntervalSince1970), lastTimestamp + 1)
    }
}

/// JSON for the CloudKit `payload` field. Default date encoding, so a date round-trips exactly and
/// stored content compares equal to freshly built content.
public enum MirrorCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

extension PomodoroState.Activity: Codable {}

// MARK: - Which timer wins

public enum MirrorArbiter {

    /// How long a running Mac timer still counts after its phase should have ended without the Mac
    /// saying so. A live Mac rewrites its record at every boundary; one that went quiet is gone.
    public static let runningGrace: TimeInterval = 5 * 60
    /// How long a paused Mac timer keeps winning over the iPhone's own.
    public static let pausedLifetime: TimeInterval = 12 * 60 * 60

    /// Still worth showing at `now`.
    public static func isLive(_ content: MirrorContent, changedAt: Date, now: Date) -> Bool {
        if content.isPaused {
            return now.timeIntervalSince(changedAt) < pausedLifetime
        }
        return now < content.phaseEndsAt.addingTimeInterval(runningGrace)
    }

    public static func isLive(_ timer: MirrorTimer, now: Date) -> Bool {
        guard timer.activity != .idle, let content = timer.content else { return false }
        return isLive(content, changedAt: timer.changedAt, now: now)
    }

    /// The Mac timer to show: of the live ones, the one that changed most recently. Nil means none is
    /// active, and the iPhone shows its own timer.
    public static func winner(_ timers: [MirrorTimer], now: Date) -> MirrorTimer? {
        timers
            .filter { isLive($0, now: now) }
            .max { lhs, rhs in
                lhs.changedAt == rhs.changedAt ? lhs.deviceID < rhs.deviceID : lhs.changedAt < rhs.changedAt
            }
    }

    /// What the iPhone displays: the winner's content, labelled with the Mac it came from.
    public static func displayed(_ timers: [MirrorTimer], now: Date) -> MirrorContent? {
        guard let winner = winner(timers, now: now), var content = winner.content else { return nil }
        content.mirroredFrom = winner.name
        return content
    }
}

// MARK: - What to push

public enum MirrorPushPlanner {

    public enum Broadcast: Equatable, Sendable {
        case update(MirrorContent)
        case end(MirrorContent?)
    }

    public struct Plan: Equatable, Sendable {
        /// iPhones to send a push-to-start, each subscribing its new activity to the channel.
        public var starts: [MirrorPhone]
        /// One push on the channel for every activity already up.
        public var broadcast: Broadcast?
        /// The channel record as it stands once the pushes have gone out.
        public var channel: MirrorChannel

        public var isEmpty: Bool { starts.isEmpty && broadcast == nil }
    }

    /// Decides the pushes that bring every iPhone in `channel.environment` to `desired` (nil: no Mac
    /// timer is active). Only a real change is pushed: the same content twice is nothing.
    public static func plan(desired: MirrorContent?, channel: MirrorChannel, phones: [MirrorPhone], now: Date) -> Plan {
        var after = channel
        let eligible = phones.filter { $0.canReceive && $0.environment == channel.environment }
        let eligibleIDs = Set(eligible.map(\.deviceID))
        // An iPhone that turned mirroring off ended its mirrored activity itself.
        after.startedPhones = channel.startedPhones.filter { eligibleIDs.contains($0.key) }

        guard let desired else {
            guard !channel.startedPhones.isEmpty else {
                after.lastContent = nil
                return Plan(starts: [], broadcast: nil, channel: after)
            }
            after.startedPhones = [:]
            after.lastContent = nil
            return Plan(starts: [], broadcast: .end(channel.lastContent), channel: after)
        }

        let starts = eligible.filter { phone in
            guard let started = after.startedPhones[phone.deviceID] else { return true }
            return (phone.mirrorEndedAt ?? .distantPast) > started
        }
        let startingIDs = Set(starts.map(\.deviceID))
        let alreadyUp = after.startedPhones.keys.contains { !startingIDs.contains($0) }
        let broadcast: Broadcast? = alreadyUp && desired != channel.lastContent ? .update(desired) : nil

        for phone in starts { after.startedPhones[phone.deviceID] = now }
        if !starts.isEmpty || broadcast != nil { after.lastContent = desired }
        return Plan(starts: starts, broadcast: broadcast, channel: after)
    }
}

// MARK: - APNs payloads

/// The `aps` bodies of Live Activity pushes.
public enum APNsPayload {

    /// The `attributes-type` a push-to-start names: the Swift type of the activity's attributes.
    public static let attributesType = "PomodoroActivityAttributes"

    /// A push-to-start. `attributes` marks the activity as a mirror, so the iPhone app never treats it
    /// as its own; `input-push-channel` subscribes it to the broadcast channel.
    public static func start(content: MirrorContent, timestamp: Int, channelID: String, alertTitle: String, alertBody: String) throws -> Data {
        var aps: [String: Any] = [
            "timestamp": timestamp,
            "event": "start",
            "content-state": try contentState(content),
            "attributes-type": attributesType,
            "attributes": ["mirrorSource": "mac"],
            "input-push-channel": channelID,
            "alert": ["title": alertTitle, "body": alertBody]
        ]
        if let stale = MirrorContentBuilder.staleDate(for: content) {
            aps["stale-date"] = Int(stale.timeIntervalSince1970)
        }
        return try serialize(aps)
    }

    public static func update(content: MirrorContent, timestamp: Int) throws -> Data {
        var aps: [String: Any] = [
            "timestamp": timestamp,
            "event": "update",
            "content-state": try contentState(content)
        ]
        if let stale = MirrorContentBuilder.staleDate(for: content) {
            aps["stale-date"] = Int(stale.timeIntervalSince1970)
        }
        return try serialize(aps)
    }

    /// Ends the activity and takes it off the Lock Screen at once.
    public static func end(content: MirrorContent?, timestamp: Int) throws -> Data {
        var aps: [String: Any] = [
            "timestamp": timestamp,
            "event": "end",
            "dismissal-date": timestamp
        ]
        if let content { aps["content-state"] = try contentState(content) }
        return try serialize(aps)
    }

    /// The content as the JSON object ActivityKit decodes into `ContentState`.
    public static func contentState(_ content: MirrorContent) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(content))
    }

    private static func serialize(_ aps: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["aps": aps], options: [.sortedKeys])
    }
}
