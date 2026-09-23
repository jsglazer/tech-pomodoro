import Foundation

/// One upcoming phase boundary: the instant it falls, the alert it raises, and what begins there.
public struct PhaseBoundary: Sendable, Equatable {
    public let fireAt: Date
    public let kind: AlertKind
    /// The phase that starts at `fireAt`. Nil for `sessionComplete`, where the timer goes idle.
    public let nextPhase: Phase?
    /// When the phase that starts at `fireAt` will itself end. Nil for `sessionComplete`.
    public let nextPhaseEndsAt: Date?

    public init(fireAt: Date, kind: AlertKind, nextPhase: Phase?, nextPhaseEndsAt: Date?) {
        self.fireAt = fireAt
        self.kind = kind
        self.nextPhase = nextPhase
        self.nextPhaseEndsAt = nextPhaseEndsAt
    }
}

/// Lays out the boundaries a running timer will cross, so a shell that may be suspended can hand
/// them to the OS ahead of time (iOS local notifications) instead of waking to find them.
///
/// It adds no schedule logic of its own: the chain is produced by reducing `.tick` at each phase's
/// own `phaseEndsAt` on a scratch copy of the state, so every boundary is exactly the one the reducer
/// will reach, counters, long breaks, session rests and `repeatSession` included.
public enum BoundaryPlanner {

    /// iOS keeps at most 64 pending local notifications per app; staying under that leaves headroom.
    public static let defaultLimit = 60
    /// `repeatSession` makes the chain endless, so planning stops a day out and is redone on resume.
    public static let defaultHorizon: TimeInterval = 24 * 60 * 60

    /// Boundaries strictly after `now`, in order, up to `limit` of them and no further than
    /// `horizon` past `now`. Empty unless the timer is running: a paused or idle timer has no
    /// boundaries until it is resumed.
    public static func upcoming(
        from state: PomodoroState,
        now: Date,
        limit: Int = defaultLimit,
        horizon: TimeInterval = defaultHorizon
    ) -> [PhaseBoundary] {
        guard state.activity == .running, limit > 0 else { return [] }

        let cutoff = now.addingTimeInterval(horizon)
        var s = state
        var boundaries: [PhaseBoundary] = []

        while boundaries.count < limit, s.activity == .running, let end = s.phaseEndsAt, end <= cutoff {
            s = PomodoroReducer.reduce(s, .tick, end)
            // A boundary already behind `now` belongs to a catch-up the shell has not reduced yet;
            // it is walked through, never scheduled.
            guard end > now, let kind = alertKind(in: s) else { continue }
            let running = s.activity == .running
            boundaries.append(
                PhaseBoundary(
                    fireAt: end,
                    kind: kind,
                    nextPhase: running ? s.phase : nil,
                    nextPhaseEndsAt: running ? s.phaseEndsAt : nil
                )
            )
        }
        return boundaries
    }

    private static func alertKind(in state: PomodoroState) -> AlertKind? {
        for effect in state.pendingEffects {
            if case .alert(let kind) = effect { return kind }
        }
        return nil
    }
}
