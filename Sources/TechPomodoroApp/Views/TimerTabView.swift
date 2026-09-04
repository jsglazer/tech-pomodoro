import SwiftUI
import TechPomodoroCore

/// Progress through the current schedule, plus the analytics block.
struct TimerTabView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: controller.state.progress(at: controller.displayNow))
                .tint(Color.tpPrimary)

            LabeledRow(label: "Phase", value: controller.state.activity == .idle ? "Idle" : controller.state.phase.title)
            LabeledRow(label: "Sessions completed", value: String(controller.state.completedSessions))

            Divider().overlay(Color.tpRule)

            AnalyticsPanel(controller: controller)
        }
    }
}

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(Color.tpDimmed)
            Spacer()
            Text(value)
        }
        .font(.system(size: 12))
    }
}

/// Hover reveals the detail — and fails open: if `.onHover` never fires, the numbers are already
/// visible rather than hidden behind a gesture that may not arrive.
struct AnalyticsPanel: View {
    @ObservedObject var controller: AppController
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ANALYTICS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.tpDimmed)
                Spacer()
                if hovering {
                    Text("hover")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.tpRule)
                }
            }

            window("Today", controller.analytics.today)
            window("Last 3 days", controller.analytics.lastThreeDays)
            window("Last 5 days", controller.analytics.lastFiveDays)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).stroke(hovering ? Color.tpPrimary : Color.tpRule, lineWidth: 1))
        .onHover { isHovering in
            hovering = isHovering
            if isHovering { controller.refreshAnalytics() }
        }
    }

    private func window(_ title: String, _ value: AnalyticsWindow) -> some View {
        LabeledRow(
            label: title,
            value: "\(value.sessions) sess · \(value.cycles) cyc · \(value.workDurationText)"
        )
    }
}
