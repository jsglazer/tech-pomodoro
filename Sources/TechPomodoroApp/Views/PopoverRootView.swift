import SwiftUI
import TechPomodoroCore

/// The popover: a live countdown header with its own Stop and Pause controls, over three tabs.
struct PopoverRootView: View {
    @ObservedObject var controller: AppController
    @State private var tab: Tab = .timer

    enum Tab: String, CaseIterable, Identifiable {
        case timer = "Timer"
        case intervals = "Intervals"
        case settings = "Settings"
        case sound = "Sound"

        var id: String { rawValue }
    }

    /// The bundle's marketing version, or `dev` when running the SwiftPM binary outside a bundle.
    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "v\(version ?? "dev")"
    }

    var body: some View {
        VStack(spacing: 0) {
            CountdownHeader(controller: controller)

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().overlay(Color.tpRule)

            // No scroll view: the popover sizes itself to whichever tab is showing, so every control
            // is reachable without scrolling.
            Group {
                switch tab {
                case .timer: TimerTabView(controller: controller)
                case .intervals: IntervalsTabView(controller: controller)
                case .settings: SettingsTabView(controller: controller)
                case .sound: SoundTabView(controller: controller)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(Color.tpRule)

            ZStack {
                // Centred on the footer rather than trailing the name, so it stays centred whatever
                // the side labels do.
                Text(Self.appVersion)
                    .font(.caption2)

                HStack {
                    Text("tech-pomodoro")
                        .font(.caption2)
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.plain)
                        .font(.caption2)
                }
            }
            .foregroundStyle(Color.tpDimmed)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 320)
        .background(Color.tpBackground)
        .foregroundStyle(Color.tpPrimary)
        .preferredColorScheme(.dark)
    }
}

/// The countdown itself is the pause control: clicking the numbers toggles running and paused.
private struct CountdownHeader: View {
    @ObservedObject var controller: AppController

    private var state: PomodoroState { controller.state }

    private var remainingText: String {
        let remaining = Int(state.remaining(at: controller.displayNow).rounded(.up))
        return String(format: "%02d:%02d", remaining / 60, remaining % 60)
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(state.activity == .idle ? "Ready" : state.phase.title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color.tpDimmed)

            Button {
                controller.send(.toggleRunning)
            } label: {
                Text(state.activity == .idle ? "--:--" : remainingText)
                    .font(.system(size: 44, weight: .medium, design: .monospaced))
                    .foregroundStyle(state.activity == .paused ? Color.tpWarning : Color.tpPrimary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click the countdown to pause or resume")

            Text(state.activity == .idle
                 ? "Rep 1 of \(state.settings.repsPerCycle) · Cycle 1 of \(state.settings.cyclesPerSession)"
                 : "Rep \(state.currentRep) of \(state.settings.repsPerCycle) · Cycle \(state.currentCycle) of \(state.settings.cyclesPerSession)")
                .font(.caption)
                .foregroundStyle(Color.tpDimmed)

            HStack(spacing: 8) {
                // Left slot: Start when idle, and Stop takes that same place once running — so the
                // button you reach for first is always on the left.
                if state.activity == .idle {
                    ControlButton(title: "Start", enabled: true) {
                        controller.send(.start)
                    }
                } else {
                    ControlButton(title: "Stop", enabled: true) {
                        controller.send(.stop)
                    }
                }

                // Right slot: always the pause control.
                ControlButton(
                    title: state.activity == .paused ? "Resume" : "Pause",
                    enabled: state.activity != .idle
                ) {
                    controller.send(.toggleRunning)
                }
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, 12)
    }
}

private struct ControlButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).stroke(Color.tpRule, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}
