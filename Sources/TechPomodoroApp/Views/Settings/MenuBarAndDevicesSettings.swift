import SwiftUI
import TechPomodoroCore
import TechPomodoroSync

/// Menu bar appearance and the countdown thresholds.
struct MenuBarSettingsView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Menu bar", selection: controller.bind(\.menuBarMode)) {
                Text("Minutes").tag(MenuBarMode.minutesRemaining)
                Text("Clock icon").tag(MenuBarMode.clockIcon)
            }
            .pickerStyle(.segmented)

            Toggle("Filled background", isOn: controller.bind(\.useCustomBackground))
                .toggleStyle(.switch)

            Toggle("Custom text colour", isOn: controller.bind(\.useCustomTextColor))
                .toggleStyle(.switch)

            HStack {
                Text("Menu bar text").foregroundStyle(Color.tpDimmed)
                Spacer()
                ColorPicker("", selection: controller.menuBarTextColor, supportsOpacity: false)
                    .labelsHidden()
            }
            .disabled(!controller.settings.useCustomTextColor)
            .opacity(controller.settings.useCustomTextColor ? 1 : 0.4)

            Toggle("Colour the rest phases", isOn: controller.bind(\.useRestColor))
                .toggleStyle(.switch)

            HStack {
                Text("Rest colour").foregroundStyle(Color.tpDimmed)
                Spacer()
                ColorPicker("", selection: controller.restColor, supportsOpacity: false)
                    .labelsHidden()
            }
            .disabled(!controller.settings.useRestColor)
            .opacity(controller.settings.useRestColor ? 1 : 0.4)

            SettingsHeading("Thresholds")

            Group {
                thresholdStepper("Warning at", controller.bind(\.warningThresholdMinutes))
                thresholdStepper("Alert at", controller.bind(\.alertThresholdMinutes))
            }
            .disabled(controller.settings.menuBarMode == .clockIcon)
            .opacity(controller.settings.menuBarMode == .clockIcon ? 0.4 : 1)

            InfoCaption(
                "Minutes mode only. 0 disables a threshold.",
                detail: "Thresholds colour the countdown yellow, then red, as a phase runs out. A threshold always wins over the custom and rest colours."
            )
        }
    }

    private func thresholdStepper(_ label: String, _ value: Binding<Int>) -> some View {
        HStack {
            Text(label).foregroundStyle(Color.tpDimmed)
            Spacer()
            TextField("", text: thresholdTextBinding(for: value))
                .textFieldStyle(.roundedBorder)
                .frame(width: 36)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(label.hasPrefix("Alert") ? Color.tpAlert : Color.tpWarning)
            Text("min")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(label.hasPrefix("Alert") ? Color.tpAlert : Color.tpWarning)
            Stepper("", value: value, in: 0...60)
                .labelsHidden()
        }
    }

    private func thresholdTextBinding(for value: Binding<Int>) -> Binding<String> {
        Binding<String>(
            get: { String(value.wrappedValue) },
            set: { newValue in
                if let parsed = Int(newValue) {
                    value.wrappedValue = min(max(parsed, 0), 60)
                }
            }
        )
    }
}

/// What differs per device: sleep, login, iCloud sync and the iPhone mirror.
struct DevicesSettingsView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("On sleep", selection: controller.bind(\.sleepBehavior)) {
                Text("Resume").tag(SleepBehavior.resumeOnWake)
                Text("Keep counting").tag(SleepBehavior.continueThroughSleep)
                Text("Pause").tag(SleepBehavior.pauseOnSleep)
            }
            .pickerStyle(.segmented)
            InfoCaption(
                "What a running timer does when this Mac sleeps.",
                detail: "Resume freezes on sleep and carries on at wake. Keep counting runs against the clock and catches up at wake. Pause freezes and waits for you."
            )

            Toggle("Launch at login", isOn: Binding(
                get: { controller.settings.launchAtLogin },
                set: { controller.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)

            if let warning = controller.loginItemWarning {
                InfoCaption(warning, color: .tpWarning)
            }

            SettingsHeading("iCloud")

            Toggle("Sync via iCloud", isOn: controller.bind(\.cloudSyncEnabled))
                .toggleStyle(.switch)
            InfoCaption(
                controller.syncStatus.label,
                detail: "Settings, history and paper corrections sync across your Macs and iPhone through your private iCloud database.",
                color: controller.syncStatus.isProblem ? .tpWarning : .tpDimmed
            )

            SettingsHeading("iPhone")

            MirrorSettingsSection(controller: controller, mirror: controller.mirror)
        }
    }
}

/// Mirroring to the iPhone: the per-device switch, the push status, and the APNs key. The key is
/// imported once from the .p8 file into the Keychain; nothing about it is ever written to the app's files.
private struct MirrorSettingsSection: View {
    @ObservedObject var controller: AppController
    @ObservedObject var mirror: MirrorPusher
    @State private var keyID = ""
    @State private var teamID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Mirror timer with iPhone", isOn: controller.bind(\.mirrorEnabled))
                .help("This Mac's timer shows on the iPhone's Lock Screen, and the iPhone's timer shows here while this Mac's is idle. Display only, both ways.")
                .toggleStyle(.switch)
            InfoCaption(
                mirror.status.label,
                detail: "This Mac's timer shows on the iPhone's Lock Screen, and the iPhone's timer shows here while this Mac's is idle. Display only, both ways.",
                color: mirror.status.isProblem ? .tpWarning : .tpDimmed
            )

            HStack {
                Text("APNs key").foregroundStyle(Color.tpDimmed)
                Spacer()
                Button(mirror.credentials == nil ? "Import .p8…" : "Replace…") { mirror.importKey() }
                if mirror.credentials != nil {
                    Button("Remove") { mirror.removeKey() }
                }
            }

            if mirror.credentials != nil {
                HStack {
                    Text("Key ID").foregroundStyle(Color.tpDimmed)
                    Spacer()
                    TextField("10 characters", text: $keyID)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit { mirror.update(keyID: keyID) }
                }
                HStack {
                    Text("Team ID").foregroundStyle(Color.tpDimmed)
                    Spacer()
                    TextField("10 characters", text: $teamID)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit { mirror.update(teamID: teamID) }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: mirror.credentials) { _, _ in load() }
    }

    private func load() {
        keyID = mirror.credentials?.keyID ?? ""
        teamID = mirror.credentials?.teamID ?? ""
    }
}
