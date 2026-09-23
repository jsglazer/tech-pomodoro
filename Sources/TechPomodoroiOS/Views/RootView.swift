import SwiftUI
import TechPomodoroCore

/// The whole app: the Mac popover's tabs, promoted to a tab bar, with Analytics given a tab of its
/// own now that there is room for it.
struct RootView: View {
    @ObservedObject var controller: PomodoroController

    var body: some View {
        // `.tabItem` rather than iOS 18's `Tab`, to keep the iOS 17 floor.
        TabView {
            TimerScreen(controller: controller)
                .tabItem { Label("Timer", systemImage: "timer") }
            IntervalsScreen(controller: controller)
                .tabItem { Label("Intervals", systemImage: "square.stack.3d.up") }
            SoundScreen(controller: controller)
                .tabItem { Label("Sound", systemImage: "bell") }
            SettingsScreen(controller: controller)
                .tabItem { Label("Settings", systemImage: "gearshape") }
            AnalyticsScreen(controller: controller)
                .tabItem { Label("Analytics", systemImage: "chart.bar") }
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

/// A settings screen in the app's dark palette: a grouped form on the theme background.
struct ThemedForm<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            Form { content }
                .scrollContentBackground(.hidden)
                .background(Color.tpBackground)
                .navigationTitle(title)
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
