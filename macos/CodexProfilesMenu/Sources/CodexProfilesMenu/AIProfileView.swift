import AppKit
import Combine
import SwiftUI

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

/// Live Codex state shown in the "In use" section.
@MainActor
final class CodexCurrentModel: ObservableObject {
    @Published var profile = "default"
    @Published var usage: ProfileUsage?
}

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct CodexCurrentBlock: View {
    @ObservedObject var model: CodexCurrentModel
    @ObservedObject var settings: AIProfileSettings

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Codex", systemImage: "square.stack.3d.up.fill").font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("Show in menu bar", isOn: $settings.showsCodexInMenuBar)
                    .toggleStyle(.checkbox).font(.system(size: 11))
                    .help("Show Codex quota and icon in the menu bar")
            }
            Text(model.profile == "default" ? "Default account" : "Profile \(model.profile)")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if case let .available(limits, _) = model.usage {
                ForEach(Array(limits.windows.enumerated()), id: \.offset) { _, window in
                    HStack {
                        Text(window.durationLabel.map { "\($0) window" } ?? "Window").font(.system(size: 12))
                        Spacer()
                        Text(window.hasReset(at: now) ? "Awaiting reading" : "\(window.remainingPercent)% left")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    }
                }
            } else {
                Text("Usage unavailable").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ClaudeCurrentBlock: View {
    @ObservedObject var store: ClaudeUsageStore
    @ObservedObject var settings: AIProfileSettings

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Claude", systemImage: "sparkles").font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("Show in menu bar", isOn: $settings.showsClaudeInMenuBar)
                    .toggleStyle(.checkbox).font(.system(size: 11))
                    .help("Show Claude quota and icon in the menu bar")
            }
            switch store.state {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking Claude usage…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            case let .unavailable(reason):
                Text(reason.title).font(.system(size: 12, weight: .medium))
                Text(reason.detail).font(.system(size: 11)).foregroundStyle(.secondary)
            case let .available(snapshot):
                let detail = [snapshot.account.email, snapshot.account.plan.map { "Claude \($0.capitalized)" }, snapshot.account.organization]
                    .compactMap { $0 }.joined(separator: " · ")
                Text(detail.isEmpty ? "Claude Code account" : detail).font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(snapshot.windows, id: \.id) { ClaudeQuotaRow(window: $0, now: now) }
                Text("Subscription quota, not token cost. Checked \(UsageFormat.clock(snapshot.checkedAt, relativeTo: now)).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CurrentSection: View {
    @ObservedObject var codex: CodexCurrentModel
    @ObservedObject var claude: ClaudeUsageStore
    @ObservedObject var settings: AIProfileSettings
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "In use")
                Spacer()
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh Claude usage")
                    .disabled(claude.isRefreshing)
            }
            CodexCurrentBlock(model: codex, settings: settings)
            Divider()
            ClaudeCurrentBlock(store: claude, settings: settings)
        }
        .padding(14)
        .frame(width: 400, alignment: .topLeading)
    }
}

/// One vertical scrolling panel: what is in use, then Codex profiles, then
/// Claude profiles. The Codex section keeps its existing list, Switch, Auto and
/// workspace controls untouched.
@MainActor
final class AIProfileViewController: NSViewController {
    private let codex: WorkspaceMenuViewController
    private let codexStore: WorkspaceStore
    private let settings: AIProfileSettings
    private let claude: ClaudeUsageStore
    private let current = CodexCurrentModel()
    private let maxHeight: CGFloat = 560
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var scrollHeight: NSLayoutConstraint?
    var onPreferredContentSizeChange: ((NSSize) -> Void)?

    init(codex: WorkspaceMenuViewController, store: WorkspaceStore, settings: AIProfileSettings, claude: ClaudeUsageStore) {
        self.codex = codex
        codexStore = store
        self.settings = settings
        self.claude = claude
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 400, height: 480)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    override func loadView() {
        let root = NSView()
        view = root
        let section = NSHostingView(rootView: CurrentSection(codex: current, claude: claude, settings: settings) { [weak self] in
            guard let self else { return }
            Task { await self.claude.refresh(force: true) }
        })
        addChild(codex)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for subview in [section, divider(), codex.view] { stack.addArrangedSubview(subview) }
        let document = FlippedView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 480)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 400),
            scrollHeight!,
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalToConstant: 400),
        ])
        codex.onPreferredContentSizeChange = { [weak self] _ in self?.relayout() }
        let previousChange = codexStore.onChange
        codexStore.onChange = { [weak self] in previousChange?(); self?.refreshCurrent() }
        let previousUsage = codexStore.onStatusUsageChange
        codexStore.onStatusUsageChange = { [weak self] in previousUsage?(); self?.refreshCurrent() }
        refreshCurrent()
        relayout()
    }

    /// Mirrors the store's active Codex profile and its default-home reading.
    func refreshCurrent() {
        current.profile = codexStore.activeProfile
        current.usage = codexStore.usage["default"]
        Task { @MainActor in self.relayout() }
    }

    func relayout() {
        view.layoutSubtreeIfNeeded()
        let height = min(maxHeight, stack.fittingSize.height)
        scrollHeight?.constant = height
        preferredContentSize = NSSize(width: 400, height: height)
        onPreferredContentSizeChange?(preferredContentSize)
    }

    func focusMenu() { codex.focusMenu() }

    func handleShortcut(_ event: NSEvent) -> Bool { codex.handleShortcut(event) }
}
