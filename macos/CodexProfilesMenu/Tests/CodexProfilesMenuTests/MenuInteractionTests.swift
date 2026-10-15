import AppKit
import Foundation

@MainActor
@main
struct MenuInteractionTests {
    static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let suite = "menu-interaction-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("launch")
        let executable = root.appendingPathComponent("cli")
        // The shim receives launch arguments without opening a real app or account.
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(marker.path)'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let store = WorkspaceStore(client: CLIClient(executableURL: executable), defaults: defaults)
        let checkedAt = Date()
        let quota = ProfileUsage.available(CodexRateLimits(windows: [
            RateLimitWindow(usedPercent: 23, windowDurationMins: 300, resetsAt: checkedAt.addingTimeInterval(3600).timeIntervalSince1970),
            RateLimitWindow(usedPercent: 91, windowDurationMins: 10080, resetsAt: checkedAt.addingTimeInterval(86400).timeIntervalSince1970),
        ]), checkedAt: checkedAt)
        store.loadPreview([], profiles: ["work"], usage: ["work": quota])
        let firstRunController = WorkspaceMenuViewController(store: store, defaults: defaults)
        expect(descendants(firstRunController.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "work" },
            "an initialized profile must be usable without any workspace binding")
        var profileClosed = false
        firstRunController.onRequestClose = { profileClosed = true }
        let profileRow = descendants(firstRunController.view).compactMap { $0 as? LaunchRowButton }.first!
        expect(descendants(profileRow).compactMap { $0 as? NSButton }.contains { $0.title == "Switch" },
            "named profiles must offer Switch instead of Open")
        let usageView = descendants(profileRow).compactMap { $0 as? ProfileUsageView }.first!
        expect(descendants(usageView).compactMap { $0 as? NSTextField }.map(\.stringValue) == ["5h", "77%", "7d", "9%"],
            "profile rows must show remaining percentages and actual window durations")
        expect(profileRow.accessibilityLabel()!.contains("77% remaining") && profileRow.accessibilityLabel()!.contains("Resets"),
            "quota and reset times must be available to accessibility clients")
        expect(usageView.toolTip!.contains("ChatGPT may use a different account") && usageView.toolTip!.contains("Checked"),
            "quota tooltips must explain sign-in scope and freshness")
        try? FileManager.default.removeItem(at: marker)
        profileRow.performClick(nil)
        expect(!profileClosed && !FileManager.default.fileExists(atPath: marker.path) && profileRow.isSelectedRow,
            "clicking a profile row must select it without opening a separate window")
        let firstProfileMenu = firstRunController.actionsMenu(for: .profile("work"))
        let profileArguments = try await launchArguments(recordedIn: marker, until: { profileClosed },
            "a profile menu launch must dismiss the menu and record its arguments") {
            firstProfileMenu.performActionForItem(at: firstProfileMenu.indexOfItem(withTitle: "Open in ChatGPT"))
        }
        expect(profileArguments == "app\nwork\n", "a profile must open without supplying a workspace path")
        expect(store.workspaces.isEmpty, "opening a profile must not create a workspace binding")
        store.loadPreview([], profiles: [])
        expect(descendants(firstRunController.view).compactMap { $0 as? NSButton }.contains { $0.title == "Create profile…" },
            "first-run setup must ask for a profile rather than a project folder")

