import SwiftUI
import TechPomodoroCore

/// The class list and publishing. The sittings list itself stays in the popover's Today tab.
struct PaperSettingsView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PaperClassesEditor(controller: controller)
            SettingsHeading("Publishing")
            PaperPublishingSection(controller: controller, publisher: controller.paperPublisher)
        }
    }
}

/// Every analytics window, the per-project totals beyond today, and the export.
struct AnalyticsSettingsView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledRow(label: "Today", value: controller.analytics.today.summaryText)
            LabeledRow(label: "Last 3 days", value: controller.analytics.lastThreeDays.summaryText)
            LabeledRow(label: "Last 5 days", value: controller.analytics.lastFiveDays.summaryText)

            SettingsHeading("Paper")
            ForEach([1, 3, 5], id: \.self) { days in
                LabeledRow(label: label(days), value: controller.paperLine(days: days) ?? "—")
            }

            if controller.settings.focus.enabled {
                ForEach([3, 5], id: \.self) { days in
                    SettingsHeading("By project, \(label(days).lowercased())")
                    let totals = controller.projectTotals(days: days).prefix(6)
                    if totals.isEmpty {
                        InfoCaption("No tracked Work.")
                    }
                    ForEach(Array(totals)) { total in
                        LabeledRow(label: total.name, value: PaperHistory.durationText(total.seconds))
                    }
                    if let share = controller.meanFocusShare(days: days) {
                        LabeledRow(label: "Mean focus", value: "\(Int((share * 100).rounded()))%")
                    }
                }
            }

            SettingsHeading("Export")
            HStack {
                Button("Export CSV…") { controller.exportHistory(as: .csv) }
                Button("Export JSON…") { controller.exportHistory(as: .json) }
            }
            InfoCaption("\(controller.history.count) records. Kept for 30 days; paper sittings for \(PaperHistory.retentionDays).")
        }
        .onAppear { controller.refreshAnalytics() }
    }

    private func label(_ days: Int) -> String {
        days == 1 ? "Today" : "Last \(days) days"
    }
}
