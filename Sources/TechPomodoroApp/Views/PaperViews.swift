import AppKit
import SwiftUI
import TechPomodoroCore

/// The compact Paper control on the Timer tab: class, kind and an optional note, usable idle (applies
/// from the next Start), running or paused, with Clear.
struct PaperControl: View {
    @ObservedObject var controller: AppController
    @State private var note = ""
    @State private var pendingTag: PaperTag?
    @State private var confirmingOtherDevice = false
    /// The kind picked before any class, used when a class is chosen.
    @State private var chosenKind: PaperKind = .read
    @FocusState private var noteFocused: Bool

    private var tag: PaperTag? { controller.state.paperTag }
    private var kind: PaperKind { tag?.kind ?? chosenKind }
    private var classes: [String] { controller.settings.paperClasses.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The kind, always one click away: Read, Write, Practice, Watch.
            HStack(spacing: 4) {
                ForEach(PaperKind.allCases) { option in
                    let selected = option == kind
                    Button {
                        select(option)
                    } label: {
                        Text(option.title)
                            .font(.system(size: 11, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.tpBackground : Color.tpPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background {
                                if selected {
                                    RoundedRectangle(cornerRadius: 5).fill(tag == nil ? Color.tpDimmed : Color.tpPrimary)
                                } else {
                                    RoundedRectangle(cornerRadius: 5).stroke(Color.tpRule, lineWidth: 1)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tag == nil ? "\(option.title) — used when you pick a class" : "Paper kind: \(option.title)")
                }
            }

            HStack(spacing: 6) {
                Menu {
                    ForEach(classes, id: \.self) { name in
                        Button(name) { choose(className: name) }
                    }
                    if classes.isEmpty {
                        Text("Add classes in Settings")
                    }
                } label: {
                    Text(tag?.className ?? "Class…")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("The class this paper time is credited to")

                Spacer()

                if tag != nil {
                    Text(controller.state.activity == .idle ? "from next Start" : (controller.state.phase == .work ? "logging" : "next Work"))
                        .font(.system(size: 9))
                        .foregroundStyle(Color.tpPrimary)
                }

                if tag != nil {
                    Button("Clear") { apply(nil) }
                        .buttonStyle(.borderless)
                        .help("Stop tagging Work as paper time")
                }
            }

            if tag != nil {
                TextField("Note (optional)", text: $note)
                    .textFieldStyle(.roundedBorder)
                    .focused($noteFocused)
                    .onSubmit(commitNote)
                    .onChange(of: noteFocused) { _, focused in if !focused { commitNote() } }
            }
        }
        .font(.system(size: 12))
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).stroke(tag == nil ? Color.tpRule : Color.tpPrimary, lineWidth: 1))
        .onAppear { note = tag?.note ?? "" }
        .onChange(of: tag) { _, new in if !noteFocused { note = new?.note ?? "" } }
        .alert("Timer running on \(controller.otherDeviceTimerName ?? "another device")", isPresented: $confirmingOtherDevice) {
            Button("Tag this one") {
                if let pendingTag { controller.setPaperTag(pendingTag) }
                pendingTag = nil
            }
            Button("Cancel", role: .cancel) { pendingTag = nil }
        } message: {
            Text("A timer is running on \(controller.otherDeviceTimerName ?? "another device") — tag this one anyway? Tagging both would log one sitting twice.")
        }
    }

    /// Choosing a class keeps the kind already selected (Read until another is picked).
    private func choose(className: String) {
        apply(PaperTag(className: className, kind: kind, note: tag?.note))
    }

    private func select(_ option: PaperKind) {
        chosenKind = option
        guard let tag, tag.kind != option else { return }
        apply(PaperTag(className: tag.className, kind: option, note: tag.note))
    }

    private func commitNote() {
        guard let tag, (tag.note ?? "") != note.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        apply(PaperTag(className: tag.className, kind: tag.kind, note: note))
    }

    private func apply(_ new: PaperTag?) {
        guard let new else {
            controller.clearPaperTag()
            return
        }
        // Setting a tag (not just editing one) while the iPhone's timer runs asks first.
        if tag == nil, controller.otherDeviceTimerName != nil {
            pendingTag = new
            confirmingOtherDevice = true
            return
        }
        controller.setPaperTag(new)
    }
}

/// The Paper tab: log a past sitting, and the last 14 days of sittings with edit and delete.
struct PaperTabView: View {
    @ObservedObject var controller: AppController
    @State private var adding = false
    @State private var editing: UUID?
    @State private var deleting: PaperSittingView?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup("Log a past sitting", isExpanded: $adding) {
                SittingForm(
                    classes: controller.settings.paperClasses,
                    initial: .blank(className: controller.settings.paperClasses.first ?? ""),
                    timesEditable: true,
                    actionTitle: "Add sitting"
                ) { form in
                    controller.addPaperSitting(tag: form.tag, span: form.span)
                    adding = false
                }
                .padding(.top, 6)
            }

            Divider().overlay(Color.tpRule)

            Text("LAST 14 DAYS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Color.tpDimmed)

            let sittings = controller.recentPaperSittings
            if sittings.isEmpty {
                Text("No paper sittings yet. Tag a Work interval on the Timer tab, or log a past sitting above.")
                    .font(.caption2)
                    .foregroundStyle(Color.tpDimmed)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(sittings) { sitting in
                            if editing == sitting.id {
                                SittingForm(
                                    classes: controller.settings.paperClasses,
                                    initial: .init(sitting),
                                    timesEditable: sitting.manual,
                                    actionTitle: "Save",
                                    onCancel: { editing = nil }
                                ) { form in
                                    controller.editPaperSitting(
                                        sitting.id, className: form.className, kind: form.kind, note: form.note,
                                        start: sitting.manual ? form.span.start : nil,
                                        end: sitting.manual ? form.span.end : nil
                                    )
                                    editing = nil
                                }
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 6).stroke(Color.tpPrimary, lineWidth: 1))
                            } else {
                                SittingRow(sitting: sitting) { editing = sitting.id } onDelete: { deleting = sitting }
                            }
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
        .font(.system(size: 12))
        .alert("Delete this sitting?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let deleting { controller.deletePaperSitting(deleting.id) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text(deleting.map { "\($0.className) · \($0.kind.title) · \(SittingRow.timeText($0)). It is removed on every device." } ?? "")
        }
    }
}

private struct SittingRow: View {
    let sitting: PaperSittingView
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(PaperTag.shortClass(sitting.className)) · \(sitting.kind.title) · \(PaperHistory.durationText(sitting.seconds))")
                Text(Self.timeText(sitting) + (sitting.manual ? " · logged" : "") + (sitting.note.map { " · \($0)" } ?? ""))
                    .font(.caption2)
                    .foregroundStyle(Color.tpDimmed)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Edit")
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete")
        }
    }

