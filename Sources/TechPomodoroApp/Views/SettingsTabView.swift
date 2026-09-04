import SwiftUI
import TechPomodoroCore

/// Menu bar appearance, thresholds, sleep behaviour, launch at login, and export.
struct SettingsTabView: View {
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

            Group {
                thresholdStepper("Warning at", controller.bind(\.warningThresholdMinutes))
                thresholdStepper("Alert at", controller.bind(\.alertThresholdMinutes))
            }
            .disabled(controller.settings.menuBarMode == .clockIcon)
            .opacity(controller.settings.menuBarMode == .clockIcon ? 0.4 : 1)

            Text("Thresholds colour the Work countdown only, in minutes mode. 0 disables one.")
                .font(.caption2)
                .foregroundStyle(Color.tpDimmed)

            Divider().overlay(Color.tpRule)

            Picker("On sleep", selection: controller.bind(\.sleepBehavior)) {
                Text("Keep counting").tag(SleepBehavior.continueThroughSleep)
                Text("Pause").tag(SleepBehavior.pauseOnSleep)
            }
            .pickerStyle(.segmented)

            Toggle("Launch at login", isOn: Binding(
                get: { controller.settings.launchAtLogin },
                set: { controller.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)

            if let warning = controller.loginItemWarning {
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(Color.tpWarning)
            }

            Divider().overlay(Color.tpRule)

            HStack {
                Text("Export history").foregroundStyle(Color.tpDimmed)
                Spacer()
                Button("CSV") { controller.exportHistory(as: .csv) }
                Button("JSON") { controller.exportHistory(as: .json) }
            }
            .font(.system(size: 12))
        }
        .font(.system(size: 12))
    }

    private func thresholdStepper(_ label: String, _ value: Binding<Int>) -> some View {
        HStack {
            Text(label).foregroundStyle(Color.tpDimmed)
            Spacer()
            Stepper(value: value, in: 0...60) {
                Text("\(value.wrappedValue) min")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(label.hasPrefix("Alert") ? Color.tpAlert : Color.tpWarning)
            }
            .fixedSize()
        }
    }
}
