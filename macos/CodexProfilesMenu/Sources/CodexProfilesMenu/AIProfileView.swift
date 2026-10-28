import AppKit
import Combine
import SwiftUI

private struct AIProfileHeader: View {
    @ObservedObject var settings: AIProfileSettings

    var body: some View {
        HStack(spacing: 8) {
            Picker("Provider", selection: $settings.tab) {
                Text("Codex").tag(PopupTab.codex)
                Text("Claude").tag(PopupTab.claude)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Menu {
                Picker("Menu bar", selection: $settings.menuBarProvider) {
                    ForEach(MenuBarProvider.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Menu bar: \(settings.menuBarProvider.title)", systemImage: "menubar.rectangle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose which provider’s usage appears in the menu bar")
            .accessibilityLabel("Menu bar provider: \(settings.menuBarProvider.title)")
        }
        .padding(.horizontal, 12)
        .frame(width: 400, height: 40)
    }
}

private struct ClaudeQuotaRow: View {
    let window: ClaudeQuotaWindow
    let now: Date

    private var tint: Color {
        switch window.level {
        case .normal: return .green
        case .low: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        let reset = window.hasReset(at: now)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(reset ? "Awaiting reading" : "\(window.remainingPercent)% left")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            ProgressView(value: reset ? 0 : Double(window.remainingPercent), total: 100).tint(tint)
            Text(window.resetDescription(at: now)).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ClaudePane: View {
    @ObservedObject var store: ClaudeUsageStore

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 12) {
            switch store.state {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking Claude usage…").foregroundStyle(.secondary)
                }
            case let .unavailable(reason):
                VStack(alignment: .leading, spacing: 4) {
                    Label(reason.title, systemImage: "exclamationmark.triangle").font(.system(size: 13, weight: .semibold))
                    Text(reason.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            case let .available(snapshot):
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.account.email ?? "Claude Code account").font(.system(size: 13, weight: .semibold))
                    let detail = [snapshot.account.plan.map { "Claude \($0.capitalized)" }, snapshot.account.organization]
                        .compactMap { $0 }.joined(separator: " · ")
                    if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                ForEach(snapshot.windows, id: \.id) { ClaudeQuotaRow(window: $0, now: now) }
                Text("Subscription quota for the signed-in Claude Code account, not token cost. Checked \(UsageFormat.clock(snapshot.checkedAt, relativeTo: now)).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button { Task { await store.refresh(force: true) } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .padding(16)
        .frame(width: 400, height: 300, alignment: .topLeading)
    }
}

/// Hosts the provider tabs. The Codex tab keeps the existing profile list,
/// Switch and Auto controls untouched; the Claude tab is read-only.
@MainActor
final class AIProfileViewController: NSViewController {
    private let codex: WorkspaceMenuViewController
    private let settings: AIProfileSettings
    private let claude: ClaudeUsageStore
    private let headerHeight: CGFloat = 40
    private let claudeHeight: CGFloat = 300
    private var claudeView: NSView?
    var onPreferredContentSizeChange: ((NSSize) -> Void)?

    init(codex: WorkspaceMenuViewController, settings: AIProfileSettings, claude: ClaudeUsageStore) {
        self.codex = codex
        self.settings = settings
        self.claude = claude
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = size(forTab: settings.tab)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func size(forTab tab: PopupTab) -> NSSize {
        NSSize(width: 400, height: headerHeight + (tab == .codex ? codex.preferredContentSize.height : claudeHeight))
    }

    override func loadView() {
        let root = NSView()
        view = root
        let header = NSHostingView(rootView: AIProfileHeader(settings: settings))
        let claudePane = NSHostingView(rootView: ClaudePane(store: claude))
        claudeView = claudePane
        addChild(codex)
        for subview in [header, codex.view, claudePane] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: headerHeight),
            codex.view.topAnchor.constraint(equalTo: header.bottomAnchor),
            codex.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            claudePane.topAnchor.constraint(equalTo: header.bottomAnchor),
            claudePane.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            claudePane.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            claudePane.heightAnchor.constraint(equalToConstant: claudeHeight),
        ])
        codex.onPreferredContentSizeChange = { [weak self] _ in self?.applyTab(self?.settings.tab ?? .codex) }
        // $tab fires in willSet, so use the published value, not settings.tab.
        settings.$tab.dropFirst().sink { [weak self] tab in self?.applyTab(tab) }.store(in: &subscriptions)
        applyTab(settings.tab)
    }

    private var subscriptions: Set<AnyCancellable> = []

    private func applyTab(_ tab: PopupTab) {
        codex.view.isHidden = tab != .codex
        claudeView?.isHidden = tab != .claude
        preferredContentSize = size(forTab: tab)
        onPreferredContentSizeChange?(preferredContentSize)
        if tab == .claude { Task { await claude.refresh() } }
    }

    func focusMenu() {
        if settings.tab == .codex { codex.focusMenu() }
    }

    func handleShortcut(_ event: NSEvent) -> Bool {
        settings.tab == .codex && codex.handleShortcut(event)
    }
}
