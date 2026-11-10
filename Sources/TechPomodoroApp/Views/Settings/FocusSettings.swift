import AppKit
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
                    .disabled(focus.paperClass != nil)
                    .help(focus.paperClass != nil
                          ? "Pinned to the paper tag's class while it is set."
                          : "The project this pomodoro is about. Pick one to pin it for the rest of the interval.")
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

        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).stroke(Color.tpRule, lineWidth: 1))
    }

    private var driftColor: Color {
        Color(nsColor: Theme.color(hexString: controller.settings.focus.driftColorHex))
    }

    private func anchorText(_ focus: FocusSnapshot) -> String {
        if let paperClass = focus.paperClass { return "\(paperClass) · paper" }
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

            SettingsHeading("Folder rules")

            editor("Class folders", \.focus.areaRules)
            editor("Task folders (first match wins)", \.focus.taskRules)
            InfoCaption(
                "One folder per line; * matches one folder name.",
                detail: "A note belongs to the first rule whose folder contains it. Class folders are the areas; task folders are inside them."
            )

            SettingsHeading("On task")

            editor("On-task apps", \.focus.onTaskApps)
            editor("On-task sites", \.focus.allowedSites)
            editor("Ignored apps", \.focus.neutralApps)
            InfoCaption("PDFs always count as on task. Any other app or site is a distraction.")
        }
    }
}

/// The document sensor: which apps' open documents go to ActivityWatch. Runs whether or not the
/// timer is running.
struct DocumentSensorSettingsView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        documentSensing
    }

    private var documentSensing: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Report open documents to ActivityWatch", isOn: controller.bind(\.focus.documents.enabled))
                .toggleStyle(.switch)
            stepper(
                "Sample every",
                controller.bind(\.focus.documents.intervalSeconds),
                range: DocumentSensorSettings.intervalRange,
                step: 5,
                unit: "s"
            )
            InfoCaption(controller.documentSensorStatusText, color: statusIsError ? .orange : .tpDimmed)

            SettingsHeading("Watched apps (extensions)")
            ForEach(controller.settings.focus.documents.apps) { app in
                HStack(spacing: 6) {
                    Text(app.name)
                        .lineLimit(1)
                        .frame(width: 110, alignment: .leading)
                        .help(app.bundleID)
                    if app.reportsFolder {
                        Text("current folder")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.tpDimmed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help("Reports the folder in ForkLift's active tab. macOS asks once to allow this.")
                    } else {
                        TextField("pdf, docx", text: controller.extensionsBinding(bundleID: app.bundleID))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    Button {
                        controller.removeWatchedApp(bundleID: app.bundleID)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Stop watching \(app.name)")
                }
            }
            Menu("Add a running app") {
                ForEach(addableApps, id: \.processIdentifier) { app in
                    Button(app.localizedName ?? app.bundleIdentifier ?? "?") { controller.addWatchedApp(app) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            InfoCaption(
                "Open documents of these types go to aw-watcher-documents.",
                detail: "When a watched app is in front, the full paths of its open documents of these types (for ForkLift, the folder it shows) go to the aw-watcher-documents bucket, and Focus files them under your class and task folders. Paths stay in this Mac's ActivityWatch (aw-sync copies them to your other Macs)."
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusIsError: Bool {
        if case .error = controller.documentSensorStatus { return true }
        return false
    }

    /// Regular (Dock) apps that are running and not watched yet.
    private var addableApps: [NSRunningApplication] {
        let watched = Set(controller.settings.focus.documents.apps.map { $0.bundleID.lowercased() })
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .filter { !watched.contains(($0.bundleIdentifier ?? "").lowercased()) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func editor(_ title: String, _ keyPath: WritableKeyPath<PomodoroSettings, [String]>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(Color.tpDimmed)
            TextEditor(text: controller.linesBinding(keyPath))
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(3)
                .frame(height: 80)
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

extension FocusTabView {
    fileprivate func editor(_ title: String, _ keyPath: WritableKeyPath<PomodoroSettings, [String]>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(Color.tpDimmed)
            TextEditor(text: controller.linesBinding(keyPath))
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(3)
                .frame(height: 80)
                .background(RoundedRectangle(cornerRadius: 4).stroke(Color.tpRule, lineWidth: 1))
        }
    }

    fileprivate func stepper(_ label: String, _ value: Binding<Int>, range: ClosedRange<Int>, step: Int, unit: String) -> some View {
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

/// Today's time by project and mean focus, for the popover's Today tab.
struct TodayFocusTotals: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
    }

    private func percent(_ share: Double) -> String {
        "\(Int((share * 100).rounded()))%"
    }

    private func minutes(_ seconds: Int) -> String {
        let m = seconds / 60
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}
