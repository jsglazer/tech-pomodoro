import SwiftUI
import TechPomodoroCore

/// The time blocks: the durations and the shape of the cycle and the session.
struct IntervalsTabView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepper("Work", controller.bind(\.workMinutes), range: 1...180, unit: "min")
            stepper("Rest", controller.bind(\.restMinutes), range: 1...60, unit: "min")
            stepper("Reps per cycle", controller.bind(\.repsPerCycle), range: 1...12, unit: "")
            stepper("Long break", controller.bind(\.longBreakMinutes), range: 1...120, unit: "min")
            stepper("Cycles per session", controller.bind(\.cyclesPerSession), range: 1...12, unit: "")
            stepper("Session rest", controller.bind(\.sessionRestMinutes), range: 1...240, unit: "min")

            Toggle("Repeat session indefinitely", isOn: controller.bind(\.repeatSession))
                .toggleStyle(.switch)
                .font(.system(size: 12))

            Text("A cycle is \(controller.settings.repsPerCycle) work/rest reps then a long break; a session is \(controller.settings.cyclesPerSession) cycles then the session rest.")
                .font(.caption2)
                .foregroundStyle(Color.tpDimmed)
        }
    }

    private func stepper(_ label: String, _ value: Binding<Int>, range: ClosedRange<Int>, unit: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Color.tpDimmed)
            Spacer()
            Stepper(value: value, in: range) {
                Text(unit.isEmpty ? "\(value.wrappedValue)" : "\(value.wrappedValue) \(unit)")
                    .font(.system(size: 12, design: .monospaced))
            }
            .fixedSize()
        }
        .font(.system(size: 12))
    }
}
