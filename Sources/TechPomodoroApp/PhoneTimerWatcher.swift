import Combine
import Foundation
import TechPomodoroCore
import TechPomodoroSync

/// The Mac's half of mirroring an iPhone's own timer: the counterpart of the iPhone's `MirrorReceiver`.
///
/// - Reads the iPhones' timers (`iphone-<id>`) from CloudKit every 15 seconds while mirroring is on,
///   and lets `PhoneTimerArbiter` pick the one to show. `AppController` shows it in the menu bar and
///   the popover, display only, whenever this Mac's own timer is idle.
/// - Runs that timer forward once a second with the reducer, so its countdown and its phase changes
///   land on time here even though the iPhone, suspended, wrote nothing at its boundaries. The alerts
///   those crossings raise go back to `AppController` to sound.
/// - Pushes each such boundary to the iPhone's own Live Activity, over a broadcast channel this Mac
///   makes for that iPhone (`ownchannel-<id>`): the suspended iPhone app cannot move its activity on,
///   so without this it sits at 00:00 until opened. The channel records the last boundary pushed, so
///   two awake Macs push it once.
@MainActor
final class PhoneTimerWatcher {

    struct Display: Equatable {
        let deviceID: String
        let phoneName: String
        /// Caught up to the last tick.
        let state: PomodoroState
    }

    /// The iPhone timer being shown, or nil.
    private(set) var display: Display?

    static let pollSeconds: TimeInterval = 15
    /// A failed channel creation is not tried again for this long; the poll would otherwise hammer APNs.
    static let channelRetrySeconds: TimeInterval = 10 * 60

    private let store = MirrorCloudStore()
    private let apns: APNsClient
    private let credentials: () -> APNsCredentials?

    private var enabled = false
    private var pollTimer: Timer?
    private var fetchInFlight = false
    private var snapshot = MirrorSnapshot()
    /// The record being shown and the timer as run forward from it.
    private var tracked: (timer: MirrorTimer, state: PomodoroState)?
    private var pushWork: Task<Void, Never>?
    private var channelFailures: [String: Date] = [:]
    private var creatingChannels: Set<String> = []

    init(apns: APNsClient, credentials: @escaping () -> APNsCredentials?) {
        self.apns = apns
        self.credentials = credentials
    }

    // MARK: - Driven by AppController

