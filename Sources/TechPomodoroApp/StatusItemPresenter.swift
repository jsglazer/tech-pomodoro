import AppKit
import TechPomodoroCore

/// Draws the abstract `MenuBarPresentation` onto a real `NSStatusItem`.
///
/// Two things keep the menu bar quiet: the title is only rebuilt when the presentation actually
/// changes (a tick that leaves "24" as "24" touches nothing), and the countdown is drawn in a
/// monospaced-digit font so the item cannot jitter as the digits change.
@MainActor
final class StatusItemPresenter: MenuBarPresenting {
    private let statusItem: NSStatusItem
    private var lastApplied: MenuBarPresentation?
    private var flashWorkItems: [DispatchWorkItem] = []

    /// Each blink is an on/off pair at 250ms; how many of them is the user's setting.
    private static let flashInterval: TimeInterval = 0.25

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
    }

    func apply(_ presentation: MenuBarPresentation) {
        guard presentation != lastApplied else { return }
        lastApplied = presentation
        render(presentation)
    }

    private func render(_ presentation: MenuBarPresentation, dimmed: Bool = false) {
        guard let button = statusItem.button else { return }
        // When the presentation adapts, macOS owns the colour: a template image and a label-coloured
        // title stay legible on a light menu bar and match the items either side. Only a threshold
        // colour or our own filled background takes the colour into our hands.
        let base: NSColor
        if let hex = presentation.customForegroundHex {
            base = Theme.color(hexString: hex)
        } else if presentation.adaptsToMenuBar {
            base = NSColor.labelColor
        } else {
            base = Theme.color(presentation.foreground)
        }
        let color = dimmed ? base.withAlphaComponent(0.15) : base

        if let text = presentation.text {
            button.image = nil
            button.attributedTitle = NSAttributedString(
                string: text,
                attributes: [
                    .foregroundColor: color,
                    // Monospaced digits: a fixed-width title that never reflows the menu bar.
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)
                ]
            )
        } else if let symbolName = presentation.symbolName {
            button.attributedTitle = NSAttributedString(string: "")
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "tech-pomodoro")
            if presentation.adaptsToMenuBar && !dimmed {
                // A template image is what lets the glyph invert with the menu bar's appearance.
                image?.isTemplate = true
                button.image = image
            } else {
                image?.isTemplate = false
                button.image = image?.tinted(with: color)
            }
        }

        if let backgroundToken = presentation.background {
            button.layer?.backgroundColor = Theme.color(backgroundToken).cgColor
            button.layer?.cornerRadius = 4
        } else {
            button.layer?.backgroundColor = nil
        }
    }

    /// Blinks the status item. A new request cancels the one in flight and restores the normal
    /// appearance first, so flashes can never queue up or leave the item stuck dimmed.
    func flash(times: Int) {
        cancelFlash()
        guard let presentation = lastApplied else { return }
        let blinks = max(1, times)

        for step in 0..<(blinks * 2) {
            let dimmed = step % 2 == 0
            let item = DispatchWorkItem { [weak self] in
                self?.render(presentation, dimmed: dimmed)
            }
            flashWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.flashInterval * Double(step), execute: item)
        }

        let restore = DispatchWorkItem { [weak self] in
            self?.render(presentation, dimmed: false)
        }
        flashWorkItems.append(restore)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.flashInterval * Double(blinks * 2),
            execute: restore
        )
    }

    func cancelFlash() {
        flashWorkItems.forEach { $0.cancel() }
        flashWorkItems.removeAll()
        if let presentation = lastApplied {
            render(presentation, dimmed: false)
        }
    }
}

private extension NSImage {
    /// SF Symbols arrive as templates; the menu bar needs them in the theme's colour.
    func tinted(with color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}
