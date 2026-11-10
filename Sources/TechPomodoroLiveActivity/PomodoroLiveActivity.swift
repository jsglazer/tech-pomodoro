import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct TechPomodoroWidgets: WidgetBundle {
    var body: some Widget {
        PomodoroLiveActivity()
    }
}

/// The lock screen banner and the Dynamic Island — the iOS stand-in for the Mac's menu bar item.
///
/// Every countdown here is `Text(timerInterval:)` or `ProgressView(timerInterval:)`, which the system
/// animates itself: no update from the app is needed while a phase runs. At a phase end nothing may be
/// able to update it (the app is suspended, no Mac is awake to push), so the activity goes stale there,
/// the system draws it again, and it moves on to `nextPhase` by itself (see `moved(at:)`).
struct PomodoroLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PomodoroActivityAttributes.self) { context in
            LockScreenView(state: context.state.moved(at: Date()), isMirror: context.attributes.isMirror)
                .activityBackgroundTint(Color.tpBackground)
                .activitySystemActionForegroundColor(Color.tpPrimary)
        } dynamicIsland: { context in
            let state = context.state.moved(at: Date()).state
            let isMirror = context.attributes.isMirror
            let tint = Color(hexString: state.tintHex)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(state.phaseTitle, systemImage: state.isPaused ? "pause.circle" : "timer")
                        .font(.headline)
                        .foregroundStyle(tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CountdownText(state: state)
                        .font(.title2.monospacedDigit())
                        .foregroundStyle(state.isPaused ? Color.tpAlert : tint)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        PhaseProgress(state: state, tint: tint)
                        HStack {
                            Text(state.paperLine.map { "Paper · \($0)" } ?? state.progressLine)
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(Color.tpDimmed)
                            Spacer()
                            if isMirror {
                                MirrorLabel(state: state)
                            } else {
                                ActivityButtons(isPaused: state.isPaused)
                            }
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: isMirror ? "laptopcomputer" : (state.isPaused ? "pause.circle" : "timer"))
                    .foregroundStyle(tint)
            } compactTrailing: {
                CountdownText(state: state)
                    .monospacedDigit()
                    .frame(maxWidth: 52)
                    .foregroundStyle(state.isPaused ? Color.tpAlert : tint)
            } minimal: {
                Image(systemName: isMirror ? "laptopcomputer" : (state.isPaused ? "pause.circle" : "timer"))
                    .foregroundStyle(tint)
            }
            .keylineTint(tint)
        }
    }
}

/// The content as it should read at a given moment, once any phase end it has run past is accounted for.
struct MovedContent {
    var state: PomodoroActivityAttributes.ContentState
    /// Drawn at a moment past even the end of the phase it could move on to: what the clock says now
    /// is only known from `upcoming`, until the app or a Mac updates the activity.
    var isBehind: Bool
    var now: Date
}

extension PomodoroActivityAttributes.ContentState {
    /// Past the end of a running phase, the next phase takes its place: its title, countdown, progress
    /// and tint. The activity is only drawn again when its content changes or it goes stale, so this
    /// carries it across one boundary on its own; a Mac push or the app catches it up after that.
    func moved(at now: Date) -> MovedContent {
        guard !isPaused, now >= phaseEndsAt else { return MovedContent(state: self, isBehind: false, now: now) }
        guard let next = nextPhase else { return MovedContent(state: self, isBehind: !upcoming.isEmpty, now: now) }
        var moved = self
        moved.phaseTitle = next.title
        moved.phaseStartedAt = next.startsAt
        moved.phaseEndsAt = next.endsAt
        moved.progressLine = next.progressLine
        moved.tintHex = next.tintHex
        moved.upcoming = upcoming.filter { $0.startsAt > next.startsAt }
        moved.nextPhase = nil
        return MovedContent(state: moved, isBehind: now >= next.endsAt, now: now)
    }
}

private struct LockScreenView: View {
    let moved: MovedContent
    let isMirror: Bool

    init(state: MovedContent, isMirror: Bool) {
        self.moved = state
        self.isMirror = isMirror
    }

