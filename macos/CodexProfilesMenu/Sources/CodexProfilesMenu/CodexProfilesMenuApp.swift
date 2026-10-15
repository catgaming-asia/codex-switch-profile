import AppKit

#if !TESTING
@MainActor
@main
struct CodexProfilesMenuApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let store = WorkspaceStore(client: CLIClient())
    private let notifier = UserNotificationsQuotaNotifier()
    private lazy var alerts = QuotaAlertController(store: store, notifier: notifier)
    private var menuController: WorkspaceMenuViewController?
    private var eventMonitor: Any?
    private var statusRefreshTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = WorkspaceMenuViewController(store: store, alerts: alerts)
        controller.onPreferredContentSizeChange = { [weak self] size in
            self?.popover.contentSize = size
        }
        controller.onRequestClose = { [weak self] in self?.popover.performClose(nil) }
        controller.onProfileNameVisibilityChange = { [weak self] in
            guard let self else { return }
            self.updateStatusItem(self.alerts.indicator)
        }
        menuController = controller

        popover.behavior = .transient
        updateAccessibilityPreferences()
        NSWorkspace.shared.notificationCenter.addObserver(self,
            selector: #selector(updateAccessibilityPreferences),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        popover.contentSize = controller.preferredContentSize
        popover.contentViewController = controller

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusItem(alerts.indicator)
        alerts.onIndicatorChange = { [weak self] indicator in self?.updateStatusItem(indicator) }
        store.onStatusUsageChange = { [weak self] in
            guard let self else { return }
            self.updateStatusItem(self.alerts.indicator)
        }
        notifier.onOpen = { [weak self] in self?.showMenu() }
        // Alerts keep their own notification schedule; the status text also refreshes while the app runs.
        alerts.start()
        statusRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.store.refreshIfNeeded()
                await self.store.refreshUsage()
                try? await Task.sleep(for: .seconds(300), tolerance: .seconds(60))
            }
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown, NSApp.modalWindow == nil,
                event.window == self.menuController?.view.window else { return event }
            return self.menuController?.handleShortcut(event) == true ? nil : event
        }
        // Login launches stay in the menu bar; launches by the user open the menu.
        if !Self.launchedAsLoginItem { togglePopover() }
    }

    /// Opening the app again from Finder or Spotlight shows the menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMenu()
        return false
    }

    private func showMenu() {
        if !popover.isShown { togglePopover() }
    }

    /// The icon is a template image either way; a low quota adds a badge shape,
    /// and the tooltip and accessibility label name each profile and window.
    private func updateStatusItem(_ indicator: QuotaIndicator) {
        guard let button = statusItem?.button else { return }
        let now = Date()
        let quota = DefaultMenuBarQuota(reading: store.usage["default"], at: now).text
        let namesHidden = UserDefaults.standard.bool(forKey: "hideProfileNames")
        let label = namesHidden ? "Codex Profiles" : indicator.accessibilityLabel(at: now)
        button.image = StatusItemIcon.image(for: indicator.level, accessibilityDescription: label)
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        button.title = quota ?? ""
        statusItem?.length = quota == nil ? NSStatusItem.squareLength : NSStatusItem.variableLength
        button.toolTip = namesHidden ? "Codex Profiles" : indicator.toolTip(at: now)
        button.setAccessibilityLabel(quota.map { "\(label). Default Codex quota: \($0)" } ?? label)
    }

    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store.isRefreshingUsage else { return .terminateNow }
        Task {
            await store.stopUsageRefresh()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusRefreshTask?.cancel()
        store.cancelUsageRefresh()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    @objc private func updateAccessibilityPreferences() {
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            menuController?.focusMenu()
            Task { await store.refresh(); await store.refreshUsage() }
            Task { await alerts.refreshPermission() }
        }
    }
}
#endif
