import SwiftUI
import TechPomodoroCore

/// The ding and the flash, and which system sound the ding uses.
struct SoundTabView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Ding at each boundary", isOn: controller.bind(\.dingEnabled))
                .toggleStyle(.switch)
            Toggle("Flash the menu bar icon", isOn: controller.bind(\.flashEnabled))
                .toggleStyle(.switch)

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
}
