import SwiftUI
import TechPomodoroCore

/// The popover: a live countdown header with its own Stop, Pause and Skip controls, over two tabs —
/// Now (paper and focus) and Today (today's numbers and the paper sittings). Everything set once lives
/// in the Settings window, behind the header's gear.
struct PopoverRootView: View {
    @ObservedObject var controller: AppController
    @State private var tab: Tab = .now

    enum Tab: String, CaseIterable, Identifiable {
        case now = "Now"
        case today = "Today"

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
                case .now: NowTabView(controller: controller)
                case .today: TodayTabView(controller: controller)
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
///
/// While this Mac's timer is idle and an iPhone's is running, it shows the iPhone's, display only:
/// Start still starts this Mac's own timer (which then takes over), and the other controls are off.
private struct CountdownHeader: View {
    @ObservedObject var controller: AppController
    @State private var confirmingStop = false

    private var phone: PhoneTimerWatcher.Display? { controller.phoneDisplay }
    private var state: PomodoroState { phone?.state ?? controller.state }
    /// What the controls act on: always this Mac's own timer.
    private var ownActivity: PomodoroState.Activity { controller.state.activity }

    private var remainingText: String {
        let remaining = Int(state.remaining(at: controller.displayNow).rounded(.up))
        return String(format: "%02d:%02d", remaining / 60, remaining % 60)
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(state.activity == .idle ? "Ready" : (state.phase == .work && state.paperTag != nil ? "PAPER" : state.phase.title.uppercased()))
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color.tpDimmed)

            if let tag = state.paperTag {
                Label(tag.label + (tag.note.map { " · \($0)" } ?? ""), systemImage: "book")
                    .font(.caption)
                    .foregroundStyle(state.phase == .work && state.activity != .idle ? Color.tpPrimary : Color.tpDimmed)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let phone {
                Label("On \(phone.phoneName) · display only", systemImage: "iphone")
                    .font(.caption2)
                    .foregroundStyle(Color.tpDimmed)
            }

            Button {
                controller.send(.toggleRunning)
            } label: {
                Text(state.activity == .idle ? "--:--" : remainingText)
                    .font(.system(size: 44, weight: .medium, design: .monospaced))
                    .foregroundStyle(state.activity == .paused ? Color.tpAlert : Color.tpPrimary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(phone != nil)
            .help(phone == nil ? "Click the countdown to pause or resume" : "The iPhone's timer: control it on the iPhone")

            Text(state.activity == .idle
                 ? "Rep 1 of \(state.settings.repsPerCycle) · Cycle 1 of \(state.settings.cyclesPerSession)"
                 : "Rep \(state.currentRep) of \(state.settings.repsPerCycle) · Cycle \(state.currentCycle) of \(state.settings.cyclesPerSession)")
                .font(.caption)
                .foregroundStyle(Color.tpDimmed)

            HStack(spacing: 8) {
                // Left slot: Start when idle, and Stop takes that same place once running — so the
                // button you reach for first is always on the left.
                if ownActivity == .idle {
                    ControlButton(title: "Start", enabled: true) {
                        controller.send(.start)
                    }
                } else {
                    // Stop throws away the place in the schedule, so it asks first.
                    ControlButton(title: "Stop", enabled: true) {
                        confirmingStop = true
                    }
                }

                // Middle slot: always the pause control.
                // Pause filled yellow, Resume filled green, so the button says which way it goes.
                ControlButton(
                    title: ownActivity == .paused ? "Resume" : "Pause",
                    enabled: ownActivity != .idle,
                    fill: ownActivity == .paused ? .tpSuccess : .tpWarning
                ) {
                    controller.send(.toggleRunning)
                }

                // Far right: jump straight to the next phase.
                ControlButton(title: "Skip", enabled: ownActivity != .idle) {
                    controller.send(.skip)
                }
                .help("End this phase now and start the next one")
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, 12)
        .overlay(alignment: .topTrailing) {
            Button {
                controller.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.tpDimmed)
                    .padding(10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .alert("Stop the timer?", isPresented: $confirmingStop) {
            Button("Stop", role: .destructive) { controller.send(.stop) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The schedule resets to Rep 1 of Cycle 1. Work done so far is still logged.")
        }
    }
}

private struct ControlButton: View {
    let title: String
    let enabled: Bool
    /// Fills the button with this colour (white text on top); nil keeps the plain outlined button.
    var fill: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(fill == nil ? Color.tpPrimary : Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background {
                    if let fill {
                        RoundedRectangle(cornerRadius: 6).fill(fill)
                    } else {
                        RoundedRectangle(cornerRadius: 6).stroke(Color.tpRule, lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}
