import SwiftUI
import TechPomodoroCore

/// The compact Paper control on the Timer screen: class, kind and an optional note, usable idle
/// (applies from the next Start), running or paused, with Clear.
struct PaperPanel: View {
    @ObservedObject var controller: PomodoroController
    @State private var note = ""
    @State private var pendingTag: PaperTag?
    @State private var confirmingOtherDevice = false
    @FocusState private var noteFocused: Bool

    private var tag: PaperTag? { controller.state.paperTag }
    private var classes: [String] { controller.settings.paperClasses.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("PAPER")
                Spacer()
                if tag != nil {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(Color.tpPrimary)
                }
            }

            HStack {
                Menu {
                    ForEach(classes, id: \.self) { name in
                        Button(name) { choose(className: name) }
                    }
                    if classes.isEmpty {
                        Text("Add classes in Settings")
                    }
                } label: {
                    Label(tag?.className ?? "Choose a class", systemImage: "book")
                        .lineLimit(1)
                }
                Spacer()
                if tag != nil {
                    Button("Clear", role: .destructive) { apply(nil) }
                }
            }

            if let tag {
                Picker("Kind", selection: Binding(
                    get: { tag.kind },
                    set: { kind in apply(PaperTag(className: tag.className, kind: kind, note: tag.note)) }
                )) {
                    ForEach(PaperKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                TextField("Note (optional)", text: $note)
                    .textFieldStyle(.roundedBorder)
                    .focused($noteFocused)
                    .submitLabel(.done)
                    .onSubmit(commitNote)
                    .onChange(of: noteFocused) { _, focused in if !focused { commitNote() } }
            }
        }
        .panelStyle()
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

    private var statusText: String {
        let state = controller.state
        if state.activity == .idle { return "from next Start" }
        return state.phase == .work ? "logging" : "next Work"
    }

    /// Choosing a class picks Read unless a kind was already chosen.
    private func choose(className: String) {
        apply(PaperTag(className: className, kind: tag?.kind ?? .read, note: tag?.note))
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
        // Setting a tag (not just editing one) while a Mac's timer runs asks first.
        if tag == nil, controller.otherDeviceTimerName != nil {
            pendingTag = new
            confirmingOtherDevice = true
            return
        }
        controller.setPaperTag(new)
    }
}

/// The last 14 days of paper sittings, with edit and delete, and Add sitting.
struct PaperSittingsScreen: View {
    @ObservedObject var controller: PomodoroController
    @State private var adding = false
    @State private var editing: PaperSittingView?
    @State private var deleting: PaperSittingView?

    var body: some View {
        let sittings = controller.recentPaperSittings
        Form {
            if sittings.isEmpty {
                Text("No paper sittings in the last 14 days. Tag a Work interval on the Timer screen, or add a past sitting.")
                    .foregroundStyle(Color.tpDimmed)
            }
            ForEach(sittings) { sitting in
                Button { editing = sitting } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(sitting.className) · \(sitting.kind.title) · \(PaperHistory.durationText(sitting.seconds))")
                            .foregroundStyle(Color.tpPrimary)
                        Text(Self.timeText(sitting) + (sitting.manual ? " · logged" : "") + (sitting.note.map { " · \($0)" } ?? ""))
                            .font(.caption)
                            .foregroundStyle(Color.tpDimmed)
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { deleting = sitting }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.tpBackground)
        .navigationTitle("Paper sittings")
        .toolbar {
            Button { adding = true } label: { Label("Add sitting", systemImage: "plus") }
        }
        .sheet(isPresented: $adding) {
            SittingSheet(
                title: "Add sitting",
                classes: controller.settings.paperClasses,
                initial: .blank(className: controller.settings.paperClasses.first ?? ""),
                timesEditable: true
            ) { value in
                controller.addPaperSitting(tag: value.tag, span: value.span)
            }
        }
        .sheet(item: $editing) { sitting in
            SittingSheet(
                title: "Edit sitting",
                classes: controller.settings.paperClasses,
                initial: .init(sitting),
                timesEditable: sitting.manual,
                onDelete: { deleting = sitting }
            ) { value in
                controller.editPaperSitting(
                    sitting.id, className: value.className, kind: value.kind, note: value.note,
                    start: sitting.manual ? value.span.start : nil,
                    end: sitting.manual ? value.span.end : nil
                )
            }
        }
        .alert("Delete this sitting?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let deleting { controller.deletePaperSitting(deleting.id) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text(deleting.map { "\($0.className) · \($0.kind.title) · \(Self.timeText($0)). It is removed on every device." } ?? "")
        }
    }

    static func timeText(_ sitting: PaperSittingView) -> String {
        let day = sitting.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let from = sitting.start.formatted(date: .omitted, time: .shortened)
        let to = sitting.end.formatted(date: .omitted, time: .shortened)
        return "\(day) \(from)–\(to)"
    }
}

struct SittingValue {
    var className: String
    var kind: PaperKind
    var note: String
    var start: Date
    /// A time of day; the sitting ends on the start's day, or the next if this is earlier.
    var endTime: Date

