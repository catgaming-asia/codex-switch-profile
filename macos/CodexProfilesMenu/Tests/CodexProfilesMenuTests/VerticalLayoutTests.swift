import AppKit
import Foundation

private struct MemorySecrets: ClaudeSecretStore {
    func save(_ secret: String, id: String) -> Bool { true }
    func exists(id: String) -> Bool { true }
    func delete(id: String) {}
}

/// Geometry smoke for the single vertical panel: three sections stack top-down
/// inside one scroll view at entry, after a quota loads and after a profile is added.
@MainActor
@main
struct VerticalLayoutTests {
    static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let suite = "vertical-layout-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(client: CLIClient(executableURL: nil), defaults: defaults)
        let checkedAt = Date()
        let quota = ProfileUsage.available(CodexRateLimits(windows: [
            RateLimitWindow(usedPercent: 23, windowDurationMins: 300, resetsAt: checkedAt.addingTimeInterval(3600).timeIntervalSince1970),
            RateLimitWindow(usedPercent: 91, windowDurationMins: 10080, resetsAt: checkedAt.addingTimeInterval(86400).timeIntervalSince1970),
        ]), checkedAt: checkedAt)
        let names = (1...8).map { "profile-\($0)" }
        store.loadPreview([], profiles: names, usage: Dictionary(uniqueKeysWithValues: names.map { ($0, quota) }))
        let snapshot = ClaudeSnapshot(account: ClaudeAccount(email: "dev@example.com", organization: nil, plan: "max"), windows: [
            ClaudeQuotaWindow(id: "five_hour", title: "5-hour", shortLabel: "5h", usedPercent: 20, resetsAt: checkedAt.addingTimeInterval(3600)),
            ClaudeQuotaWindow(id: "seven_day", title: "Weekly", shortLabel: "7d", usedPercent: 60, resetsAt: checkedAt.addingTimeInterval(86400)),
        ], checkedAt: checkedAt)
        let claude = ClaudeUsageStore(fetch: { _ in .available(snapshot) })
        let profiles = ClaudeProfileStore(directory: root.appendingPathComponent("claude"), claudeDirectory: root.appendingPathComponent(".claude"),
                                          secrets: MemorySecrets())
        let codex = WorkspaceMenuViewController(store: store, defaults: defaults)
        let settings = AIProfileSettings(defaults: defaults)
        expect(!settings.codexProfilesExpanded && !settings.claudeProfilesExpanded, "both profile sections must default to collapsed")
        let controller = AIProfileViewController(codex: codex, store: store, settings: settings,
                                                 claude: claude, profiles: profiles)
        let window = NSWindow(contentViewController: controller)
        controller.onPreferredContentSizeChange = { window.setContentSize($0) }
        window.setContentSize(controller.preferredContentSize)

