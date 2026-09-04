import AppKit
import TechPomodoroCore

/// The readout that appears under the status item on hover.
///
/// The system tooltip cannot be restyled, so this is a borderless panel of our own: the countdown at
/// roughly twice tooltip size, the phase above it, in the app's palette. It never takes focus and
/// never accepts a click — hovering must not interrupt whatever the user is doing.
@MainActor
final class HoverPanelController {
    private var panel: NSPanel?
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(info: HoverInfo, color: NSColor, below button: NSStatusBarButton) {
        let panel = panel ?? makePanel()
        self.panel = panel

        update(info: info, color: color)
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 140, height: 64))
        position(panel, below: button)
        panel.orderFrontRegardless()
    }

    func update(info: HoverInfo, color: NSColor) {
        titleField.stringValue = info.title
        titleField.textColor = Theme.dimmedText
        detailField.stringValue = info.detail
        detailField.textColor = color
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        titleField.alignment = .center
        // Twice the size of a system tooltip, in monospaced digits so the readout does not wobble.
        detailField.font = .monospacedDigitSystemFont(ofSize: 28, weight: .medium)
        detailField.alignment = .center

        let stack = NSStackView(views: [titleField, detailField])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)

        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = Theme.background.cgColor
        background.layer?.cornerRadius = 10
        background.layer?.borderWidth = 1
        background.layer?.borderColor = Theme.rule.cgColor
        background.addSubview(stack)

        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 140, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = background
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        return panel
    }

    private func position(_ panel: NSPanel, below button: NSStatusBarButton) {
        guard let window = button.window else { return }
        let onScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: onScreen.midX - size.width / 2,
            y: onScreen.minY - size.height - 6
        ))
    }
}
