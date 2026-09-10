import AppKit
import SwiftUI
import TechPomodoroCore

@main
enum TechPomodoroMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // Menu-bar-only: no Dock icon, no menu bar menus of its own. Info.plist sets LSUIElement for
        // the bundled app; this covers the SwiftPM binary too.
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var presenter: StatusItemPresenter?
    /// Non-nil only while the popover is on screen — see `makePopover`.
    private var popover: NSPopover?
    private var controller: AppController?
    private var monitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let intervalStore: any IntervalStore
        if let url = try? FileIntervalStore.applicationSupportURL() {
            intervalStore = FileIntervalStore(url: url)
        } else {
            intervalStore = MemoryIntervalStore()
        }

        let controller = AppController(
            intervalStore: intervalStore,
            settingsStore: UserDefaultsSettingsStore(defaults: .standard)
        )
        self.controller = controller

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.wantsLayer = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        self.statusItem = statusItem

        let presenter = StatusItemPresenter(statusItem: statusItem)
        self.presenter = presenter
        controller.attach(presenter: presenter)

        controller.startRefreshing()
        controller.observeWorkspace()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let controller else { return }
        if let popover {
            popover.performClose(nil)
            return
        }
        // The flash must not fight the popover for the button's appearance, and the hover
        // readout would sit on top of it.
        presenter?.cancelFlash()
        presenter?.hideHoverPanel()
        controller.refreshAnalytics()

        let popover = makePopover(controller: controller)
        self.popover = popover
        controller.setPopoverVisible(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// The popover and its SwiftUI hosting controller are built fresh on every open and torn down on
    /// close, rather than living for the lifetime of the app.
    ///
    /// A retained `NSHostingController` keeps its SwiftUI view graph — and the popover window it was
    /// installed in — alive after `performClose`, and AppKit's display cycle goes on running layout
    /// on that off-screen view. Measured on 1.0.8: the app sat at 47-59% CPU for hours with nothing
    /// visible, all of it `NSHostingView.layout()` under `UC::DriverCore::continueProcessing`, which
    /// is what made macOS report significant energy use. With no hosting controller alive between
    /// opens there is no view graph left for that cycle to touch, and the app measures 0.0% CPU idle.
    private func makePopover(controller: AppController) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        // No fixed contentSize: the hosting controller reports the SwiftUI content's own height, so
        // a taller tab grows the popover instead of scrolling inside it.
        let hosting = NSHostingController(rootView: PopoverRootView(controller: controller))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        return popover
    }

    func popoverDidClose(_ notification: Notification) {
        controller?.setPopoverVisible(false)
        // Drop the hosting controller with the popover: this is what actually releases the view graph.
        popover?.contentViewController = nil
        popover?.delegate = nil
        popover = nil
    }
}
