import SwiftUI
import TechPomodoroCore

/// The ding and the flash, and which system sound the ding uses.
struct SoundTabView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Ding at each boundary", isOn: controller.bind(\.dingEnabled))
                .toggleStyle(.switch)

            repeatStepper("Repeat ding", controller.bind(\.dingRepeatCount))
                .disabled(!controller.settings.dingEnabled)
                .opacity(controller.settings.dingEnabled ? 1 : 0.4)

            Toggle("Flash the menu bar icon", isOn: controller.bind(\.flashEnabled))
                .toggleStyle(.switch)

            repeatStepper("Repeat flash", controller.bind(\.flashRepeatCount))
                .disabled(!controller.settings.flashEnabled)
                .opacity(controller.settings.flashEnabled ? 1 : 0.4)

            Toggle("Show alert dialog", isOn: controller.bind(\.popupEnabled))
                .toggleStyle(.switch)

            Text("A dialog box appears at every boundary and must be dismissed by hand.")
                .font(.caption2)
                .foregroundStyle(Color.tpDimmed)

            Divider().overlay(Color.tpRule)

            Picker("Sound", selection: controller.bind(\.soundName)) {
                ForEach(controller.soundCatalog.availableSoundNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }

            Button("Preview") { controller.previewSound() }
                .font(.system(size: 12))

            Text("Sounds are read from the system sound folders on this Mac.")
                .font(.caption2)
                .foregroundStyle(Color.tpDimmed)
        }
        .font(.system(size: 12))
    }

    private func repeatStepper(_ label: String, _ value: Binding<Int>) -> some View {
        HStack {
            Text(label).foregroundStyle(Color.tpDimmed)
            Spacer()
            Stepper(value: value, in: 1...10) {
                Text(value.wrappedValue == 1 ? "once" : "\(value.wrappedValue)×")
                    .font(.system(size: 12, design: .monospaced))
            }
            .fixedSize()
        }
    }
}