    func setEnabled(_ on: Bool) {
        guard MirrorCloudStore.isAvailable, on != enabled else { return }
        enabled = on
        pollTimer?.invalidate()
        pollTimer = nil
        if on {
            let timer = Timer(timeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshNow() }
            }
            timer.tolerance = 3
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
            refreshNow()
        } else {
            snapshot = MirrorSnapshot()
            tracked = nil
            display = nil
        }
    }

    /// Reads CloudKit now: on the poll, on wake, and as the popover opens.
    func refreshNow() {
        guard enabled, !fetchInFlight else { return }
        fetchInFlight = true
        Task {
            defer { fetchInFlight = false }
            do {
                let fresh = try await store.fetchAll()
                guard enabled else { return }
                snapshot = fresh
                ensureOwnChannels()
            } catch {
                NSLog("tech-pomodoro: could not read the iPhone's timer: \(error.localizedDescription)")
            }
        }
    }

    /// Run once a second. Moves the shown iPhone timer on to `now` and returns the alerts its
    /// boundaries raised on the way, for the caller to sound when it is the timer on show.
    func tick(settings: PomodoroSettings, at now: Date) -> [PomodoroEffect] {
        guard enabled else { return [] }
        var effects: [PomodoroEffect] = []

        // The same record as before: step it forward, and push any boundary it crossed.
        if let current = tracked,
           let record = snapshot.phoneTimers.first(where: { $0.deviceID == current.timer.deviceID }),
           record.changedAt == current.timer.changedAt {
            let before = current.state
            let stepped = PomodoroReducer.reduce(before, .tick, now)
            effects = stepped.pendingEffects
            if !effects.isEmpty {
                // The last boundary crossed: where the phase now running began, or the session's end.
                let boundary = stepped.activity == .running ? (stepped.phaseStartedAt ?? now) : (before.phaseEndsAt ?? now)
                pushBoundary(phoneID: record.deviceID, state: stepped, boundary: boundary)
            }
            tracked = stepped.activity == .idle ? nil : (record, stepped)
        } else {
            tracked = nil
        }

        // A newer record, another iPhone, or nothing tracked yet: take what the arbiter picks. A record
        // the iPhone just wrote is one it is awake for, so it has updated its own activity itself.
        if let shown = PhoneTimerArbiter.shown(snapshot.phoneTimers, settings: settings, now: now) {
            if tracked == nil || tracked?.timer != shown.timer {
                if tracked != nil { effects = [] }
                tracked = (shown.timer, shown.state)
            }
        } else {
            // Gone idle, gone out of date, or switched off on the iPhone.
            tracked = nil
        }

        let next = tracked.map { Display(deviceID: $0.timer.deviceID, phoneName: $0.timer.name, state: $0.state) }
        if next != display { display = next }
        return effects
    }

    // MARK: - Pushing the iPhone's boundaries

    private func pushBoundary(phoneID: String, state: PomodoroState, boundary: Date) {
        guard let credentials = credentials() else { return }
        let desired = MirrorContentBuilder.content(for: state, at: boundary)
        let previous = pushWork
        pushWork = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await self.push(desired: desired, phoneID: phoneID, boundary: boundary, credentials: credentials)
            } catch {
                NSLog("tech-pomodoro: could not push the iPhone's phase change: \(error.localizedDescription)")
            }
        }
    }

    private func push(desired: MirrorContent?, phoneID: String, boundary: Date, credentials: APNsCredentials) async throws {
        // Read fresh: another Mac may have pushed this boundary, or the iPhone woke and moved on itself.
        let fresh = try await store.fetchAll()
        guard let channel = fresh.ownChannels[phoneID] else { return }
        if let record = fresh.phoneTimers.first(where: { $0.deviceID == phoneID }), record.changedAt >= boundary {
            return
        }
        guard let broadcast = MirrorPushPlanner.ownBroadcast(desired: desired, boundary: boundary, channel: channel) else { return }

        let timestamp = channel.nextTimestamp(at: Date())
        let payload: Data
        switch broadcast {
        case .update(let content):
            // Stale right at the phase end, so the activity moves on by itself if no push follows.
            payload = try APNsPayload.update(content: content, timestamp: timestamp, staleGrace: 0)
        case .end(let content):
            payload = try APNsPayload.end(content: content, timestamp: timestamp)
        }

        do {
            try await apns.broadcast(channelID: channel.channelID, environment: channel.environment, payload: payload, credentials: credentials)
        } catch let error as APNsError where error.isBadChannel {
            // Apple no longer knows it. Make a new one; the iPhone moves its activity onto it when next opened.
            let id = try await apns.createChannel(environment: channel.environment, credentials: credentials)
            let replacement = MirrorChannel(environment: channel.environment, channelID: id)
            try await store.save(ownChannel: replacement, phoneID: phoneID)
            snapshot.ownChannels[phoneID] = replacement
            return
        }

        var after = channel
        after.lastBoundary = boundary
        after.lastContent = desired
        after.lastTimestamp = timestamp
        try await store.save(ownChannel: after, phoneID: phoneID)
        snapshot.ownChannels[phoneID] = after
    }

    /// Every iPhone with mirroring on gets a channel for its own activity, made once and kept. Only a
    /// Mac can make one: it takes the APNs key.
    private func ensureOwnChannels() {
        guard let credentials = credentials() else { return }
        let now = Date()
        for phone in snapshot.phones where phone.mirroringEnabled {
            let existing = snapshot.ownChannels[phone.deviceID]
            guard existing?.environment != phone.environment,
                  !creatingChannels.contains(phone.deviceID),
                  now.timeIntervalSince(channelFailures[phone.deviceID] ?? .distantPast) > Self.channelRetrySeconds else { continue }
            creatingChannels.insert(phone.deviceID)
            Task {
                defer { creatingChannels.remove(phone.deviceID) }
                do {
                    let id = try await apns.createChannel(environment: phone.environment, credentials: credentials)
                    let fresh = MirrorChannel(environment: phone.environment, channelID: id)
                    let kept: MirrorChannel
                    if existing == nil {
                        kept = try await store.claim(ownChannel: fresh, phoneID: phone.deviceID)
                    } else {
                        // Made for the other APNs environment (the iPhone build changed): replace it.
                        try await store.save(ownChannel: fresh, phoneID: phone.deviceID)
                        kept = fresh
                    }
                    snapshot.ownChannels[phone.deviceID] = kept
                } catch {
                    channelFailures[phone.deviceID] = Date()
                    NSLog("tech-pomodoro: could not make a channel for \(phone.name): \(error.localizedDescription)")
                }
            }
        }
    }
}