        await settle(controller)
        let collapsed = sectionHeights(controller)
        expect(collapsed[1] < 60 && collapsed[2] < 80, "collapsed sections must shrink to their headers: \(collapsed)")
        settings.codexProfilesExpanded = true
        settings.claudeProfilesExpanded = true
        await settle(controller)
        let entry = check("entry", controller)
        // One common scroll view: the Codex list is laid out at its full height, with no scroller or 500-point cap of its own.
        let scrolls = descendants(controller.view).compactMap { $0 as? NSScrollView }
        expect(scrolls.count == 1, "the panel must have a single scroll view, found \(scrolls.count)")
        let expanded = sectionHeights(controller)
        let rows = descendants(controller.view).compactMap { $0 as? LaunchRowButton }
        expect(rows.count == 8 && expanded[1] > 500, "all eight Codex rows must be laid out in full, section height \(expanded[1])")
        let document = scrolls[0].documentView!
        let lastRow = rows.last!.convert(rows.last!.bounds, to: document)
        expect(lastRow.maxY <= document.frame.height + 0.5 && lastRow.height > 20, "the last Codex row must lie inside the common document")
        scrolls[0].contentView.scroll(to: NSPoint(x: 0, y: max(0, lastRow.maxY - scrolls[0].contentView.bounds.height)))
        expect(scrolls[0].contentView.bounds.maxY >= lastRow.maxY - 0.5, "the last Codex row must be reachable with the common scroller")
        scrolls[0].contentView.scroll(to: .zero)
        await claude.refresh(force: true)
        await settle(controller)
        let loaded = check("quota loaded", controller)
        expect(loaded.document > entry.document, "the document must grow when the Claude quota rows load")
        _ = profiles.upsert(ClaudeProfile(id: "api-1", name: "Work API", kind: .api, baseURL: "https://api.anthropic.com", model: "x"), apiKey: "k")
        await settle(controller)
        let added = check("profile added", controller)
        expect(added.document > loaded.document, "the document must grow when a Claude profile is added")
        settings.claudeProfilesExpanded = false
        await settle(controller)
        let claudeFolded = sectionHeights(controller)
        expect(claudeFolded[2] < 80 && claudeFolded[1] > 200, "folding Claude must not fold Codex: \(claudeFolded)")
        expect(!settings.claudeProfilesExpanded && settings.codexProfilesExpanded, "each section keeps its own state")
        let reopened = AIProfileSettings(defaults: defaults)
        expect(reopened.codexProfilesExpanded && !reopened.claudeProfilesExpanded, "section state must persist in defaults")
        print("Vertical layout smoke passed.")
    }

    private static func settle(_ controller: AIProfileViewController) async {
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            controller.view.layoutSubtreeIfNeeded()
        }
    }

    private static func sectionHeights(_ controller: AIProfileViewController) -> [CGFloat] {
        let scroll = descendants(controller.view).compactMap { $0 as? NSScrollView }.first!
        let stack = scroll.documentView!.subviews.first as! NSStackView
        let sections = stack.arrangedSubviews.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        return sections.map { $0.frame.height }
    }

    /// Verifies the rects of the three sections and returns the document and viewport heights.
    private static func check(_ stage: String, _ controller: AIProfileViewController) -> (document: CGFloat, viewport: CGFloat) {
        let scroll = descendants(controller.view).compactMap { $0 as? NSScrollView }.first!
        let document = scroll.documentView!
        let stack = document.subviews.first as! NSStackView
        let sections = stack.arrangedSubviews.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        expect(sections.count == 3, "\(stage): expected In use, Codex and Claude sections")
        let viewport = scroll.contentView.bounds
        expect(viewport.height > 100 && viewport.height <= 560, "\(stage): viewport height \(viewport.height) must be finite and at most 560")
        expect(abs(controller.view.frame.height - viewport.height) < 1, "\(stage): scroll view must fill the popover")
        expect(document.frame.minX >= 0 && document.frame.minY >= 0 && abs(document.frame.width - 400) < 1,
               "\(stage): document frame \(document.frame) must start top-left at width 400")
        expect(viewport.width >= 400 - 0.5, "\(stage): clip width \(viewport.width) crops 400-wide sections, scroller style \(scroll.scrollerStyle.rawValue), view \(controller.view.frame.width)")
        expect(scroll.contentView.bounds.origin.y <= 0.5, "\(stage): content must open scrolled to the top")
        var previousMaxY: CGFloat = 0
        for (index, section) in sections.enumerated() {
            let frame = section.convert(section.bounds, to: document)
            print("\(stage) section \(index): \(frame)")
            expect(frame.minX >= 0 && frame.minY >= 0, "\(stage): section \(index) must stay inside the document origin")
            expect(abs(frame.width - document.frame.width) < 1 && frame.maxX <= document.frame.width + 0.5,
                   "\(stage): section \(index) must span the document width")
            expect(frame.height > 20, "\(stage): section \(index) must have height")
            expect(frame.minY >= previousMaxY - 0.5, "\(stage): section \(index) overlaps the section above")
            previousMaxY = frame.maxY
        }
        expect(previousMaxY <= document.frame.height + 0.5, "\(stage): last section ends beyond the document")
        expect(document.frame.height >= previousMaxY - 0.5, "\(stage): the document must contain every section")
        expect(document.frame.height > viewport.height, "\(stage): fixture content must exceed the viewport so scrolling is exercised")
        // Scroll to the bottom: the last section must then be fully visible.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - viewport.height))
        let last = sections[2].convert(sections[2].bounds, to: document)
        expect(scroll.contentView.bounds.maxY >= last.maxY - 0.5, "\(stage): the Claude profiles section must be reachable by scrolling")
        scroll.contentView.scroll(to: .zero)
        print("\(stage): document \(document.frame.size) viewport \(viewport.size)")
        return (document.frame.height, viewport.height)
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }
}
