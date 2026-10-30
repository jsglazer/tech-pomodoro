import SwiftUI
import TechPomodoroCore

/// The live focus readout on the Timer tab: the anchor (inferred, or pinned from the menu), what you
/// are on now, and how this interval and today have gone.
struct FocusPanel: View {
    @ObservedObject var controller: AppController

    private var level: DriftLevel { controller.settings.focus.driftLevel }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("FOCUS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.tpDimmed)
                Spacer()
                Text(controller.focusStatus)
                    .font(.system(size: 9))
                    .foregroundStyle(controller.focusStatus == "Live" ? Color.tpPrimary : Color.tpDimmed)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let focus = controller.focus {
                HStack {
                    Text("Anchor").foregroundStyle(Color.tpDimmed)
                    Spacer()
                    Menu {
                        Button("Infer automatically") { controller.setAnchor(nil) }
                        Divider()
                        ForEach(controller.focusProjects, id: \.self) { project in
                            Button(project.displayName) { controller.setAnchor(project) }
                        }
                    } label: {
                        Text(anchorText(focus))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("The project this pomodoro is about. Pick one to pin it for the rest of the interval.")
                }
                .font(.system(size: 12))

                HStack {
                    Text("Now").foregroundStyle(Color.tpDimmed)
                    Spacer()
                    Text(focus.current.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(focus.isDrifting ? driftColor : Color.tpPrimary)
                }
                .font(.system(size: 12))

                LabeledRow(label: "This interval", value: intervalText(focus))
            } else {
                Text("Start a Work interval to track what it goes on.")
                    .font(.caption2)
                    .foregroundStyle(Color.tpDimmed)
            }

            if let line = controller.lastFocusLine {
                LabeledRow(label: "Last", value: line)
            }

            let today = controller.projectTotals(days: 1).prefix(4)
            if !today.isEmpty {
                Text("TODAY BY PROJECT")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(Color.tpDimmed)
                    .padding(.top, 2)
                ForEach(Array(today)) { total in
                    LabeledRow(label: total.name, value: minutes(total.seconds))
                }
                if let share = controller.meanFocusShare(days: 1) {
                    LabeledRow(label: "Mean focus", value: percent(share))
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).stroke(Color.tpRule, lineWidth: 1))
    }

    private var driftColor: Color {
        Color(nsColor: Theme.color(hexString: controller.settings.focus.driftColorHex))
    }

    private func anchorText(_ focus: FocusSnapshot) -> String {
        guard let anchor = focus.anchor else { return "—" }
        let how = focus.anchorIsManual ? "pinned" : (focus.anchorIsLocked ? "auto" : "auto, settling")
        return "\(anchor.taskName) · \(how)"
    }

    private func intervalText(_ focus: FocusSnapshot) -> String {
        var parts = [focus.focusShare(level: level).map(percent) ?? "—", "\(focus.switches) sw"]
        if focus.isDrifting {
            parts.append("off \(Int(focus.offAnchorSeconds.rounded()))s")
        }
        return parts.joined(separator: " · ")
    }

    private func percent(_ share: Double) -> String {
        "\(Int((share * 100).rounded()))%"
    }

    private func minutes(_ seconds: Int) -> String {
        let m = seconds / 60
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}

/// How projects are recognised, what else counts as on task, and when drift alerts.
struct FocusTabView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Track focus with ActivityWatch", isOn: controller.bind(\.focus.enabled))
                .toggleStyle(.switch)

            HStack {
                Text("Server").foregroundStyle(Color.tpDimmed)
                Spacer()
                TextField("", text: controller.bind(\.focus.serverURL))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .font(.system(size: 11, design: .monospaced))
            }

            stepper("Drift alert after", controller.bind(\.focus.driftAlertSeconds), range: 0...600, step: 5, unit: "s")
            stepper("Anchor from first", controller.bind(\.focus.anchorLockMinutes), range: 1...25, step: 1, unit: "min")

            Picker("Drift is leaving the", selection: controller.bind(\.focus.driftLevel)) {
                Text("Task").tag(DriftLevel.task)
                Text("Class").tag(DriftLevel.area)
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Drift colour").foregroundStyle(Color.tpDimmed)
                Spacer()
                ColorPicker("", selection: controller.driftColor, supportsOpacity: false)
                    .labelsHidden()
            }

            Divider().overlay(Color.tpRule)

            editor("Class folders", \.focus.areaRules)
            editor("Task folders (first match wins)", \.focus.taskRules)
            Text("One folder per line. * matches one folder name. A note belongs to the first rule whose folder contains it.")
                .font(.caption2)
                .foregroundStyle(Color.tpDimmed)

            editor("On-task apps", \.focus.onTaskApps)
            editor("On-task sites", \.focus.allowedSites)
            editor("Ignored apps", \.focus.neutralApps)
            Text("PDFs always count as on task. Any other app or site is a distraction.")
                .font(.caption2)
                .foregroundStyle(Color.tpDimmed)
        }
        .font(.system(size: 12))
    }

    private func editor(_ title: String, _ keyPath: WritableKeyPath<PomodoroSettings, [String]>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(Color.tpDimmed)
            TextEditor(text: controller.linesBinding(keyPath))
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(3)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 4).stroke(Color.tpRule, lineWidth: 1))
        }
    }

    private func stepper(_ label: String, _ value: Binding<Int>, range: ClosedRange<Int>, step: Int, unit: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Color.tpDimmed)
            Spacer()
            Text("\(value.wrappedValue) \(unit)")
                .font(.system(size: 12, design: .monospaced))
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
        }
    }
}
