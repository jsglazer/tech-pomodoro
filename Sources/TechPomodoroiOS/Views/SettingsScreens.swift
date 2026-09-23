import SwiftUI
import TechPomodoroCore
import UIKit

/// The time blocks: the durations and the shape of the cycle and the session.
struct IntervalsScreen: View {
    @ObservedObject var controller: PomodoroController

    var body: some View {
        ThemedForm(title: "Intervals") {
            Section {
                NumberRow(label: "Work", value: controller.bind(\.workMinutes), range: 1...180, unit: "min")
                NumberRow(label: "Rest", value: controller.bind(\.restMinutes), range: 1...60, unit: "min")
                NumberRow(label: "Reps per cycle", value: controller.bind(\.repsPerCycle), range: 1...12)
                NumberRow(label: "Long break", value: controller.bind(\.longBreakMinutes), range: 1...120, unit: "min")
                NumberRow(label: "Cycles per session", value: controller.bind(\.cyclesPerSession), range: 1...12)
                NumberRow(label: "Session rest", value: controller.bind(\.sessionRestMinutes), range: 1...240, unit: "min")
            } footer: {
                Text("A cycle is \(controller.settings.repsPerCycle) work/rest reps then a long break; a session is \(controller.settings.cyclesPerSession) cycles then the session rest. A change takes effect from the next phase.")
            }

            Section {
                Toggle("Repeat session indefinitely", isOn: controller.bind(\.repeatSession))
            }
        }
    }
}

/// The ding, the haptic pulse that replaces the Mac's menu bar flash, the alert dialog, and the tone.
struct SoundScreen: View {
    @ObservedObject var controller: PomodoroController

    var body: some View {
        ThemedForm(title: "Sound") {
            Section {
                Toggle("Ding at each boundary", isOn: controller.bind(\.dingEnabled))
                Picker("Sound", selection: controller.soundSelection) {
                    ForEach(controller.soundCatalog.availableSoundNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .disabled(!controller.settings.dingEnabled)
                RepeatRow(label: "Repeat in app", value: controller.bind(\.dingRepeatCount))
                    .disabled(!controller.settings.dingEnabled)
                Button("Preview") { controller.previewSound() }
            } footer: {
                Text("With the app closed, each boundary arrives as a notification that plays the sound once. The silent switch mutes the in-app ding.")
            }

            Section {
                Toggle("Haptic at each boundary", isOn: controller.bind(\.flashEnabled))
                RepeatRow(label: "Repeat haptic", value: controller.bind(\.flashRepeatCount))
                    .disabled(!controller.settings.flashEnabled)
                Toggle("Show alert dialog", isOn: controller.bind(\.popupEnabled))
            } footer: {
                Text("The haptic and the dialog happen while the app is open.")
            }

            Section("Notifications") {
                NotificationStatusRow(status: controller.notificationAuthorization)
            }
        }
    }
}

private struct RepeatRow: View {
    let label: String
    @Binding var value: Int

    var body: some View {
        Stepper(value: $value, in: 1...10) {
            HStack {
                Text(label)
                Spacer()
                Text(value == 1 ? "once" : "\(value)×")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(Color.tpDimmed)
            }
        }
    }
}

private struct NotificationStatusRow: View {
    let status: NotificationScheduler.Authorization
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch status {
        case .authorized:
            Label("On — boundaries alert with the app closed", systemImage: "bell.badge")
        case .notDetermined:
            Label("You will be asked the first time you start a timer", systemImage: "bell")
                .foregroundStyle(Color.tpDimmed)
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Label("Off — boundaries only alert while the app is open", systemImage: "bell.slash")
                    .foregroundStyle(Color.tpWarning)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        openURL(url)
                    }
                }
            }
        }
    }
}

/// Countdown colours and thresholds. The Mac-only settings — menu bar mode, filled background,
/// launch at login, sleep behaviour — are hidden here but left untouched in the stored settings.
struct SettingsScreen: View {
    @ObservedObject var controller: PomodoroController

    var body: some View {
        ThemedForm(title: "Settings") {
            Section {
                NumberRow(label: "Warning at", value: controller.bind(\.warningThresholdMinutes), range: 0...60, unit: "min", tint: .tpWarning)
                NumberRow(label: "Alert at", value: controller.bind(\.alertThresholdMinutes), range: 0...60, unit: "min", tint: .tpAlert)
            } header: {
                Text("Thresholds")
            } footer: {
                Text("Thresholds colour the Work countdown. 0 disables one, and a threshold always wins over the custom colour.")
            }

            Section("Colours") {
                Toggle("Colour the rest phases", isOn: controller.bind(\.useRestColor))
                ColorPicker("Rest colour", selection: controller.restColor, supportsOpacity: false)
                    .disabled(!controller.settings.useRestColor)
                Toggle("Custom countdown colour", isOn: controller.bind(\.useCustomTextColor))
                ColorPicker("Countdown colour", selection: controller.countdownColor, supportsOpacity: false)
                    .disabled(!controller.settings.useCustomTextColor)
            }

            Section {
                HStack {
                    Text("tech-pomodoro")
                    Spacer()
                    Text(RootView.appVersion).foregroundStyle(Color.tpDimmed)
                }
            }
        }
    }
}

/// The rolling windows, and export through the share sheet in place of the Mac's save panel.
struct AnalyticsScreen: View {
    @ObservedObject var controller: PomodoroController
    @State private var sharing: SharedFile?

    var body: some View {
        ThemedForm(title: "Analytics") {
            Section("Completed") {
                AnalyticsRow(title: "Today", window: controller.analytics.today)
                AnalyticsRow(title: "Last 3 days", window: controller.analytics.lastThreeDays)
                AnalyticsRow(title: "Last 5 days", window: controller.analytics.lastFiveDays)
            }

            Section {
                Button("Export CSV") { share(.csv) }
                Button("Export JSON") { share(.json) }
            } header: {
                Text("Export history")
            } footer: {
                Text("\(controller.history.count) records, kept for 30 days.")
            }
        }
        .onAppear { controller.refreshAnalytics() }
        .sheet(item: $sharing) { file in
            ShareSheet(items: [file.url])
                .presentationDetents([.medium, .large])
        }
    }

    private func share(_ format: PomodoroController.ExportFormat) {
        if let url = controller.exportFile(as: format) {
            sharing = SharedFile(url: url)
        }
    }
}

private struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// `UIActivityViewController`, for the export — the iOS counterpart of the Mac's save panel.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
