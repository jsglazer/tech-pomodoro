import Foundation
import TechPomodoroCore

/// The running timer, saved to disk so it survives iOS terminating the app in the background.
///
/// The Mac app never persists in-progress state because it is never killed while suspended. iOS kills
/// suspended apps routinely, while the pre-scheduled notifications keep firing, so relaunching into an
/// idle timer would contradict the alerts the user is still receiving. This DTO lives in the shell and
/// copies `PomodoroState`'s stored fields, so the core is unchanged. Settings are not duplicated here:
/// they have their own store and are re-attached on restore.
struct SessionSnapshot: Codable, Equatable {
    var activity: String
    var phase: Phase
    var phaseEndsAt: Date?
    var remainingWhenPaused: TimeInterval?
    var phaseStartedAt: Date?
    var phaseDuration: TimeInterval
    var completedRepsInCycle: Int
    var completedCyclesInSession: Int
    var completedSessions: Int

    init(_ state: PomodoroState) {
        activity = state.activity.rawValue
        phase = state.phase
        phaseEndsAt = state.phaseEndsAt
        remainingWhenPaused = state.remainingWhenPaused
        phaseStartedAt = state.phaseStartedAt
        phaseDuration = state.phaseDuration
        completedRepsInCycle = state.completedRepsInCycle
        completedCyclesInSession = state.completedCyclesInSession
        completedSessions = state.completedSessions
    }

    /// The state this snapshot describes, under `settings`. Nil when the snapshot is inconsistent —
    /// a running timer with no end, say — so a corrupt file starts idle rather than stuck.
    func restore(settings: PomodoroSettings) -> PomodoroState? {
        guard let activity = PomodoroState.Activity(rawValue: activity) else { return nil }
        switch activity {
        case .running where phaseEndsAt == nil: return nil
        case .paused where remainingWhenPaused == nil: return nil
        default: break
        }
        var state = PomodoroState(settings: settings)
        state.activity = activity
        state.phase = phase
        state.phaseEndsAt = phaseEndsAt
        state.remainingWhenPaused = remainingWhenPaused
        state.phaseStartedAt = phaseStartedAt
        state.phaseDuration = phaseDuration
        state.completedRepsInCycle = completedRepsInCycle
        state.completedCyclesInSession = completedCyclesInSession
        state.completedSessions = completedSessions
        return state
    }
}

/// `session.json` beside the interval history in Application Support. Written only while the timer is
/// running or paused, and removed the moment it goes idle.
struct SessionSnapshotStore {
    let url: URL

    static func applicationSupportURL() throws -> URL {
        try FileIntervalStore.applicationSupportURL()
            .deletingLastPathComponent()
            .appendingPathComponent("session.json", isDirectory: false)
    }

    func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(SessionSnapshot.self, from: data)
    }

    func save(_ state: PomodoroState) {
        guard state.activity != .idle else {
            clear()
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.encoder.encode(SessionSnapshot(state)).write(to: url, options: .atomic)
        } catch {
            NSLog("tech-pomodoro: could not save the running session: \(error.localizedDescription)")
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    // Default date coding (seconds as a `Double`), not ISO 8601: `phaseEndsAt` must round-trip to the
    // sub-second, or a restored phase would end a fraction early and drift from its notification.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