        let missing = workspace("/projects/missing", exists: false)
        let first = workspace("/projects/first")
        let last = workspace("/projects/last")
        store.loadPreview([first, missing, last], usage: ["work": quota])
        store.togglePin(first)
        let controller = WorkspaceMenuViewController(store: store, defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 480), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(controller.preferredContentSize)
        controller.view.layoutSubtreeIfNeeded()
        controller.focusMenu()
        expect(controller.preferredContentSize.width == 400, "popover must retain compact reference width")
        let allViews = descendants(controller.view)
        expect(!(controller.view is NSVisualEffectView) && !allViews.contains { $0 is NSVisualEffectView },
            "NSPopover must own its background material without a duplicate effect layer")
        let title = allViews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Codex Profiles" }!
        let options = allViews.compactMap { $0 as? NSButton }.first { $0.toolTip == "Options" }!
        let titleCenter = controller.view.convert(NSPoint(x: title.bounds.midX, y: title.bounds.midY), from: title)
        let optionsCenter = controller.view.convert(NSPoint(x: options.bounds.midX, y: options.bounds.midY), from: options)
        expect(abs(titleCenter.y - optionsCenter.y) < 1, "title and options must share one compact header line")
        let headerIcon = title.superview!.subviews.compactMap { $0 as? NSImageView }.first!
        expect(isMonochrome(headerIcon.contentTintColor), "header symbol must use native monochrome tint")
        expect(!allViews.contains { $0 is NSSearchField }, "menu must omit the Search field")
        expect(!controller.handleShortcut(key(40, characters: "k", modifiers: .command)), "Command-K must no longer focus Search")
        expect(allViews.contains { $0 is NSPopUpButton }, "profile filter must remain available")
        expect(allViews.contains { $0 is NSSegmentedControl }, "launch destination must remain available")
        var initialRows = descendants(controller.view).compactMap { $0 as? LaunchRowButton }
        let list = descendants(controller.view).compactMap { $0 as? NSScrollView }.first!
        let listWidth = list.contentView.bounds.width
        expect(initialRows.count == 4, "initialized profiles and all bindings must be rendered")
        expect(list.documentView!.bounds.height <= list.contentView.bounds.height + 1,
            "a short list must fit without clipping the last row or needing to scroll")
        expect(initialRows.allSatisfy { abs($0.frame.width - listWidth) < 1 }, "workspace rows must fill the list width")
        let separators = descendants(list).compactMap { $0 as? NSBox }.filter { $0.boxType == .separator }
        expect(separators.count >= initialRows.count - 1, "workspace rows must have native separators")
        expect(separators.allSatisfy { abs($0.frame.width - listWidth) < 1 }, "row separators must fill the list width")
        let profileUsage = descendants(initialRows[0]).compactMap { $0 as? ProfileUsageView }.first!
        let profileName = descendants(initialRows[0]).compactMap { $0 as? NSTextField }.first { $0.stringValue == "work" }!
        let profileSwitch = descendants(initialRows[0]).compactMap { $0 as? NSButton }.first { $0.title == "Switch" }!
        let nameFrame = initialRows[0].convert(profileName.bounds, from: profileName)
        let usageFrame = initialRows[0].convert(profileUsage.bounds, from: profileUsage)
        let openFrame = initialRows[0].convert(profileSwitch.bounds, from: profileSwitch)
        expect(usageFrame.width == ProfileUsageView.columnWidth && nameFrame.maxX <= usageFrame.minX && usageFrame.maxX < openFrame.minX,
            "quota must fit beside the profile without obscuring its name or Switch button")
        expect(allViews.compactMap { $0 as? NSButton }.contains { $0.title == "Add profile…" },
            "footer must offer profile creation beside Add workspace")
        for row in initialRows where row.item.workspace != nil {
            expect(!descendants(row).contains { $0 is ProfileUsageView }, "workspace rows must not duplicate account quota")
            let workspace = row.item.workspace!
            let labels = descendants(row).compactMap { $0 as? NSTextField }
            let name = labels.first { $0.stringValue == workspace.name }!
            let path = labels.first { $0.stringValue == "\(workspace.profile) · \(workspace.displayPath())" }!
            expect(abs(row.convert(name.bounds.origin, from: name).x - row.convert(path.bounds.origin, from: path).x) < 1,
                "workspace profile and path must align with project title")
            let icon = descendants(row).compactMap { $0 as? NSImageView }.first!
            expect(isMonochrome(icon.contentTintColor), "folder and pin symbols must use native monochrome tint")
            let open = openButton(in: row)
            expect(open.controlSize == .small, "explicit Open action must use a compact native button")
            expect(open.isEnabled == workspace.isAvailable, "Open availability must match workspace availability")
            expect(abs(row.frame.height - (workspace.isAvailable ? 56 : 72)) < 1,
                "rows must remain compact while leaving space for missing-folder guidance")
        }
        expect(initialRows.allSatisfy { !$0.isSelectedRow }, "opening must not paint an unsolicited grey selection")
        try? FileManager.default.removeItem(at: marker)
        let avatar = descendants(initialRows[0]).compactMap { $0 as? NSButton }.first { $0.toolTip == "Account info for work" }!
        avatar.performClick(nil)
        let infoLabels = descendants(controller.view).compactMap { $0 as? NSTextField }.map(\.stringValue)
        expect(infoLabels.contains("Account info") && infoLabels.contains("Profile work")
            && infoLabels.contains("5h  ·  77% remaining") && infoLabels.contains("W (7d)  ·  9% remaining")
            && infoLabels.contains { $0.hasPrefix("Checked ") }
            && !FileManager.default.fileExists(atPath: marker.path),
            "avatar must open account info with quota and last check without launching")
        expect(descendants(controller.view).compactMap { $0 as? LaunchRowButton }.isEmpty,
            "account info must replace the profile list")
        let back = descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Back" }!
        back.performClick(nil)
        initialRows = descendants(controller.view).compactMap { $0 as? LaunchRowButton }
        expect(initialRows.count == 4 && back.isHidden, "Back must restore the profile list")
        controller.focusMenu()
        expect(initialRows.first(where: { $0.item.workspace == missing })?.isEnabled == false, "missing workspace must not launch")
        expect(descendants(initialRows.first(where: { $0.item.workspace == missing })!).contains { ($0 as? NSButton)?.toolTip?.contains("remove binding") == true }, "missing rows must retain an actions button")
        expect(controller.handleShortcut(key(125)), "down arrow must be handled")
        expect(initialRows.first?.item == .profile("work") && initialRows.first?.isSelectedRow == true,
            "first down arrow must select the profile before optional workspaces")
        expect(controller.handleShortcut(key(125)), "next down arrow must be handled")
        expect(initialRows.first(where: { $0.item.workspace == first })?.isSelectedRow == true,
            "next down arrow must select the first available workspace")
        expect(controller.handleShortcut(key(125)), "second down arrow must be handled")
        expect(initialRows.first(where: { $0.item.workspace == last })?.isSelectedRow == true, "arrow must skip unavailable workspace")
        expect(controller.handleShortcut(key(126)), "up arrow must be handled")
        expect(initialRows.first(where: { $0.item.workspace == first })?.isSelectedRow == true, "up arrow must restore prior selection")
        let actions = descendants(initialRows.first { $0.item.workspace == first }!).compactMap { $0 as? NSButton }.first { $0.toolTip?.contains("remove binding") == true }!
        window.makeFirstResponder(actions)
        expect(!controller.handleShortcut(key(36)), "Return on an actions button must retain its native action")
        expect(!controller.handleShortcut(key(125)), "arrows on a native control must retain native behaviour")
        controller.focusMenu()
        expect(initialRows.allSatisfy { !$0.isSelectedRow }, "reopening the menu must clear old selection")
        expect(controller.handleShortcut(key(126)), "up arrow must be handled from an unselected list")
        expect(initialRows.first(where: { $0.item.workspace == last })?.isSelectedRow == true,
            "first up arrow must select the last available workspace")
        controller.focusMenu()
        var closed = false
        controller.onRequestClose = { closed = true }
        expect(controller.handleShortcut(key(53)), "escape must be handled")
        expect(closed, "escape must request popover close")
        closed = false
        controller.focusMenu()
        _ = controller.handleShortcut(key(125))
        _ = controller.handleShortcut(key(125))
        _ = controller.handleShortcut(key(125))
        let args = try await launchArguments(recordedIn: marker, until: { closed },
            "successful Return launch must dismiss popover and record its arguments") { _ = controller.handleShortcut(key(36)) }
        expect(args.contains(last.path), "Return must launch selected available workspace")
        expect(!args.contains(missing.path), "keyboard launch must skip missing workspace")
        closed = false
        let firstRow = descendants(controller.view).compactMap { $0 as? LaunchRowButton }.first { $0.item.workspace == first }!
        let clickArgs = try await launchArguments(recordedIn: marker, until: { closed },
            "successful explicit Open action must dismiss popover and record its arguments") { openButton(in: firstRow).performClick(nil) }
        expect(clickArgs.contains(first.path), "Open must launch its own workspace")
        expect(!clickArgs.contains(last.path), "Open must replace the prior launch arguments")
        controller.focusMenu()
        closed = false
        let shortcutArguments = try await launchArguments(recordedIn: marker, until: { closed },
            "Command-1 must dismiss popover and record its arguments") {
            _ = controller.handleShortcut(key(18, characters: "1", modifiers: .command))
        }
        expect(shortcutArguments == "app\nwork\n", "Command-1 must open the first visible profile without a folder")
        let selectedRow = descendants(controller.view).compactMap { $0 as? LaunchRowButton }.first!
        expect(controller.view.appearance == nil && selectedRow.appearance == nil,
            "menu views must inherit the system appearance")
        selectedRow.isSelectedRow = true
        expect(selectedRow.isAccessibilitySelected(), "keyboard selection must be exposed to accessibility clients")
        selectedRow.displayIfNeeded()
        let expectedBorder = selectedRow.layer!.borderColor!
        selectedRow.layer!.borderColor = NSColor.clear.cgColor
        NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
        expect(selectedRow.layer!.borderColor == expectedBorder,
            "changing the system accent colours must update custom row decoration")
        selectedRow.layer!.borderColor = NSColor.clear.cgColor
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: NSWorkspace.shared)
        expect(selectedRow.layer!.borderColor == expectedBorder,
            "changing accessibility display options must update custom row decoration")
        var borders: [CGFloat] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            window.appearance = NSAppearance(named: appearance)
            expect(selectedRow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance,
                "an open menu must inherit light and dark appearance changes")
            selectedRow.displayIfNeeded()
            selectedRow.updateLayer()
            let border = NSColor(cgColor: selectedRow.layer!.borderColor!)!.usingColorSpace(.sRGB)!
            borders.append(border.redComponent)
            expect(selectedRow.layer!.borderWidth > 0, "keyboard selection must include a shape cue rather than relying on colour")
            for preferences in [(true, false), (false, true), (true, true)] {
                selectedRow.updateSystemColours(reduceTransparency: preferences.0, increaseContrast: preferences.1)
                expect(selectedRow.layer!.backgroundColor!.alpha > 0.99,
                    "reduced transparency and increased contrast must use opaque system selection colours")
            }
        }
        expect(borders[0] < 0.5 && borders[1] > 0.5 && borders[2] < 0.5,
            "custom row decoration must resolve semantic colours again when appearance changes")
        let expired = ProfileUsage.available(CodexRateLimits(windows: [RateLimitWindow(usedPercent: 80, windowDurationMins: nil, resetsAt: 1)]), checkedAt: checkedAt)
        store.loadPreview([], profiles: ["very-long-profile-name-for-a-client", "work"], usage: [
            "work": expired, "very-long-profile-name-for-a-client": .unavailable(checkedAt: checkedAt),
        ])
        window.setContentSize(controller.preferredContentSize)
        controller.view.layoutSubtreeIfNeeded()
        let quotaRows = descendants(controller.view).compactMap { $0 as? LaunchRowButton }
        expect(descendants(quotaRows[0]).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Unavailable" },
            "missing quota must say Unavailable rather than zero")
        expect(descendants(quotaRows[0]).compactMap { $0 as? NSButton }.first { $0.title == "Switch" }?.isEnabled == true,
            "unavailable quota must not disable Switch")
        expect(descendants(quotaRows[1]).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "—" },
            "a passed reset must not show stale percentages")
        let longName = descendants(quotaRows[0]).compactMap { $0 as? NSTextField }.first { $0.stringValue == "very-long-profile-name-for-a-client" }!
        expect(longName.lineBreakMode == .byTruncatingTail && longName.toolTip == longName.stringValue,
            "long profile names must truncate while retaining the full name on hover")
        store.loadPreview((0..<12).map { workspace("/projects/project-\($0)") })
        window.setContentSize(controller.preferredContentSize)
        controller.view.layoutSubtreeIfNeeded()
        let longList = descendants(controller.view).compactMap { $0 as? NSScrollView }.first!
        expect(controller.preferredContentSize.height == 500, "long lists must retain the compact height limit")
        expect(longList.documentView!.bounds.height > longList.contentView.bounds.height,
            "projects beyond the height limit must remain in the scrollable document")

        // Usage readings stream in after opening; they must not rebuild the list.
        store.loadPreview([first], profiles: ["work", "personal"], usage: ["work": quota])
        let picker = descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first!
        let pickerItem = picker.item(at: 1)
        let stableRow = descendants(controller.view).compactMap { $0 as? LaunchRowButton }.first { $0.item == .profile("work") }!
        let lowQuota = ProfileUsage.available(CodexRateLimits(windows: [
            RateLimitWindow(usedPercent: 95, windowDurationMins: 300, resetsAt: checkedAt.addingTimeInterval(4320).timeIntervalSince1970),
        ]), checkedAt: checkedAt)
        store.loadPreview([first], profiles: ["work", "personal"], usage: ["work": lowQuota], readingUsage: ["work"])
        let updatedRow = descendants(controller.view).compactMap { $0 as? LaunchRowButton }.first { $0.item == .profile("work") }!
        expect(updatedRow === stableRow && picker.item(at: 1) === pickerItem,
            "a usage reading must update rows in place without rebuilding the list or the profile filter")
        let updatedText = descendants(updatedRow).compactMap { $0 as? NSTextField }.map(\.stringValue)
        expect(updatedText.contains("5%") && updatedText.contains { $0.hasPrefix("5h limit low · resets in ") },
            "the row must show the newer reading and when the low window resets")
        let refreshingUsage = descendants(updatedRow).compactMap { $0 as? ProfileUsageView }.first!
        expect(refreshingUsage.arrangedSubviews.allSatisfy { $0.alphaValue < 1 } && refreshingUsage.toolTip!.contains("Refreshing"),
            "a refresh must dim the previous reading rather than hide it")
        expect(descendants(refreshingUsage).contains { $0 is QuotaMeter }, "each quota window must have a meter beside its percentage")

        // A row whose binding is changing shows progress and refuses launches.
        store.loadPreview([first, last], profiles: ["work"], usage: ["work": quota], changingPaths: [last.path])
        let changingRow = descendants(controller.view).compactMap { $0 as? LaunchRowButton }.first { $0.item.workspace == last }!
        expect(!changingRow.isEnabled && openButton(in: changingRow).title == "Updating…" && !openButton(in: changingRow).isEnabled,
            "a row being changed must show progress and refuse launches")
        expect(descendants(changingRow).compactMap { $0 as? NSButton }.first { $0.toolTip?.contains("remove binding") == true }?.isEnabled == false,
            "a row being changed must not accept another change")
        controller.focusMenu()
        _ = controller.handleShortcut(key(125))
        _ = controller.handleShortcut(key(125))
        _ = controller.handleShortcut(key(125))
        expect(changingRow.isSelectedRow == false, "keyboard selection must skip a row being changed")

        // Disabled actions stay disabled through AppKit's menu validation.
        store.loadPreview([first, missing], profiles: ["work", "personal"])
        let missingMenu = controller.actionsMenu(for: .workspace(missing))
        missingMenu.update()
        expect(!item("Show in Finder", in: missingMenu).isEnabled && !item("Open in ChatGPT", in: missingMenu).isEnabled
            && !item("Open in Terminal", in: missingMenu).isEnabled,
            "a missing folder must not be revealed or opened from its actions")
        expect(item("Change profile", in: missingMenu).submenu!.items.allSatisfy { !$0.isEnabled }, "a missing folder cannot be reassigned")
        expect(item("Locate moved folder…", in: missingMenu).isEnabled, "a missing folder must remain repairable")
        let firstMenu = controller.actionsMenu(for: .workspace(first))
        let choices = item("Change profile", in: firstMenu).submenu!
        choices.update()
        expect(choices.items.first { $0.title == "work" }?.isEnabled == false && choices.items.first { $0.title == "personal" }?.isEnabled == true,
            "only another profile may be chosen")
        let profileMenu = controller.actionsMenu(for: .profile("work"))
        expect(["Open in ChatGPT", "Open in Terminal", "Add workspace…", "Sign in to Codex CLI…", "Remove profile…"].allSatisfy { item($0, in: profileMenu).isEnabled },
            "profile actions must offer launches, removal and CLI sign-in")
        expect(profileMenu.items.allSatisfy { $0.title != "Switch to default…" },
            "Switch to default must move from the menu to the profile row")
        let defaultMenu = controller.actionsMenu(for: .profile("default"))
        expect(defaultMenu.items.allSatisfy { $0.title != "Switch to default…" && $0.title != "Remove profile…" },
            "the stock default profile must not offer switching or removal")
        store.loadPreview([], profiles: ["default", "work"])
        let defaultRow = descendants(controller.view).compactMap { $0 as? LaunchRowButton }.first { $0.item == .profile("default") }!
        expect(!descendants(defaultRow).compactMap { $0 as? NSButton }.contains { $0.title == "Switch" || $0.title == "Open" },
            "default profile must have no primary action button")
        let workRow = descendants(controller.view).compactMap { $0 as? LaunchRowButton }.first { $0.item == .profile("work") }!
        let workCheck = descendants(workRow).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Include work in automatic switching" }!
        workCheck.performClick(nil)
        expect(store.isAutoSelected("work"), "profile checkbox must persist automatic-switch participation")
        let autoCheck = descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Auto switch profiles" }!
        autoCheck.performClick(nil)
        expect(store.autoSwitchEnabled, "footer checkbox must enable automatic switching")
        defaults.set("work", forKey: "activeDefaultProfile")
        store.loadPreview([], profiles: ["default", "work"], usage: ["default": quota, "work": quota])
        let activeRow = descendants(controller.view).compactMap { $0 as? LaunchRowButton }.first { $0.item == .profile("work") }!
        expect(!descendants(activeRow).compactMap { $0 as? NSButton }.contains { $0.title == "Switch" },
            "the current profile must hide its Switch button")
        let activeAvatar = descendants(activeRow).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Account info for work" }!
        activeAvatar.performClick(nil)
        let slider = descendants(controller.view).compactMap { $0 as? NSSlider }.first!
        slider.integerValue = 30
        _ = slider.sendAction(slider.action, to: slider.target)
        expect(store.autoThreshold(for: "work") == 30, "Info slider must save its per-profile quota threshold")

        // A row action opens the other destination without changing the default.
        defaults.set(OpenDestination.terminal.rawValue, forKey: "openDestination")
        let login = FakeLoginItem()
        let terminalController = WorkspaceMenuViewController(store: store, defaults: defaults, loginItem: login)
        _ = terminalController.view
        var terminalClosed = false
        terminalController.onRequestClose = { terminalClosed = true }
        let alternate = terminalController.actionsMenu(for: .profile("work"))
        let alternateArguments = try await launchArguments(recordedIn: marker, until: { terminalClosed },
            "Open in ChatGPT must dismiss the menu and record its arguments") {
            alternate.performActionForItem(at: alternate.indexOfItem(withTitle: "Open in ChatGPT"))
        }
        expect(alternateArguments == "app\nwork\n", "Open in ChatGPT must launch ChatGPT while Terminal stays the default")
        expect(defaults.string(forKey: "openDestination") == OpenDestination.terminal.rawValue, "a row action must not change the default destination")

        // Open at Login reflects and changes the login item.
        var settings = terminalController.settingsMenu()
        expect(item("Open at Login", in: settings).state == .off, "Open at Login must start off")
        settings.performActionForItem(at: settings.indexOfItem(withTitle: "Open at Login"))
        expect(login.status == .enabled && item("Open at Login", in: terminalController.settingsMenu()).state == .on,
            "choosing Open at Login must register the app")
        settings = terminalController.settingsMenu()
        settings.performActionForItem(at: settings.indexOfItem(withTitle: "Open at Login"))
        expect(login.status == .disabled && !login.openedSettings, "choosing it again must unregister the app")
        login.statusAfterRegister = .requiresApproval
        settings = terminalController.settingsMenu()
        settings.performActionForItem(at: settings.indexOfItem(withTitle: "Open at Login"))
        expect(login.openedSettings && item("Open at Login", in: terminalController.settingsMenu()).state == .mixed,
            "a login item awaiting approval must open Login Items settings and show a mixed state")

        // Low-quota alerts start off and ask for permission only when chosen.
        // Fresh readings keep the background pass from starting a reader.
        store.loadPreview([], profiles: ["work"], usage: ["work": quota])
        let notifier = FakeNotifier()
        let alerts = QuotaAlertController(store: store, notifier: notifier, defaults: defaults, refreshInterval: 3600)
        let alertsController = WorkspaceMenuViewController(store: store, defaults: defaults, loginItem: login, alerts: alerts)
        _ = alertsController.view
        alerts.start()
        settings = alertsController.settingsMenu()
        settings.update()
        expect(item("Low-quota alerts", in: settings).state == .off && item("Low-quota alerts", in: settings).isEnabled
            && notifier.requests == 0 && notifier.permissionChecks == 0,
            "Low-quota alerts must start off without touching notification permission")
        expect(!terminalController.settingsMenu().items.contains { $0.title == "Low-quota alerts" },
            "the toggle needs an alerts controller")
        settings.performActionForItem(at: settings.indexOfItem(withTitle: "Low-quota alerts"))
        try await waitUntil { store.statusMessage.hasPrefix("Low-quota alerts") }
        expect(alerts.isEnabled && notifier.requests == 1 && item("Low-quota alerts", in: alertsController.settingsMenu()).state == .on
            && store.statusMessage == "Low-quota alerts on · usage checked every 5 minutes",
            "choosing Low-quota alerts must ask once, turn alerts on and say how often usage is checked")
        expect(defaults.bool(forKey: "lowQuotaAlerts"), "the choice must persist")
        notifier.current = .notDetermined
        await alerts.refreshPermission()
        expect(item("Low-quota alerts", in: alertsController.settingsMenu()).state == .mixed,
            "alerts on without a permission answer must show the same mixed state as a denial")
        notifier.current = .denied
        await alerts.refreshPermission()
        let revoked = item("Low-quota alerts", in: alertsController.settingsMenu())
        expect(revoked.state == .mixed && revoked.toolTip?.contains("System Settings › Notifications") == true,
            "revoked notification permission must show a mixed state that explains where to allow it")
        settings = alertsController.settingsMenu()
        settings.performActionForItem(at: settings.indexOfItem(withTitle: "Low-quota alerts"))
        try await waitUntil { !alerts.isEnabled }
        expect(!alerts.isEnabled && !store.isRefreshingUsageInBackground && item("Low-quota alerts", in: alertsController.settingsMenu()).state == .off,
            "choosing it again must turn alerts and background reads off")

        // Screenshot mode masks visible profile names while keeping actions bound to real profiles.
        let privacyStore = WorkspaceStore(client: CLIClient(executableURL: executable), defaults: defaults)
        privacyStore.loadPreview([first], profiles: ["default", "work"], usage: ["work": quota])
        let privacyController = WorkspaceMenuViewController(store: privacyStore, defaults: defaults)
        _ = privacyController.view
        var visibilityChanges = 0
        privacyController.onProfileNameVisibilityChange = { visibilityChanges += 1 }
        let hideMenu = privacyController.settingsMenu()
        hideMenu.performActionForItem(at: hideMenu.indexOfItem(withTitle: "Hide profile names"))
        expect(defaults.bool(forKey: "hideProfileNames") && visibilityChanges == 1,
            "Hide profile names must persist and update the status item")
        let hiddenLabels = descendants(privacyController.view).compactMap { $0 as? NSTextField }.map(\.stringValue)
        expect(hiddenLabels.contains("••••") && !hiddenLabels.contains("work") && !hiddenLabels.contains("default")
            && !hiddenLabels.contains { $0.hasPrefix("work · ") },
            "screenshot mode must mask profile names in rows and workspace metadata")
        let hiddenPicker = descendants(privacyController.view).compactMap { $0 as? NSPopUpButton }.first!
        expect(hiddenPicker.item(at: 1)?.title == "•••• 1" && hiddenPicker.item(at: 2)?.title == "•••• 2",
            "profile filter must not reveal names in screenshot mode")
        hiddenPicker.selectItem(at: 2)
        _ = hiddenPicker.sendAction(hiddenPicker.action, to: hiddenPicker.target)
        expect(privacyStore.selectedProfile == "work", "masked filter must still select the real profile")
        let hiddenSignIn = item("Sign in to Codex CLI", in: privacyController.settingsMenu()).submenu!
        expect(hiddenSignIn.items.map(\.title) == ["•••• 1", "•••• 2"]
            && hiddenSignIn.items[1].representedObject as? String == "work",
            "masked menu entries must keep their real profile targets")
        let maskedRow = descendants(privacyController.view).compactMap { $0 as? LaunchRowButton }.first { $0.item == .profile("work") }!
        let maskedAvatar = descendants(maskedRow).compactMap { $0 as? NSButton }.first { $0.toolTip == "Account info for ••••" }!
        maskedAvatar.performClick(nil)
        let maskedInfo = descendants(privacyController.view).compactMap { $0 as? NSTextField }.map(\.stringValue)
        expect(maskedInfo.contains("Profile ••••") && !maskedInfo.contains("Profile work"),
            "account info must respect Hide profile names")
        descendants(privacyController.view).compactMap { $0 as? NSButton }.first { $0.title == "Back" }!.performClick(nil)
        let showMenu = privacyController.settingsMenu()
        showMenu.performActionForItem(at: showMenu.indexOfItem(withTitle: "Show profile names"))
        expect(!defaults.bool(forKey: "hideProfileNames") && visibilityChanges == 2
            && descendants(privacyController.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "work" },
            "Show profile names must restore the visible names")

        // The status icon stays a labelled template image; low quota changes
        // its shape, never only its colour.
        let icons = [QuotaLevel.normal, .low, .critical].map { StatusItemIcon.image(for: $0, accessibilityDescription: "Codex Profiles. Low Codex quota: work") }
        expect(icons.allSatisfy { $0.isTemplate && $0.accessibilityDescription == "Codex Profiles. Low Codex quota: work" },
            "every icon state must be a template image carrying the accessibility label")
        // The badge fills the bottom-right 9-point square. Points name pixel
        // centres in its middle column: the bar, the gap, the dot, and a point
        // of solid badge beside the column.
        expect(icons[1].size.width > icons[0].size.width && StatusItemIcon.badgeDiameter == 9, "a badge must widen the icon")
        let column = icons[1].size.width - 4.5
        let bar = NSPoint(x: column, y: 5.5)
        let gap = NSPoint(x: column, y: 2.5)
        let dot = NSPoint(x: column, y: 1.5)
        let beside = NSPoint(x: column - 2, y: 4.5)
        for scale in [1, 2] {
            expect([bar, gap, dot, beside].allSatisfy { alpha(icons[1], at: $0, scale: scale) > 0.9 },
                "a low quota must add a solid badge at \(scale)x")
            expect(alpha(icons[2], at: bar, scale: scale) < 0.1 && alpha(icons[2], at: dot, scale: scale) < 0.1
                && alpha(icons[2], at: gap, scale: scale) > 0.9 && alpha(icons[2], at: beside, scale: scale) > 0.9,
                "a critical quota must cut a bar and a separate dot into the badge at \(scale)x")
        }
        let signalHome = root.appendingPathComponent("signal-home")
        let sessionDirectory = signalHome.appendingPathComponent(".codex/sessions/2026/10/15")
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let sessionFile = sessionDirectory.appendingPathComponent("rollout.jsonl")
        try Data("{}\n".utf8).write(to: sessionFile)
        let sessionMonitor = SessionQuotaMonitor()
        var observedSignal: SessionQuotaSignal?
        sessionMonitor.onSignal = { profile, signal in
            if profile == "default" { observedSignal = signal }
        }
        sessionMonitor.update(profiles: ["default"], home: signalHome)
        let sessionHandle = try FileHandle(forWritingTo: sessionFile)
        try sessionHandle.seekToEnd()
        try sessionHandle.write(contentsOf: Data(#"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":96},"secondary":{"used_percent":78}}}}"#.utf8))
        try sessionHandle.write(contentsOf: Data("\n".utf8))
        try sessionHandle.close()
        for _ in 0..<40 where observedSignal == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        expect(observedSignal?.remainingPercent == 4,
            "the session listener must deliver quota changes from an active session without a network poll")
        sessionMonitor.stop()
        print("Native menu interaction tests passed.")
    }

    @MainActor
    private final class FakeNotifier: QuotaNotifying {
        var current = NotificationPermission.notDetermined
        var permissionChecks = 0
        var requests = 0
        func permission() async -> NotificationPermission { permissionChecks += 1; return current }
        func requestPermission() async -> Bool { requests += 1; current = .allowed; return true }
        func post(_ notification: QuotaNotification) {}
    }

    /// Alpha of an image at a point, rendered at 1x like a standard display or
    /// 2x like a Retina menu bar.
    private static func alpha(_ image: NSImage, at point: NSPoint, scale: Int) -> CGFloat {
        let factor = CGFloat(scale)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * factor), pixelsHigh: Int(image.size.height * factor),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.colorAt(x: Int(point.x * factor), y: Int((image.size.height - point.y) * factor))?.alphaComponent ?? 0
    }

    @MainActor
    private final class FakeLoginItem: LoginItemControlling {
        var status = LoginItemStatus.disabled
        var statusAfterRegister = LoginItemStatus.enabled
        var openedSettings = false
        func register() throws { status = statusAfterRegister }
        func unregister() throws { status = .disabled }
        func openSystemSettings() { openedSettings = true }
    }

    private static func item(_ title: String, in menu: NSMenu) -> NSMenuItem {
        guard let item = menu.items.first(where: { $0.title == title }) else { fatalError("missing menu item: \(title)") }
        return item
    }

    private static func workspace(_ path: String, exists: Bool = true) -> WorkspaceBinding {
        WorkspaceBinding(path: path, profile: "work", pathExists: exists, profileExists: true)
    }
    private static func key(_ code: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
    private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
    private static func openButton(in row: LaunchRowButton) -> NSButton {
        descendants(row).compactMap { $0 as? NSButton }.first { ["Open", "Opening…", "Updating…"].contains($0.title) }!
    }
    /// Polls until a condition holds or 10 seconds pass. Work usually settles
    /// within milliseconds; the bound only absorbs a loaded machine, and the
    /// caller's next expectation reports a condition that never held.
    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    }
    /// Clears the shim's marker, runs a launch and returns the arguments the
    /// shim recorded. The menu closes only after the launch process exits, so
    /// a closed menu and a non-empty marker mean the arguments are complete.
    private static func launchArguments(recordedIn marker: URL, until closed: () -> Bool, _ message: String,
                                        launch: () -> Void) async throws -> String {
        try? FileManager.default.removeItem(at: marker)
        launch()
        var arguments = ""
        try await waitUntil {
            arguments = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
            return closed() && !arguments.isEmpty
        }
        expect(closed() && !arguments.isEmpty, message + " within 10 seconds")
        return arguments
    }
    private static func isMonochrome(_ color: NSColor?) -> Bool {
        color == .labelColor || color == .secondaryLabelColor
    }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }
}
