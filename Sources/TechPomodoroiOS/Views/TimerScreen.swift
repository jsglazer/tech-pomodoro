import SwiftUI
import TechPomodoroCore

/// The main screen, standing in for the Mac popover's countdown header: a large countdown inside a
/// progress ring, the controls, and what comes next. On an iPad in regular width the analytics sit
/// beside it.
struct TimerScreen: View {
    @ObservedObject var controller: PomodoroController
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationStack {
            ScrollView {
                if sizeClass == .regular {
                    HStack(alignment: .top, spacing: 32) {
                        TimerPanel(controller: controller)
                        VStack(spacing: 20) {
                            UpNextPanel(state: controller.state)
                            AnalyticsPanel(analytics: controller.analytics)
                        }
                        .frame(maxWidth: 360)
                    }
                    .padding(32)
                } else {
                    VStack(spacing: 24) {
                        TimerPanel(controller: controller)
                        UpNextPanel(state: controller.state)
                    }
                    .padding(20)
                }
            }
            .background(Color.tpBackground)
            .navigationTitle("tech-pomodoro")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct TimerPanel: View {
    @ObservedObject var controller: PomodoroController

    private var state: PomodoroState { controller.state }

    var body: some View {
        VStack(spacing: 20) {
            Text(state.activity == .idle ? "READY" : state.phase.title.uppercased())
                .font(.system(size: 13, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(Color.tpDimmed)

            // Once a second only for the ring and the threshold colour; the digits themselves are a
            // system-driven `Text(timerInterval:)` and need no refresh from here.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                CountdownRing(state: state, now: context.date) {
                    controller.send(.toggleRunning)
                }
            }
            .frame(maxWidth: 320)

            Text("Rep \(state.currentRep) of \(state.settings.repsPerCycle) · Cycle \(state.currentCycle) of \(state.settings.cyclesPerSession)")
                .font(.subheadline)
                .foregroundStyle(Color.tpDimmed)

            HStack(spacing: 12) {
                // Left: Start when idle, Stop in the same place once running — as on the Mac.
                if state.activity == .idle {
                    ControlButton(title: "Start", systemImage: "play.fill", enabled: true) {
                        controller.send(.start)
                    }
                } else {
                    ControlButton(title: "Stop", systemImage: "stop.fill", enabled: true) {
                        controller.send(.stop)
                    }
                }
                ControlButton(
                    title: state.activity == .paused ? "Resume" : "Pause",
                    systemImage: state.activity == .paused ? "play.fill" : "pause.fill",
                    enabled: state.activity != .idle
                ) {
                    controller.send(.toggleRunning)
                }
                ControlButton(title: "Skip", systemImage: "forward.end.fill", enabled: state.activity != .idle) {
                    controller.send(.skip)
                }
            }
            .frame(maxWidth: 420)

            if controller.notificationAuthorization == .denied {
                Label("Notifications are off, so boundaries will not alert while the app is closed.", systemImage: "bell.slash")
                    .font(.footnote)
                    .foregroundStyle(Color.tpWarning)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The ring and the digits. Tapping the digits pauses and resumes, as clicking them does on the Mac.
private struct CountdownRing: View {
    let state: PomodoroState
    let now: Date
    let toggle: () -> Void

    var body: some View {
        let color = Theme.countdownColor(for: state, at: now)
        ZStack {
            Circle()
                .stroke(Color.tpRule, lineWidth: 10)
            Circle()
                .trim(from: 0, to: state.progress(at: now))
                .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: state.progress(at: now))

            Button(action: toggle) {
                digits
                    .font(.system(size: 64, weight: .medium, design: .monospaced))
                    .foregroundStyle(color)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.horizontal, 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Tap to pause or resume")
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private var digits: some View {
        switch state.activity {
        case .idle:
            Text("--:--")
        case .paused:
            Text(clock(state.remaining(at: now)))
        case .running:
            if let end = state.phaseEndsAt, end > now {
                Text(timerInterval: end.addingTimeInterval(-state.phaseDuration)...end, countsDown: true)
            } else {
                Text("00:00")
            }
        }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let remaining = Int(max(0, seconds).rounded(.up))
        return String(format: "%02d:%02d", remaining / 60, remaining % 60)
    }
}

/// The next few boundaries, from the same planner that schedules the notifications — so what this
/// says is exactly when the phone will alert.
private struct UpNextPanel: View {
    let state: PomodoroState

    var body: some View {
        let upcoming = BoundaryPlanner.upcoming(from: state, now: Date(), limit: 4)
        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("UP NEXT")
                ForEach(upcoming, id: \.fireAt) { boundary in
                    HStack {
                        Text(boundary.nextPhase?.title ?? "Session complete")
                        Spacer()
                        Text(boundary.fireAt, style: .time)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(Color.tpDimmed)
                    }
                }
            }
            .panelStyle()
        }
    }
}

struct AnalyticsPanel: View {
    let analytics: AnalyticsSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("ANALYTICS")
            AnalyticsRow(title: "Today", window: analytics.today)
            AnalyticsRow(title: "Last 3 days", window: analytics.lastThreeDays)
            AnalyticsRow(title: "Last 5 days", window: analytics.lastFiveDays)
        }
        .panelStyle()
    }
}

struct AnalyticsRow: View {
    let title: String
    let window: AnalyticsWindow

    var body: some View {
        HStack {
            Text(title).foregroundStyle(Color.tpDimmed)
            Spacer()
            Text("\(window.sessions) sess · \(window.cycles) cyc · \(window.workDurationText)")
                .font(.body.monospacedDigit())
        }
    }
}

struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Color.tpDimmed)
    }
}

extension View {
    func panelStyle() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).stroke(Color.tpRule, lineWidth: 1))
    }
}

private struct ControlButton: View {
    let title: String
    let systemImage: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 10).stroke(Color.tpRule, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.tpPrimary)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}
