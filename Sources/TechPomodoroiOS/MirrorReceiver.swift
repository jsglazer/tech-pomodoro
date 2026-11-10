import ActivityKit
import Combine
import Foundation
import TechPomodoroCore
import TechPomodoroSync
import UIKit

/// The iPhone's half of mirroring between it and the Macs (display only, both ways).
///
/// - Publishes this iPhone's own timer (`iphone-<id>`) on every change, so a Mac can show it in its
///   menu bar and push its phase boundaries to this iPhone's own Live Activity, on the channel a Mac
///   made for it (`ownchannel-<id>`), which this reads back.
/// - Publishes this iPhone's push-to-start token, its APNs environment and its "Mirror timer with Mac" switch
///   to CloudKit, where the Macs read it just before pushing.
/// - Watches the activities the Macs start by push, and notes in the same record when one ends or is
///   swiped away, so the next Mac change starts a fresh one.
/// - Works out which Mac timer to show in the app: the mirrored activity's own content when one is up
///   (it is exactly what the Mac pushed), otherwise the Mac timers in CloudKit, read on foreground and
///   every 20 seconds while the app is open.
@MainActor
final class MirrorReceiver: ObservableObject {

    /// The Mac timer the app shows in place of its own; nil when no Mac timer is active or mirroring
    /// is off on this iPhone.
    @Published private(set) var displayed: MirrorContent?
    /// This iPhone's own broadcast channel, made by a Mac; nil until one has. Kept across launches so
    /// a timer started from a Live Activity button in a background launch still uses it.
    @Published private(set) var ownChannelID: String?

    private let store = MirrorCloudStore()
    private let defaults: UserDefaults
    private let deviceID: String
    private let environment = APNsEnvironment.current

    private var enabled = false
    private var pushToStartToken: String?
    private var mirrorEndedAt: Date?
    private var lastSaved: MirrorPhone?

    private var tokenTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var watched: [String: [Task<Void, Never>]] = [:]
    /// Content of the mirrored activity on screen, by activity id.
    private var activityContent: [String: MirrorContent] = [:]
    /// When each mirrored activity's content last changed, to tell a missed push from a stale read.
    private var activityReceivedAt: [String: Date] = [:]
    private var cloudTimers: [MirrorTimer] = []
    /// This environment's broadcast channel as last read from CloudKit.
    private var channelID: String?
    private var foreground = false
    private var pollTimer: Timer?

