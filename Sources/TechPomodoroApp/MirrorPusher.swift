import AppKit
import Combine
import Foundation
import TechPomodoroCore
import TechPomodoroSync
import UniformTypeIdentifiers

/// Mirrors this Mac's timer onto the iPhone's Live Activity, display only.
///
/// On every change the iPhone must hear about (start, pause, resume, skip, phase boundary, stop, a
/// schedule change) it writes this Mac's timer to CloudKit, reads back the iPhones' push-to-start
/// tokens, the other Macs' timers and the broadcast channel, lets `MirrorArbiter` pick the Mac timer
/// to show, and lets `MirrorPushPlanner` decide the pushes. Never per tick: the countdown runs on the
/// phone. Changes arriving while a run is out collapse into one run with the newest state.
@MainActor
final class MirrorPusher: ObservableObject {

    enum Status: Equatable {
        case off
        case unavailable(String)
        case needsKey
        case noPhone
        case ready
        case pushed(Date)
        case error(String)

        var label: String {
            switch self {
            case .off: return "Off"
            case .unavailable(let why): return why
            case .needsKey: return "Import your APNs key (.p8) to push to the iPhone"
            case .noPhone: return "No iPhone yet: open Pomodoro on the iPhone with Show Mac timer on"
            case .ready: return "Mirroring to iPhone · ready"
            case .pushed(let date):
                return "Mirroring to iPhone · last push \(date.formatted(date: .omitted, time: .shortened))"
            case .error(let message): return message
            }
        }

        var isProblem: Bool {
            switch self {
            case .unavailable, .needsKey, .error: return true
            default: return false
            }
        }
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var credentials: APNsCredentials?

    private let store = MirrorCloudStore()
    private let apns = APNsClient()
    private let deviceID: String
    private let deviceName: String

    private var enabled = false
    private var lastKey: MirrorChangeKey?
    /// The newest timer not yet pushed; a run in flight picks it up when it finishes.
    private var pending: MirrorTimer?
    private var worker: Task<Void, Never>?
    /// The newest timer handed to a run, retried after a failure so the iPhone can't stay behind
    /// until the next change (which may be most of a phase away).
    private var latest: MirrorTimer?
    private var retryTask: Task<Void, Never>?
    private var retryDelay: TimeInterval = 15

    init(defaults: UserDefaults = .standard) {
        if let id = defaults.string(forKey: "mirror.deviceID") {
            deviceID = id
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: "mirror.deviceID")
        }
        deviceName = Host.current().localizedName ?? "Mac"
        credentials = APNsKeychain.load()
    }

    // MARK: - Driven by AppController

    /// Turns mirroring on or off to match the per-device switch. Turning it off publishes this Mac as
    /// idle first, so another Mac's timer takes over or the Live Activity ends.
    func setEnabled(_ on: Bool, state: PomodoroState, at now: Date) {
        guard MirrorCloudStore.isAvailable else {
            status = on ? .unavailable("Not available in this build (no iCloud entitlement)") : .off
            return
        }
        if on {
            guard !enabled else { return }
            enabled = true
            lastKey = nil
            stateDidChange(state, at: now)
        } else {
            guard enabled else { return }
            enqueue(MirrorTimer(deviceID: deviceID, name: deviceName, activity: .idle, changedAt: now, content: nil))
            enabled = false
            lastKey = nil
        }
    }

    /// Called after every reduction; does nothing unless something the iPhone shows has changed.
    func stateDidChange(_ state: PomodoroState, at now: Date) {
        guard enabled else { return }
        let key = MirrorChangeKey(state)
        guard key != lastKey else { return }
        lastKey = key
        enqueue(MirrorTimer(
            deviceID: deviceID,
            name: deviceName,
            activity: state.activity,
            changedAt: now,
            content: MirrorContentBuilder.content(for: state, at: now)
        ))
    }

