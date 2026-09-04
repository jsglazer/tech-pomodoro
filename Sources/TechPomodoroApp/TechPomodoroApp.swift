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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var presenter: StatusItemPresenter?
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

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.contentViewController = NSHostingController(rootView: PopoverRootView(controller: controller))
        self.popover = popover

        controller.startRefreshing()
        controller.observeWorkspace()
    }

    @objc private func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // The flash must not fight the popover for the button's appearance.
            presenter?.cancelFlash()
            controller?.refreshAnalytics()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
