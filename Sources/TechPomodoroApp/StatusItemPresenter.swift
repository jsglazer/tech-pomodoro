import AppKit
import TechPomodoroCore

/// Draws the abstract `MenuBarPresentation` onto a real `NSStatusItem`.
///
/// Two things keep the menu bar quiet: the title is only rebuilt when the presentation actually
/// changes (a tick that leaves "24" as "24" touches nothing), and the countdown is drawn in a
/// monospaced-digit font so the item cannot jitter as the digits change.
@MainActor
final class StatusItemPresenter: NSResponder, MenuBarPresenting {
    private let statusItem: NSStatusItem
    private var lastApplied: MenuBarPresentation?
    private var lastTooltip: String?
    private var flashWorkItems: [DispatchWorkItem] = []

    private let hoverPanel = HoverPanelController()
    /// The current readout, refreshed every tick so the panel counts down while it is open.
    private var hoverInfo = HoverInfo(title: "Ready", detail: "--:--")

    /// Each blink is an on/off pair at 250ms; how many of them is the user's setting.
    private static let flashInterval: TimeInterval = 0.25

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        super.init()
        installHoverTracking()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: - Hover

    /// The audit's "no NSTrackingArea on the status item" rule was written to keep the *analytics*
    /// panel from depending on hover. This one is a deliberate exception: a hover readout has no
    /// other trigger. It fails safe — the system tooltip stays installed and takes over whenever the
    /// tracking area does not fire, and is suppressed only while our own panel is actually up.
    private func installHoverTracking() {
        guard let button = statusItem.button else { return }
        button.addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        showHoverPanel()
    }

    override func mouseExited(with event: NSEvent) {
        hideHoverPanel()
    }

    func showHoverPanel() {
        guard let button = statusItem.button else { return }
        // Our panel and the system tooltip must never both be up.
        button.toolTip = nil
        hoverPanel.show(info: hoverInfo, color: hoverColor, below: button)
    }

    func hideHoverPanel() {
        hoverPanel.hide()
        statusItem.button?.toolTip = lastTooltip
    }

    /// The countdown in the panel is drawn in whatever colour the menu bar is using, so the rest
    /// green and the threshold colours read the same in both places.
    private var hoverColor: NSColor {
        guard let presentation = lastApplied else { return Theme.primaryText }
        if let hex = presentation.customForegroundHex { return Theme.color(hexString: hex) }
        return presentation.adaptsToMenuBar ? Theme.primaryText : Theme.color(presentation.foreground)
    }

    /// Called every refresh with the current readout.
    func setHoverInfo(_ info: HoverInfo) {
        guard info != hoverInfo else { return }
        hoverInfo = info
        if hoverPanel.isVisible {
            hoverPanel.update(info: info, color: hoverColor)
        }
    }

    /// The tooltip changes every second, so it is set outside `apply` — a new countdown string must
    /// not force the title or image to be rebuilt.
    func setTooltip(_ text: String) {
        guard text != lastTooltip else { return }
        lastTooltip = text
        // While the panel is up it is the readout; the tooltip is only the fallback.
        if !hoverPanel.isVisible {
            statusItem.button?.toolTip = text
        }
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
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                // Monospaced digits: a fixed-width title that never reflows the menu bar.
                .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)
            ]

            if presentation.adaptsToMenuBar {
                button.image = nil
                button.attributedTitle = NSAttributedString(string: text, attributes: attributes)
            } else {
                // A status item button re-tints its *title* with the menu bar's own colour, which
                // silently discards an attributed foreground colour — that is why the threshold and
                // rest colours never appeared. Drawing the digits into a non-template image instead
                // puts the colour beyond AppKit's reach.
                button.attributedTitle = NSAttributedString(string: "")
                button.image = Self.image(of: text, attributes: attributes)
            }
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
        guard lastApplied != nil else { return }
        let blinks = max(1, times)

        // Each step redraws whatever the *current* presentation is, never a copy captured when the
        // flash began. A flash fires exactly at a phase boundary, so a captured copy would repaint
        // the phase that just ended — and since `apply` had already recorded the new one, the gate
        // would then suppress every correction and freeze the stale title in the bar.
        for step in 0..<(blinks * 2) {
            let dimmed = step % 2 == 0
            let item = DispatchWorkItem { [weak self] in
                self?.renderCurrent(dimmed: dimmed)
            }
            flashWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.flashInterval * Double(step), execute: item)
        }

        let restore = DispatchWorkItem { [weak self] in
            self?.renderCurrent(dimmed: false)
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
        renderCurrent(dimmed: false)
    }

    /// Redraws the presentation as it stands right now.
    private func renderCurrent(dimmed: Bool) {
        guard let presentation = lastApplied else { return }
        render(presentation, dimmed: dimmed)
    }
}

private extension StatusItemPresenter {
    /// Renders a menu bar title into an image, so its colour survives the status bar's tinting.
    static func image(of text: String, attributes: [NSAttributedString.Key: Any]) -> NSImage {
        let string = NSAttributedString(string: text, attributes: attributes)
        let measured = string.size()
        // A whole number of points, with a little side padding, keeps the item from shifting as the
        // digit count changes.
        let size = NSSize(width: ceil(measured.width) + 4, height: max(16, ceil(measured.height)))

        let image = NSImage(size: size, flipped: false) { rect in
            string.draw(at: NSPoint(x: 2, y: (rect.height - measured.height) / 2))
            return true
        }
        image.isTemplate = false
        return image
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