    static func blank(className: String, now: Date = Date()) -> SittingValue {
        let start = Calendar.current.date(byAdding: .minute, value: -30, to: now) ?? now
        return SittingValue(className: className, kind: .read, note: "", start: start, endTime: now)
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

private struct SittingSheet: View {
    let title: String
    let classes: [String]
    let timesEditable: Bool
    var onDelete: (() -> Void)?
    let onSave: (SittingValue) -> Void
    @State private var value: SittingValue
    @Environment(\.dismiss) private var dismiss

    init(
        title: String,
        classes: [String],
        initial: SittingValue,
        timesEditable: Bool,
        onDelete: (() -> Void)? = nil,
        onSave: @escaping (SittingValue) -> Void
    ) {
        self.title = title
        self.classes = classes
        self.timesEditable = timesEditable
        self.onDelete = onDelete
        self.onSave = onSave
        _value = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Class", selection: $value.className) {
                        ForEach(choices, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Kind", selection: $value.kind) {
                        ForEach(PaperKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Note (optional)", text: $value.note)
                }
                if timesEditable {
                    Section {
                        DatePicker("Start", selection: $value.start)
                        DatePicker("End", selection: $value.endTime, displayedComponents: .hourAndMinute)
                    } footer: {
                        Text("\(PaperHistory.durationText(Int(value.span.duration))). The end is on the start's day; an end before the start means past midnight.")
                    }
                } else {
                    Section {
                        Text("A timed sitting keeps the times the timer measured.")
                            .foregroundStyle(Color.tpDimmed)
                    }
                }
                if let onDelete {
                    Section {
                        Button("Delete sitting", role: .destructive) {
                            dismiss()
                            onDelete()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.tpBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(value)
                        dismiss()
                    }
                    .disabled(value.className.isEmpty || (timesEditable && value.span.duration <= 0))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// The class list, plus the sitting's own class if it has since left the list.
    private var choices: [String] {
        let list = classes.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return list.contains(value.className) || value.className.isEmpty ? list : list + [value.className]
    }
}

/// The class list in Settings: add, rename, delete and reorder.
struct PaperClassesSection: View {
    @ObservedObject var controller: PomodoroController
    @State private var newName = ""

    var body: some View {
        Section {
            ForEach(Array(controller.settings.paperClasses.enumerated()), id: \.offset) { index, name in
                TextField("Class folder name", text: Binding(
                    get: { name },
                    set: { rename(index, to: $0) }
                ))
            }
            .onDelete { offsets in
                var settings = controller.settings
                settings.paperClasses.remove(atOffsets: offsets)
                controller.update(settings: settings)
            }
            .onMove { from, to in
                var settings = controller.settings
                settings.paperClasses.move(fromOffsets: from, toOffset: to)
                controller.update(settings: settings)
            }
            HStack {
                TextField("Add a class", text: $newName)
                    .onSubmit(add)
                Button(action: add) { Image(systemName: "plus.circle.fill") }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            HStack {
                Text("Paper classes")
                Spacer()
                EditButton()
                    .font(.caption)
            }
        } footer: {
            Text("Use each class folder's name exactly (e.g. Data - POGO 511): the vault totals match paper time to classes by that name. Synced to your other devices.")
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
        guard !name.isEmpty, !controller.settings.paperClasses.contains(name) else { return }
        var settings = controller.settings
        settings.paperClasses.append(name)
        controller.update(settings: settings)
        newName = ""
    }
}
