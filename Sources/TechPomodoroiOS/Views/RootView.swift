import SwiftUI
import TechPomodoroCore

/// The whole app, in three tabs: Timer (countdown and Paper), Today (today's numbers and the paper
/// sittings) and Settings (everything set once, as a list of sections).
struct RootView: View {
    @ObservedObject var controller: PomodoroController

    var body: some View {
        // `.tabItem` rather than iOS 18's `Tab`: same look, and nothing gained by switching.
        TabView {
            TimerScreen(controller: controller)
                .tabItem { Label("Timer", systemImage: "timer") }
            NavigationStack {
                TodayScreen(controller: controller)
            }
            .tabItem { Label("Today", systemImage: "calendar") }
            SettingsRootScreen(controller: controller)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(Color.tpPrimary)
        .preferredColorScheme(.dark)
        .alert(
            controller.popup?.title ?? "",
            isPresented: Binding(
                get: { controller.popup != nil },
                set: { if !$0 { controller.popup = nil } }
            ),
            presenting: controller.popup
        ) { _ in
            Button("OK") { controller.popup = nil }
        } message: { popup in
            Text(popup.message)
        }
    }

    /// The bundle's marketing version, shown in the Settings footer.
    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "v\(version ?? "dev")"
    }
}

/// A settings page in the app's dark palette: a grouped form on the theme background. Pushed inside
/// the Settings tab's navigation stack, so it has none of its own.
struct ThemedForm<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .scrollContentBackground(.hidden)
            .background(Color.tpBackground)
            .navigationTitle(title)
    }
}

/// The Settings tab: one list of sections, the same as the Mac's Settings window where they exist on iOS.
struct SettingsRootScreen: View {
    @ObservedObject var controller: PomodoroController

    var body: some View {
        NavigationStack {
            List {
                Section {
                    link("Schedule", "clock") { IntervalsScreen(controller: controller) }
                    link("Alerts", "bell") { SoundScreen(controller: controller) }
                    link("Display", "paintpalette") { DisplayScreen(controller: controller) }
                    link("Paper classes", "book") {
                        ThemedForm(title: "Paper classes") { PaperClassesSection(controller: controller) }
                    }
                    link("Devices", "laptopcomputer.and.iphone") { DevicesScreen(controller: controller) }
                    link("Analytics", "chart.bar") { AnalyticsScreen(controller: controller) }
                } footer: {
                    if controller.syncStatus.isProblem {
                        Label("iCloud: \(controller.syncStatus.label)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.tpWarning)
                    }
                }

                Section {
                    HStack {
                        Text("tech-pomodoro")
                        Spacer()
                        Text(RootView.appVersion).foregroundStyle(Color.tpDimmed)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.tpBackground)
            .navigationTitle("Settings")
        }
    }

    private func link<Destination: View>(_ title: String, _ image: String, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            Label(title, systemImage: image)
        }
    }
}

/// A whole-number field with a stepper beside it, clamped to `range` — the Mac's typed-number-plus-
/// stepper control, with the number pad for typing.
struct NumberRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var unit: String = ""
    var tint: Color = .tpPrimary

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .foregroundStyle(tint)
                .frame(width: 48)
            if !unit.isEmpty {
                Text(unit)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(Color.tpDimmed)
            }
            Stepper("", value: $value, in: range)
                .labelsHidden()
        }
    }

    private var text: Binding<String> {
        Binding(
            get: { String(value) },
            set: { newValue in
                if let parsed = Int(newValue) {
                    value = min(max(parsed, range.lowerBound), range.upperBound)
                }
            }
        )
    }
}
