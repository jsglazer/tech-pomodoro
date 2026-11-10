import SwiftUI
import TechPomodoroCore
import TechPomodoroSync

/// The popover's Now tab: what you touch while working.
struct NowTabView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: controller.state.progress(at: controller.displayNow))
                .tint(Color.tpPrimary)

            AttentionLine(controller: controller, mirror: controller.mirror, publisher: controller.paperPublisher)

            PaperControl(controller: controller)

            if controller.settings.focus.enabled {
                FocusPanel(controller: controller)
            }
        }
    }
}

/// One line, shown only when something needs attention. Clicking it opens the Settings section
/// that fixes it.
private struct AttentionLine: View {
    @ObservedObject var controller: AppController
    // Observed so the line appears and clears as their status changes.
    @ObservedObject var mirror: MirrorPusher
    @ObservedObject var publisher: PaperPublisher

    var body: some View {
        if let attention = controller.attentionLine {
            Button {
                controller.openSettings(attention.section)
            } label: {
                Label(attention.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.tpWarning)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(attention.text)\nClick to open \(attention.section.rawValue) settings.")
        }
    }
}

/// The popover's Today tab: today's numbers and the paper sittings.
struct TodayTabView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TodayAnalyticsPanel(controller: controller)

            if controller.settings.focus.enabled {
                TodayFocusTotals(controller: controller)
            }

            Divider().overlay(Color.tpRule)

            PaperTabView(controller: controller)
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

/// Today only; the longer windows are in Settings → Analytics. Hover refreshes it — and fails open:
/// if `.onHover` never fires, the numbers are already visible.
struct TodayAnalyticsPanel: View {
    @ObservedObject var controller: AppController
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TODAY")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.tpDimmed)
                Spacer()
                Button("More…") { controller.openSettings(.analytics) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .help("The last 3 and 5 days, by project, and export")
            }

            LabeledRow(label: "Work", value: controller.analytics.today.summaryText)
            LabeledRow(label: "Paper", value: controller.paperTodayLine ?? "—")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).stroke(hovering ? Color.tpPrimary : Color.tpRule, lineWidth: 1))
        .onHover { isHovering in
            hovering = isHovering
            if isHovering { controller.refreshAnalytics() }
        }
    }
}
