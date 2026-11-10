import AppKit
import SwiftUI
import TechPomodoroCore

/// The sections of the Settings window: everything set once and then left alone. What you touch while
/// working stays in the popover.
enum SettingsSection: String, CaseIterable, Identifiable {
    case schedule = "Schedule"
    case alerts = "Alerts"
    case menuBar = "Menu bar"
    case focus = "Focus"
    case documents = "Documents"
    case paper = "Paper"
    case devices = "Devices"
    case analytics = "Analytics"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .schedule: return "clock"
        case .alerts: return "bell"
        case .menuBar: return "menubar.rectangle"
        case .focus: return "scope"
        case .documents: return "doc.text.magnifyingglass"
        case .paper: return "book"
        case .devices: return "laptopcomputer.and.iphone"
        case .analytics: return "chart.bar"
        }
    }
}

/// Owns the Settings window. The window and its hosting controller are built when it opens and torn
/// down when it closes, like the popover: a SwiftUI view graph left alive behind a closed window keeps
/// AppKit's display cycle laying it out (the 1.0.8 idle-CPU bug). While the window is open the app is
/// a regular app, so the window can take focus and shows in the Dock and the app switcher; closing it
/// returns the app to menu-bar-only.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let selection = SettingsSelection()

    func show(controller: AppController, section: SettingsSection? = nil) {
        if let section { selection.section = section }
        NSApp.setActivationPolicy(.regular)
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsWindowView(controller: controller, selection: selection))
        let window = NSWindow(contentViewController: hosting)
        window.title = "tech-pomodoro Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 640, height: 480))
        window.contentMinSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("SettingsWindow")
        if !window.setFrameUsingName("SettingsWindow") { window.center() }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the hosting controller with the window: this is what actually releases the view graph.
        window?.contentViewController = nil
        window?.delegate = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

/// The sidebar selection, kept across opens so the window comes back where you left it.
@MainActor
final class SettingsSelection: ObservableObject {
    @Published var section: SettingsSection = .schedule
}

struct SettingsWindowView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var selection: SettingsSelection

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: Binding(
                get: { selection.section },
                set: { if let new = $0 { selection.section = new } }
            )) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(selection.section.rawValue)
                        .font(.title2.weight(.semibold))
                    page
                }
                .padding(20)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.tpBackground)
        }
        .foregroundStyle(Color.tpPrimary)
        .preferredColorScheme(.dark)
        .font(.system(size: 13))
    }

    @ViewBuilder
    private var page: some View {
        switch selection.section {
        case .schedule: IntervalsTabView(controller: controller)
        case .alerts: SoundTabView(controller: controller)
        case .menuBar: MenuBarSettingsView(controller: controller)
        case .focus: FocusTabView(controller: controller)
        case .documents: DocumentSensorSettingsView(controller: controller)
        case .paper: PaperSettingsView(controller: controller)
        case .devices: DevicesSettingsView(controller: controller)
        case .analytics: AnalyticsSettingsView(controller: controller)
        }
    }
}

/// A one-line caption; the rest of the explanation is on the ⓘ's hover.
struct InfoCaption: View {
    let text: String
    var detail: String?
    var color: Color = .tpDimmed

    init(_ text: String, detail: String? = nil, color: Color = .tpDimmed) {
        self.text = text
        self.detail = detail
        self.color = color
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(text)
                .font(.caption)
                .foregroundStyle(color)
            if let detail {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Color.tpDimmed)
                    .help(detail)
            }
        }
    }
}

/// A small uppercase heading inside a settings page.
struct SettingsHeading: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Color.tpDimmed)
            .padding(.top, 6)
    }
}