    private var state: PomodoroActivityAttributes.ContentState { moved.state }

    var body: some View {
        let tint = Color(hexString: state.tintHex)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.isPaused ? "Paused — \(state.phaseTitle)" : state.phaseTitle)
                        .font(.headline)
                        .foregroundStyle(tint)
                    Text(state.paperLine.map { "Paper · \($0)" } ?? state.progressLine)
                        .font(.caption)
                        .foregroundStyle(Color.tpDimmed)
                        .lineLimit(1)
                }
                Spacer()
                CountdownText(state: state)
                    .font(.system(size: 40, weight: .medium, design: .monospaced))
                    .foregroundStyle(state.isPaused ? Color.tpAlert : tint)
                    .multilineTextAlignment(.trailing)
            }

            PhaseProgress(state: state, tint: tint)

            HStack {
                upcomingLine
                    .font(.caption)
                    .foregroundStyle(Color.tpDimmed)
                    .lineLimit(1)
                Spacer()
                if isMirror {
                    MirrorLabel(state: state)
                } else {
                    ActivityButtons(isPaused: state.isPaused)
                }
            }
        }
        .padding(16)
    }

    /// What follows the current phase. Drawn past even the phase it moved on to, it says plainly what
    /// the schedule implies instead.
    private var upcomingLine: Text {
        if moved.isBehind {
            let current = state.upcoming.last { $0.startsAt <= moved.now } ?? state.upcoming.first
            let title = current?.title ?? "Next phase"
            return Text(isMirror ? "Now \(title) — waiting for the Mac" : "Now \(title) — open to refresh")
        }
        guard state.upcoming.first != nil else {
            return Text(state.isPaused ? "Paused" : "Last phase of the session")
        }
        let rest = state.upcoming.map { "\($0.title) \($0.startsAt.formatted(date: .omitted, time: .shortened))" }
        return Text("Then " + rest.joined(separator: " · "))
    }
}

/// The live countdown while running, a fixed readout while paused.
private struct CountdownText: View {
    let state: PomodoroActivityAttributes.ContentState

    var body: some View {
        if let paused = state.pausedRemaining {
            let seconds = Int(max(0, paused).rounded(.up))
            Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
        } else if state.phaseStartedAt < state.phaseEndsAt {
            Text(timerInterval: state.phaseStartedAt...state.phaseEndsAt, countsDown: true)
        } else {
            Text("00:00")
        }
    }
}

private struct PhaseProgress: View {
    let state: PomodoroActivityAttributes.ContentState
    let tint: Color

    var body: some View {
        Group {
            if state.isPaused || state.phaseStartedAt >= state.phaseEndsAt {
                let total = state.phaseEndsAt.timeIntervalSince(state.phaseStartedAt)
                let done = total - (state.pausedRemaining ?? 0)
                ProgressView(value: total > 0 ? max(0, min(1, done / total)) : 1)
            } else {
                ProgressView(timerInterval: state.phaseStartedAt...state.phaseEndsAt, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            }
        }
        .tint(tint)
    }
}

/// In place of the buttons on a mirrored activity: display only, the controls are on the Mac.
private struct MirrorLabel: View {
    let state: PomodoroActivityAttributes.ContentState

    var body: some View {
        Label(state.mirroredFrom ?? "Mac", systemImage: "laptopcomputer")
            .font(.caption)
            .foregroundStyle(Color.tpDimmed)
            .lineLimit(1)
    }
}

/// Pause/Resume, Skip and Stop. Their intents run in the app's process, which re-plans the
/// notifications and refreshes this activity — so a tap also brings a stale activity back in step.
private struct ActivityButtons: View {
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: ToggleRunningIntent()) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
            }
            Button(intent: SkipPhaseIntent()) {
                Image(systemName: "forward.end.fill")
            }
            Button(intent: StopTimerIntent()) {
                Image(systemName: "stop.fill")
            }
        }
        .buttonStyle(.bordered)
        .tint(Color.tpPrimary)
        .font(.caption)
    }
}