    /// What of this iPhone's own timer was last handed to CloudKit, so a plain tick writes nothing.
    private var lastOwnKey: MirrorChangeKey?
    /// The own-timer writes in flight, chained so the newest lands last.
    private var ownWork: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let id = defaults.string(forKey: "mirror.deviceID") {
            deviceID = id
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: "mirror.deviceID")
        }
        pushToStartToken = defaults.string(forKey: "mirror.pushToStartToken")
        ownChannelID = defaults.string(forKey: "mirror.ownChannelID")
    }

    // MARK: - Switch

    /// Starts or stops everything to match the "Mirror timer with Mac" switch. Cheap enough to run in a
    /// background launch, where it is what lets a fresh push-to-start token reach the Macs.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            startObserving()
        } else {
            stopObserving()
            // Mirrored activities are display only; with the switch off they go at once.
            for activity in Activity<PomodoroActivityAttributes>.activities where activity.attributes.isMirror {
                nonisolated(unsafe) let activity = activity
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
            activityContent = [:]
            cloudTimers = []
            recompute()
            // The Macs stop showing this iPhone's timer.
            lastOwnKey = nil
            saveOwn(MirrorTimer(deviceID: deviceID, name: UIDevice.current.name, activity: .idle, changedAt: Date(), content: nil))
        }
        publishPhone()
    }

    // MARK: - This iPhone's own timer

    /// Called on every change to when this iPhone's next boundary falls. Writes the timer for the Macs
    /// only when something they show has changed. The full state goes with it: the iPhone is usually
    /// suspended at its boundaries, so the Macs run it forward themselves.
    func ownTimerChanged(_ state: PomodoroState, at now: Date) {
        guard enabled, MirrorCloudStore.isAvailable else { return }
        let key = MirrorChangeKey(state)
        guard key != lastOwnKey else { return }
        lastOwnKey = key
        let name = UIDevice.current.name
        saveOwn(MirrorTimer(
            deviceID: deviceID,
            name: name,
            activity: state.activity,
            changedAt: now,
            content: MirrorContentBuilder.content(for: state, at: now, mirroredFrom: name),
            state: state.activity == .idle ? nil : MirrorTimerState(state)
        ))
    }

    private func saveOwn(_ timer: MirrorTimer) {
        guard MirrorCloudStore.isAvailable else { return }
        let previous = ownWork
        ownWork = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await self.store.save(phoneTimer: timer)
            } catch {
                NSLog("tech-pomodoro: could not publish this iPhone's timer: \(error.localizedDescription)")
                // Written again on the next change.
                self.lastOwnKey = nil
            }
        }
    }

    /// Returns once the own-timer writes in flight have landed, for a background launch to await.
    func settle() async {
        await ownWork?.value
    }

    // MARK: - Foreground

    func sceneDidBecomeActive() {
        foreground = true
        guard enabled else { return }
        refreshFromCloud()
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFromCloud() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func sceneDidEnterBackground() {
        foreground = false
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Re-evaluated once a second by the controller's ticker, so a Mac that went quiet drops out.
    func tick() {
        recompute()
    }

    private func refreshFromCloud() {
        guard enabled, MirrorCloudStore.isAvailable else { return }
        Task {
            guard let snapshot = try? await store.fetchAll() else { return }
            cloudTimers = snapshot.timers
            channelID = snapshot.channels[environment]?.channelID
            ownChannelFetched(snapshot.ownChannels[deviceID])
            recompute()
            correctMissedPushes()
            restartMirrorIfMissing()
        }
    }

    private func ownChannelFetched(_ channel: MirrorChannel?) {
        // A channel made for the other APNs environment (a build switch) cannot reach this install.
        let id = channel?.environment == environment ? channel?.channelID : nil
        guard let id, id != ownChannelID else { return }
        ownChannelID = id
        defaults.set(id, forKey: "mirror.ownChannelID")
    }

    /// Brings an up mirrored activity in line with the Mac when CloudKit shows a change its push
    /// never delivered. Only runs while the app is open, but that is also when someone is looking.
    private func correctMissedPushes() {
        guard enabled else { return }
        let now = Date()
        for activity in Activity<PomodoroActivityAttributes>.activities where activity.attributes.isMirror {
            let id = activity.id
            guard let current = activityContent[id], let receivedAt = activityReceivedAt[id],
                  let fix = MirrorArbiter.correction(activityContent: current, receivedAt: receivedAt, timers: cloudTimers, now: now) else { continue }
            nonisolated(unsafe) let activity = activity
            switch fix {
            case .update(let content):
                NSLog("tech-pomodoro: mirrored activity missed a push; correcting from CloudKit")
                activityContentChanged(id: id, content)
                let staleDate = content.isPaused ? nil : content.phaseEndsAt.addingTimeInterval(90)
                Task { await activity.update(ActivityContent(state: .init(content), staleDate: staleDate)) }
            case .end:
                NSLog("tech-pomodoro: mirrored activity missed the Mac's stop; ending it")
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
        }
    }

    /// A Mac timer is active but no mirrored activity is up: it was swiped away, closed from the Mac's
    /// menu bar, or its push-to-start never arrived. The Mac only starts a new one on its next change
    /// (pause, skip, phase boundary), which can be most of a phase away. While the app is open it can
    /// start the activity itself, subscribed to the same broadcast channel so the Mac's later pushes
    /// still reach it. Clearing `mirrorEndedAt` tells the Macs not to push-to-start a second one.
    private func restartMirrorIfMissing() {
        guard enabled, foreground, let channelID,
              ActivityAuthorizationInfo().areActivitiesEnabled,
              !Activity<PomodoroActivityAttributes>.activities.contains(where: { $0.attributes.isMirror }),
              let content = MirrorArbiter.displayed(cloudTimers, now: Date()) else { return }
        let staleDate = content.isPaused ? nil : content.phaseEndsAt.addingTimeInterval(90)
        do {
            let activity = try Activity.request(
                attributes: PomodoroActivityAttributes(mirrorSource: "mac"),
                content: ActivityContent(state: .init(content), staleDate: staleDate),
                pushType: .channel(channelID)
            )
            watch(activity)
            mirrorEndedAt = nil
            publishPhone()
        } catch {
            NSLog("tech-pomodoro: could not restart the mirrored activity: \(error.localizedDescription)")
        }
    }

    private func recompute() {
        let now = Date()
        var shown: MirrorContent?
        if enabled {
            // A mirrored activity carries the Mac's latest push, ahead of CloudKit.
            let live = activityContent.values.filter { content in
                MirrorArbiter.isLive(content, changedAt: now, now: now)
            }
            shown = live.max { $0.phaseStartedAt < $1.phaseStartedAt } ?? MirrorArbiter.displayed(cloudTimers, now: now)
        }
        if shown != displayed { displayed = shown }
    }

    // MARK: - ActivityKit

    private func startObserving() {
        tokenTask = Task { [weak self] in
            for await data in Activity<PomodoroActivityAttributes>.pushToStartTokenUpdates {
                self?.pushToStartTokenChanged(data.hexString)
            }
        }
        activityTask = Task { [weak self] in
            for await activity in Activity<PomodoroActivityAttributes>.activityUpdates where activity.attributes.isMirror {
                nonisolated(unsafe) let activity = activity
                self?.endOtherMirrors(keeping: activity.id)
                self?.watch(activity)
            }
        }
        for activity in Activity<PomodoroActivityAttributes>.activities where activity.attributes.isMirror {
            watch(activity)
        }
    }

    private func stopObserving() {
        tokenTask?.cancel()
        activityTask?.cancel()
        tokenTask = nil
        activityTask = nil
        watched.values.flatMap { $0 }.forEach { $0.cancel() }
        watched = [:]
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pushToStartTokenChanged(_ token: String) {
        guard token != pushToStartToken else { return }
        pushToStartToken = token
        defaults.set(token, forKey: "mirror.pushToStartToken")
        publishPhone()
    }

    private func watch(_ activity: Activity<PomodoroActivityAttributes>) {
        let id = activity.id
        guard watched[id] == nil else { return }
        nonisolated(unsafe) let activity = activity
        activityContent[id] = MirrorContent(activity.content.state)
        // Unknown how old this content is (the app may have been closed when it arrived), so any
        // Mac change in CloudKit that disagrees with it wins.
        activityReceivedAt[id] = .distantPast
        recompute()
        let contentTask = Task { [weak self] in
            for await content in activity.contentUpdates {
                self?.activityContentChanged(id: id, MirrorContent(content.state))
            }
        }
        let stateTask = Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                self?.activityEnded(id: id)
                return
            }
        }
        watched[id] = [contentTask, stateTask]
    }

    /// Only one mirrored activity at a time: the newest stays, so a Mac start that crosses with one the
    /// app started itself doesn't leave two on the Lock Screen.
    private func endOtherMirrors(keeping id: String) {
        for other in Activity<PomodoroActivityAttributes>.activities where other.attributes.isMirror && other.id != id {
            nonisolated(unsafe) let other = other
            activityContent[other.id] = nil
            activityReceivedAt[other.id] = nil
            watched[other.id]?.forEach { $0.cancel() }
            watched[other.id] = nil
            Task { await other.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func activityContentChanged(id: String, _ content: MirrorContent) {
        activityContent[id] = content
        activityReceivedAt[id] = Date()
        recompute()
    }

    /// Ended by the Mac or swiped away here: either way nothing is on screen for this iPhone now.
    private func activityEnded(id: String) {
        activityContent[id] = nil
        activityReceivedAt[id] = nil
        watched[id]?.forEach { $0.cancel() }
        watched[id] = nil
        mirrorEndedAt = Date()
        recompute()
        publishPhone()
        // The Mac may have gone idle, or another Mac may now be the one to show.
        refreshFromCloud()
    }

    // MARK: - CloudKit

    private func publishPhone() {
        guard MirrorCloudStore.isAvailable else { return }
        let phone = MirrorPhone(
            deviceID: deviceID,
            name: UIDevice.current.name,
            mirroringEnabled: enabled,
            pushToStartToken: enabled ? pushToStartToken : nil,
            environment: environment,
            mirrorEndedAt: mirrorEndedAt,
            updatedAt: Date()
        )
        var comparable = phone
        comparable.updatedAt = lastSaved?.updatedAt ?? phone.updatedAt
        guard comparable != lastSaved else { return }
        Task {
            do {
                try await store.save(phone: phone)
                lastSaved = phone
            } catch {
                NSLog("tech-pomodoro: could not publish the mirror token: \(error.localizedDescription)")
            }
        }
    }
}

extension MirrorContent {
    init(_ state: PomodoroActivityAttributes.ContentState) {
        self.init(
            phaseTitle: state.phaseTitle,
            isPaused: state.isPaused,
            phaseStartedAt: state.phaseStartedAt,
            phaseEndsAt: state.phaseEndsAt,
            pausedRemaining: state.pausedRemaining,
            progressLine: state.progressLine,
            upcoming: state.upcoming.map { MirrorUpcoming(title: $0.title, startsAt: $0.startsAt) },
            tintHex: state.tintHex,
            mirroredFrom: state.mirroredFrom,
            nextPhase: state.nextPhase.map {
                MirrorNextPhase(title: $0.title, startsAt: $0.startsAt, endsAt: $0.endsAt, progressLine: $0.progressLine, tintHex: $0.tintHex)
            }
        )
    }
}

extension PomodoroActivityAttributes.ContentState {
    init(_ content: MirrorContent) {
        self.init(
            phaseTitle: content.phaseTitle,
            isPaused: content.isPaused,
            phaseStartedAt: content.phaseStartedAt,
            phaseEndsAt: content.phaseEndsAt,
            pausedRemaining: content.pausedRemaining,
            progressLine: content.progressLine,
            upcoming: content.upcoming.map { .init(title: $0.title, startsAt: $0.startsAt) },
            tintHex: content.tintHex,
            mirroredFrom: content.mirroredFrom,
            nextPhase: content.nextPhase.map {
                .init(title: $0.title, startsAt: $0.startsAt, endsAt: $0.endsAt, progressLine: $0.progressLine, tintHex: $0.tintHex)
            }
        )
    }
}

extension APNsEnvironment {
    /// Which APNs host this build's tokens belong to, read from the `aps-environment` entitlement in
    /// the embedded provisioning profile. A development install (`MakeiOSDeploy.sh`) gets sandbox
    /// tokens; an App Store or TestFlight build has no embedded profile and uses production.
    static let current: APNsEnvironment = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .isoLatin1),
              let start = raw.range(of: "<?xml"),
              let end = raw.range(of: "</plist>") else { return .production }
        let plistText = String(raw[start.lowerBound..<end.upperBound])
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(plistText.utf8), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let aps = entitlements["aps-environment"] as? String else { return .production }
        return aps == "development" ? .development : .production
    }()
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
