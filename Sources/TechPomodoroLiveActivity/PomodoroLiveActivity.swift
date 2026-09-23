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
/// animates itself: no update from the app is needed while a phase runs.
struct PomodoroLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PomodoroActivityAttributes.self) { context in
            LockScreenView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color.tpBackground)
                .activitySystemActionForegroundColor(Color.tpPrimary)
        } dynamicIsland: { context in
            let state = context.state
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
                        .foregroundStyle(state.isPaused ? Color.tpWarning : tint)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        PhaseProgress(state: state, tint: tint)
                        HStack {
                            Text(state.progressLine)
                                .font(.caption)
                                .foregroundStyle(Color.tpDimmed)
                            Spacer()
                            ActivityButtons(isPaused: state.isPaused)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: state.isPaused ? "pause.circle" : "timer")
                    .foregroundStyle(tint)
            } compactTrailing: {
                CountdownText(state: state)
                    .monospacedDigit()
                    .frame(maxWidth: 52)
                    .foregroundStyle(state.isPaused ? Color.tpWarning : tint)
            } minimal: {
                Image(systemName: state.isPaused ? "pause.circle" : "timer")
                    .foregroundStyle(tint)
            }
            .keylineTint(tint)
        }
    }
}

private struct LockScreenView: View {
    let state: PomodoroActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let tint = Color(hexString: state.tintHex)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.isPaused ? "Paused — \(state.phaseTitle)" : state.phaseTitle)
                        .font(.headline)
                        .foregroundStyle(tint)
                    Text(state.progressLine)
                        .font(.caption)
                        .foregroundStyle(Color.tpDimmed)
                }
                Spacer()
                CountdownText(state: state)
                    .font(.system(size: 40, weight: .medium, design: .monospaced))
                    .foregroundStyle(state.isPaused ? Color.tpWarning : tint)
                    .multilineTextAlignment(.trailing)
            }

            PhaseProgress(state: state, tint: tint)

            HStack {
                upcomingLine
                    .font(.caption)
                    .foregroundStyle(Color.tpDimmed)
                    .lineLimit(1)
                Spacer()
                ActivityButtons(isPaused: state.isPaused)
            }
        }
        .padding(16)
    }

    /// What follows the current phase. Once the countdown has run out with the app suspended, the
    /// activity cannot move itself on, so it says plainly what the schedule implies instead.
    private var upcomingLine: Text {
        guard let next = state.upcoming.first else {
            return Text(state.isPaused ? "Paused" : "Last phase of the session")
        }
        if isStale {
            return Text("Now \(next.title) — open to refresh")
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
