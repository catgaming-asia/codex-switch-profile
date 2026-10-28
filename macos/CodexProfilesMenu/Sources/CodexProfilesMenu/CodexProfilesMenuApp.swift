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
    private let settings = AIProfileSettings()
    private let claudeStore = ClaudeUsageStore()
    private var menuController: AIProfileViewController?
    private var eventMonitor: Any?
    private var statusRefreshTask: Task<Void, Never>?
    private let sessionQuotaMonitor = SessionQuotaMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let codexController = WorkspaceMenuViewController(store: store, alerts: alerts)
        codexController.onRequestClose = { [weak self] in self?.popover.performClose(nil) }
        codexController.onProfileNameVisibilityChange = { [weak self] in
            guard let self else { return }
            self.updateStatusItem(self.alerts.indicator)
        }
        let controller = AIProfileViewController(codex: codexController, settings: settings, claude: claudeStore)
        controller.onPreferredContentSizeChange = { [weak self] size in
            self?.popover.contentSize = size
        }
        settings.onMenuBarProviderChange = { [weak self] in
            guard let self else { return }
            self.updateStatusItem(self.alerts.indicator)
            if self.settings.menuBarProvider == .claude { Task { await self.claudeStore.refresh() } }
        }
        claudeStore.onChange = { [weak self] in
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
            self.updateSessionMonitor()
            Task { await self.store.autoSwitchIfNeeded() }
        }
        store.onAutoSwitchSettingChange = { [weak self] in self?.updateSessionMonitor() }
        sessionQuotaMonitor.onSignal = { [weak self] profile, signal in
            guard let self else { return }
            let current = self.store.activeProfile
            guard self.store.autoSwitchEnabled, !self.store.isSwitchingDefault,
                  self.store.isAutoSelected(current),
                  profile == "default" || profile == current,
                  signal.meetsThreshold(self.store.autoThreshold(for: current)) else { return }
            Task {
                await self.store.refreshUsage(force: true)
                guard self.store.activeProfile == current else { return }
                await self.store.autoSwitchIfNeeded(currentExhausted: signal.exhausted && profile == current)
            }
        }
        notifier.onOpen = { [weak self] in self?.showMenu() }
        // Alerts keep their own notification schedule; the status text also refreshes while the app runs.
        alerts.start()
        statusRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.store.refreshIfNeeded()
                self.updateSessionMonitor()
                await self.store.refreshUsage()
                await self.store.autoSwitchIfNeeded()
                if self.settings.menuBarProvider == .claude { await self.claudeStore.refresh() }
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

    private func updateSessionMonitor() {
        if store.autoSwitchEnabled {
            sessionQuotaMonitor.update(profiles: [store.activeProfile])
        } else {
            sessionQuotaMonitor.stop()
        }
    }

    /// The icon is a template image either way; a low quota adds a badge shape,
    /// and the tooltip and accessibility label name each profile and window.
    private func updateStatusItem(_ indicator: QuotaIndicator) {
        guard let button = statusItem?.button else { return }
        let now = Date()
        let showsClaude = settings.menuBarProvider == .claude
        var claudeSnapshot: ClaudeSnapshot?
        if case let .available(snapshot) = claudeStore.state { claudeSnapshot = snapshot }
        let quota = showsClaude
            ? claudeSnapshot?.menuBarText(at: now)
            : DefaultMenuBarQuota(reading: store.usage["default"], at: now).text
        let namesHidden = UserDefaults.standard.bool(forKey: "hideProfileNames")
        let label = namesHidden ? "AI profile" : showsClaude ? "AI Profile (Claude)" : indicator.accessibilityLabel(at: now)
        button.image = StatusItemIcon.image(
            for: showsClaude ? claudeSnapshot?.menuBarLevel(at: now) ?? .normal : indicator.level,
            symbolName: showsClaude ? StatusItemIcon.claudeSymbolName : StatusItemIcon.symbolName,
            accessibilityDescription: label)
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        button.title = quota ?? ""
        statusItem?.length = quota == nil ? NSStatusItem.squareLength : NSStatusItem.variableLength
        button.toolTip = namesHidden ? "AI profile" : showsClaude ? "AI Profile: Claude" : indicator.toolTip(at: now)
        button.setAccessibilityLabel(quota.map { "\(label). Default \(showsClaude ? "Claude" : "Codex") quota: \($0)" } ?? label)
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
        sessionQuotaMonitor.stop()
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
            Task {
                await store.refresh()
                updateSessionMonitor()
                await store.refreshUsage()
                await store.autoSwitchIfNeeded()
            }
            if settings.tab == .claude { Task { await claudeStore.refresh() } }
            Task { await alerts.refreshPermission() }
        }
    }
}
#endif