    /// `Mon 10 Nov 13:28–14:05`.
    static func timeText(_ sitting: PaperSittingView) -> String {
        let day = sitting.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let from = sitting.start.formatted(date: .omitted, time: .shortened)
        let to = sitting.end.formatted(date: .omitted, time: .shortened)
        return "\(day) \(from)–\(to)"
    }
}

/// The fields of a sitting, for adding and editing.
struct SittingFormValue {
    var className: String
    var kind: PaperKind
    var note: String
    var start: Date
    /// A time of day; the sitting ends on the start's day, or the next if this is earlier.
    var endTime: Date

    static func blank(className: String, now: Date = Date()) -> SittingFormValue {
        let start = Calendar.current.date(byAdding: .minute, value: -30, to: now) ?? now
        return SittingFormValue(className: className, kind: .read, note: "", start: start, endTime: now)
    }

    init(className: String, kind: PaperKind, note: String, start: Date, endTime: Date) {
        self.className = className
        self.kind = kind
        self.note = note
        self.start = start
        self.endTime = endTime
    }

    init(_ sitting: PaperSittingView) {
        self.init(className: sitting.className, kind: sitting.kind, note: sitting.note ?? "", start: sitting.start, endTime: sitting.end)
    }

    var tag: PaperTag { PaperTag(className: className, kind: kind, note: note) }
    var span: DateInterval { ManualSitting.span(start: start, endTimeOf: endTime) }
}

struct SittingForm: View {
    let classes: [String]
    let timesEditable: Bool
    let actionTitle: String
    var onCancel: (() -> Void)?
    let onSave: (SittingFormValue) -> Void
    @State private var value: SittingFormValue