    /// On quit: this Mac's timer stops with the app, so tell the iPhone. Bounded by the caller.
    func shutdown(at now: Date) async {
        guard enabled else { return }
        enqueue(MirrorTimer(deviceID: deviceID, name: deviceName, activity: .idle, changedAt: now, content: nil))
        await worker?.value
    }

    private func enqueue(_ timer: MirrorTimer) {
        pending = timer
        latest = timer
        retryTask?.cancel()
        retryTask = nil
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, let next = self.pending {
                self.pending = nil
                await self.run(next)
            }
            self?.worker = nil
        }
    }

    // MARK: - One run

    private func run(_ own: MirrorTimer) async {
        let now = own.changedAt
        do {
            try await store.save(timer: own)
            let snapshot = try await store.fetchAll()
            let timers = snapshot.timers.filter { $0.deviceID != deviceID } + [own]
            let desired = MirrorArbiter.displayed(timers, now: now)

            // Environments with an iPhone to push to, plus any with an activity still to end.
            var environments = Set(snapshot.phones.filter(\.canReceive).map(\.environment))
            environments.formUnion(snapshot.channels.values.filter { !$0.startedPhones.isEmpty }.map(\.environment))
            guard !environments.isEmpty else {
                finish(.noPhone)
                return
            }
            guard let credentials else {
                finish(.needsKey)
                return
            }

            var pushed = false
            for environment in environments.sorted(by: { $0.rawValue < $1.rawValue }) {
                pushed = try await push(desired: desired, environment: environment, snapshot: snapshot, credentials: credentials, now: now) || pushed
            }
            finish(pushed ? .pushed(Date()) : (status.isPushed ? status : .ready))
            retryDelay = 15
        } catch {
            NSLog("tech-pomodoro: mirror push failed: \(Self.describe(error))")
            finish(.error(Self.describe(error)))
            scheduleRetry(of: own)
        }
    }

    /// Tries the same timer again, backing off from 15 s to 2 min, unless something newer has been
    /// queued by then. The content holds absolute dates, so a late push still shows the right time.
    private func scheduleRetry(of timer: MirrorTimer) {
        guard enabled || timer.activity == .idle else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 120)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.latest == timer, self.pending == nil else { return }
            self.enqueue(timer)
        }
    }

    /// Returns true when anything went to APNs.
    private func push(desired: MirrorContent?, environment: APNsEnvironment, snapshot: MirrorSnapshot, credentials: APNsCredentials, now: Date) async throws -> Bool {
        var channel: MirrorChannel
        if let existing = snapshot.channels[environment] {
            channel = existing
        } else {
            // Nothing to end on a channel that never existed.
            guard desired != nil else { return false }
            channel = try await newChannel(environment, credentials: credentials)
        }

        var plan = MirrorPushPlanner.plan(desired: desired, channel: channel, phones: snapshot.phones, now: now)
        if plan.isEmpty {
            if plan.channel != channel { try await store.save(channel: plan.channel) }
            return false
        }

        var after = plan.channel
        let timestamp = channel.nextTimestamp(at: now)
        var firstError: Error?

        if let broadcast = plan.broadcast {
            do {
                try await apns.broadcast(channelID: channel.channelID, environment: environment, payload: payload(broadcast, timestamp: timestamp), credentials: credentials)
            } catch let error as APNsError where error.isBadChannel {
                // Apple no longer knows the channel. Every activity on it is orphaned, so start over
                // on a fresh one: a start for every iPhone, or nothing at all when going idle.
                channel = try await newChannel(environment, credentials: credentials, replacing: true)
                plan = MirrorPushPlanner.plan(desired: desired, channel: channel, phones: snapshot.phones, now: now)
                after = plan.channel
            } catch {
                firstError = error
                after = channel
            }
        }

        for phone in plan.starts {
            guard let token = phone.pushToStartToken, let content = desired else { continue }
            do {
                let body = try APNsPayload.start(
                    content: content,
                    timestamp: timestamp,
                    channelID: channel.channelID,
                    alertTitle: content.isPaused ? "Paused — \(content.phaseTitle)" : content.phaseTitle,
                    alertBody: "Mirroring the timer on \(content.mirroredFrom ?? deviceName)"
                )
                try await apns.start(token: token, environment: environment, payload: body, credentials: credentials)
            } catch {
                // Not started: leave it to be tried again on the next change.
                after.startedPhones[phone.deviceID] = channel.startedPhones[phone.deviceID]
                firstError = firstError ?? error
            }
        }

        after.lastTimestamp = timestamp
        try await store.save(channel: after)
        if let firstError { throw firstError }
        return true
    }

    private func newChannel(_ environment: APNsEnvironment, credentials: APNsCredentials, replacing: Bool = false) async throws -> MirrorChannel {
        let id = try await apns.createChannel(environment: environment, credentials: credentials)
        let fresh = MirrorChannel(environment: environment, channelID: id)
        if replacing {
            try await store.save(channel: fresh)
            return fresh
        }
        return try await store.claim(channel: fresh)
    }

    private func payload(_ broadcast: MirrorPushPlanner.Broadcast, timestamp: Int) throws -> Data {
        switch broadcast {
        case .update(let content): return try APNsPayload.update(content: content, timestamp: timestamp)
        case .end(let content): return try APNsPayload.end(content: content, timestamp: timestamp)
        }
    }

    private func finish(_ newStatus: Status) {
        // A run finishing after the switch went off must not overwrite `.off`.
        status = enabled ? newStatus : .off
    }

    private static func describe(_ error: Error) -> String {
        if let apns = error as? APNsError { return apns.localizedDescription }
        return "Mirror error: \(error.localizedDescription)"
    }

    // MARK: - APNs key

    /// Asks for the .p8 file, checks it parses, and stores it in the Keychain with its Key ID (from the
    /// file name) and the Team ID this app is signed with. Either can be corrected afterwards.
    func importKey() {
        let panel = NSOpenPanel()
        panel.title = "Choose your APNs auth key"
        panel.message = "The AuthKey_XXXXXXXXXX.p8 file from developer.apple.com → Keys. It is stored in your Keychain, never in the app's files."
        panel.allowedContentTypes = [UTType(filenameExtension: "p8") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let pem = try String(contentsOf: url, encoding: .utf8)
            let candidate = APNsCredentials(
                privateKeyPEM: pem,
                keyID: APNsCredentials.keyID(fromFileName: url.lastPathComponent) ?? credentials?.keyID ?? "",
                teamID: credentials?.teamID ?? APNsCredentials.signingTeamID() ?? ""
            )
            _ = try candidate.signingKey()
            try store(candidate)
        } catch {
            status = .error("Could not import the key: \(error.localizedDescription)")
        }
    }

    func update(keyID: String? = nil, teamID: String? = nil) {
        guard var updated = credentials else { return }
        if let keyID { updated.keyID = keyID.trimmingCharacters(in: .whitespaces).uppercased() }
        if let teamID { updated.teamID = teamID.trimmingCharacters(in: .whitespaces).uppercased() }
        guard updated != credentials else { return }
        do { try store(updated) } catch { status = .error(error.localizedDescription) }
    }

    func removeKey() {
        APNsKeychain.delete()
        credentials = nil
        Task { await apns.resetToken() }
        if enabled { status = .needsKey }
    }

    private func store(_ updated: APNsCredentials) throws {
        try APNsKeychain.save(updated)
        credentials = updated
        Task { await apns.resetToken() }
        if enabled {
            status = .ready
            // Push the current state now that there is a key to push with.
            lastKey = nil
            onForceRepush?()
        }
    }

    /// Set by `AppController`, which re-sends the current state.
    var onForceRepush: (() -> Void)?
}

private extension MirrorPusher.Status {
    var isPushed: Bool {
        if case .pushed = self { return true }
        return false
    }
}
