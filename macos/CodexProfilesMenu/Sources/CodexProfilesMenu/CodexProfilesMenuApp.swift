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
    private var claudeStatusItem: NSStatusItem?
    private let popover = NSPopover()
    private let store = WorkspaceStore(client: CLIClient())
    private let notifier = UserNotificationsQuotaNotifier()
    private lazy var alerts = QuotaAlertController(store: store, notifier: notifier)
    private let settings = AIProfileSettings()
    private let claudeStore = ClaudeUsageStore()
    private lazy var claudeProfiles: ClaudeProfileStore = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ClaudeProfileStore(directory: support.appendingPathComponent("AI Profile/claude"),
                                  claudeDirectory: home.appendingPathComponent(".claude"))
    }()
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
        let controller = AIProfileViewController(codex: codexController, store: store, settings: settings, claude: claudeStore,
                                              profiles: claudeProfiles)
        controller.onPreferredContentSizeChange = { [weak self] size in
            self?.popover.contentSize = size
        }
        settings.onMenuBarChange = { [weak self] in
            guard let self else { return }
            self.updateStatusItem(self.alerts.indicator)
            if self.settings.showsClaudeInMenuBar { Task { await self.claudeStore.refresh() } }
        }
        claudeStore.onChange = { [weak self] in
            guard let self else { return }
            self.updateStatusItem(self.alerts.indicator)
            self.menuController?.refreshCurrent()
        }
        claudeStore.select(configDirectory: claudeProfiles.accountDirectory(for: claudeProfiles.current))
        claudeProfiles.onCurrentChange = { [weak self] in
            guard let self else { return }
            self.claudeStore.select(configDirectory: self.claudeProfiles.accountDirectory(for: self.claudeProfiles.current))
            self.updateStatusItem(self.alerts.indicator)
            Task { await self.claudeStore.refresh() }
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
        let claudeItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        claudeStatusItem = claudeItem

        for button in [item.button, claudeItem.button].compactMap({ $0 }) {
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
                if self.settings.showsClaudeInMenuBar { await self.claudeStore.refresh() }
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

    /// Codex and Claude each own a status item, shown by their checkbox. With
    /// neither checked, the Codex item stays as a plain icon so the menu can
    /// still be opened. Icons are template images; a low quota adds a badge
    /// shape, and the tooltip and accessibility label name each window.
    private func updateStatusItem(_ indicator: QuotaIndicator) {
        let now = Date()
        let namesHidden = UserDefaults.standard.bool(forKey: "hideProfileNames")
        let showsCodex = settings.showsCodexInMenuBar
        let showsClaude = settings.showsClaudeInMenuBar
        statusItem?.isVisible = showsCodex || !showsClaude
        claudeStatusItem?.isVisible = showsClaude
        if let button = statusItem?.button {
            let quota = showsCodex ? DefaultMenuBarQuota(reading: store.usage["default"], at: now).text : nil
            let label = namesHidden ? "AI profile" : showsCodex ? indicator.accessibilityLabel(at: now) : "AI Profile"
            apply(to: statusItem, button: button, level: showsCodex ? indicator.level : .normal,
                  symbolName: StatusItemIcon.symbolName, quota: quota, label: label,
                  toolTip: namesHidden ? "AI profile" : showsCodex ? indicator.toolTip(at: now) : "AI Profile", provider: "Codex")
        }
        if let button = claudeStatusItem?.button {
            var snapshot: ClaudeSnapshot?
            if case let .available(value) = claudeStore.state, claudeProfiles.current.kind == .account { snapshot = value }
            apply(to: claudeStatusItem, button: button, level: snapshot?.menuBarLevel(at: now) ?? .normal,
                  symbolName: StatusItemIcon.claudeSymbolName, quota: snapshot?.menuBarText(at: now),
                  label: namesHidden ? "AI profile" : "AI Profile (Claude)",
                  toolTip: namesHidden ? "AI profile" : "AI Profile: Claude", provider: "Claude")
        }
    }

    private func apply(to item: NSStatusItem?, button: NSStatusBarButton, level: QuotaLevel, symbolName: String,
                       quota: String?, label: String, toolTip: String, provider: String) {
        button.image = StatusItemIcon.image(for: level, symbolName: symbolName, accessibilityDescription: label)
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        button.title = quota ?? ""
        item?.length = quota == nil ? NSStatusItem.squareLength : NSStatusItem.variableLength
        button.toolTip = toolTip
        button.setAccessibilityLabel(quota.map { "\(label). \(provider) quota: \($0)" } ?? label)
    }

    /// The menu opens from whichever status item is visible.
    private var anchorButton: NSStatusBarButton? {
        if statusItem?.isVisible == true { return statusItem?.button }
        return claudeStatusItem?.button
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
        guard let button = anchorButton else { return }

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
            Task { await claudeStore.refresh() }
            Task { await alerts.refreshPermission() }
        }
    }
}
#endif