    init(
        classes: [String],
        initial: SittingFormValue,
        timesEditable: Bool,
        actionTitle: String,
        onCancel: (() -> Void)? = nil,
        onSave: @escaping (SittingFormValue) -> Void
    ) {
        self.classes = classes
        self.timesEditable = timesEditable
        self.actionTitle = actionTitle
        self.onCancel = onCancel
        self.onSave = onSave
        _value = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Class", selection: $value.className) {
                ForEach(choices, id: \.self) { Text($0).tag($0) }
            }
            Picker("", selection: $value.kind) {
                ForEach(PaperKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if timesEditable {
                DatePicker("Start", selection: $value.start, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.stepperField)
                DatePicker("End", selection: $value.endTime, displayedComponents: [.hourAndMinute])
                    .datePickerStyle(.stepperField)
                Text("\(PaperHistory.durationText(Int(value.span.duration))) — an end before the start means past midnight.")
                    .font(.caption2)
                    .foregroundStyle(Color.tpDimmed)
            }
            TextField("Note (optional)", text: $value.note)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                if let onCancel {
                    Button("Cancel", action: onCancel)
                }
                Button(actionTitle) { onSave(value) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.className.isEmpty || (timesEditable && value.span.duration <= 0))
            }
        }
    }

    /// The class list, plus the sitting's own class if it has since left the list.
    private var choices: [String] {
        let list = classes.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return list.contains(value.className) || value.className.isEmpty ? list : list + [value.className]
    }
}

/// The class list in Settings: add, rename, delete and reorder.
struct PaperClassesEditor: View {
    @ObservedObject var controller: AppController
    @State private var newName = ""

    private var classes: [String] { controller.settings.paperClasses }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paper classes").foregroundStyle(Color.tpDimmed)
            ForEach(Array(classes.enumerated()), id: \.offset) { index, name in
                HStack(spacing: 4) {
                    TextField("Class folder name", text: Binding(
                        get: { name },
                        set: { rename(index, to: $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                    Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless)
                        .disabled(index == classes.count - 1)
                    Button { remove(index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove \(name)")
                }
            }
            HStack(spacing: 4) {
                TextField("Add a class", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button(action: add) { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            InfoCaption(
                "Use each class folder's name exactly, e.g. Data - POGO 511.",
                detail: "The vault totals match paper time to classes by name. The list syncs to your other devices."
            )
        }
    }

    private func rename(_ index: Int, to name: String) {
        var settings = controller.settings
        guard settings.paperClasses.indices.contains(index) else { return }
        settings.paperClasses[index] = name
        controller.update(settings: settings)
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !classes.contains(name) else { return }
        var settings = controller.settings
        settings.paperClasses.append(name)
        controller.update(settings: settings)
        newName = ""
    }

    private func remove(_ index: Int) {
        var settings = controller.settings
        guard settings.paperClasses.indices.contains(index) else { return }
        settings.paperClasses.remove(at: index)
        controller.update(settings: settings)
    }

    private func move(_ index: Int, by offset: Int) {
        var settings = controller.settings
        let target = index + offset
        guard settings.paperClasses.indices.contains(index), settings.paperClasses.indices.contains(target) else { return }
        settings.paperClasses.swapAt(index, target)
        controller.update(settings: settings)
    }
}

/// The Focus tab's publishing section. Mac only, per device, off by default.
struct PaperPublishingSection: View {
    @ObservedObject var controller: AppController
    @ObservedObject var publisher: PaperPublisher

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Publish paper time", isOn: controller.bind(\.paperPublishEnabled))
                .toggleStyle(.switch)
            HStack {
                Text(controller.settings.paperLogPath)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(controller.settings.paperLogPath)
                Spacer()
                Button("Choose…", action: choose)
            }
            .disabled(!controller.settings.paperPublishEnabled)
            .opacity(controller.settings.paperPublishEnabled ? 1 : 0.4)
            if controller.settings.paperPublishEnabled {
                InfoCaption(statusText, color: publisher.status.lastError == nil ? .tpDimmed : .orange)
            }
            InfoCaption(
                "Turn this on on one Mac only.",
                detail: "Writes every paper sitting to the aw-watcher-paper bucket and rewrites the file above whole. aw-sync copies ActivityWatch buckets between Macs, so two publishing Macs would count every sitting twice."
            )
        }
    }

    private var statusText: String {
        var parts: [String] = []
        if let last = publisher.status.lastWrite {
            parts.append("Last written \(last.formatted(date: .omitted, time: .shortened)) · \(publisher.status.sittingsWritten) \(publisher.status.sittingsWritten == 1 ? "sitting" : "sittings")")
        } else {
            parts.append("Not written yet")
        }
        if let error = publisher.status.lastError { parts.append(error) }
        return parts.joined(separator: " · ")
    }

    private func choose() {
        let panel = NSSavePanel()
        let current = URL(fileURLWithPath: controller.settings.paperLogPath)
        panel.directoryURL = current.deletingLastPathComponent()
        panel.nameFieldStringValue = current.lastPathComponent
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = false
        panel.message = "The app owns this file and rewrites it whole."
        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            var settings = controller.settings
            settings.paperLogPath = url.path
            controller.update(settings: settings)
        }
        // Attached to the Settings window when there is one.
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(panel.runModal())
        }
    }
}
