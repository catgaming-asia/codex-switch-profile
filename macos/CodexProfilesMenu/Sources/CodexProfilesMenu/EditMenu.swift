import AppKit

/// The app is an accessory with no menu bar, so nothing owns the Edit key
/// equivalents: Command-V never reaches a focused text field while right-click
/// Paste, which the field editor answers itself, still works. This menu is the
/// main menu's only content; its items have no target, so AppKit sends each
/// action down the responder chain to whichever text field is focused.
@MainActor
final class EditMenu {
    func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "AI Profile")
        main.addItem(appItem)
        let editItem = NSMenuItem()
        editItem.submenu = makeEditMenu()
        main.addItem(editItem)
        return main
    }

    func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        let entries: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Undo", Selector(("undo:")), "z", .command),
            ("Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("Cut", #selector(NSText.cut(_:)), "x", .command),
            ("Copy", #selector(NSText.copy(_:)), "c", .command),
            ("Paste", #selector(NSText.paste(_:)), "v", .command),
            ("Select All", #selector(NSText.selectAll(_:)), "a", .command),
        ]
        for (index, entry) in entries.enumerated() {
            if index == 2 { menu.addItem(.separator()) }
            let item = NSMenuItem(title: entry.0, action: entry.1, keyEquivalent: entry.2)
            item.keyEquivalentModifierMask = entry.3
            menu.addItem(item)
        }
        return menu
    }
}
