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

private struct CodexQuotaRow: View {
    let window: RateLimitWindow
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
                Text(window.durationLabel.map { "\($0) window" } ?? "Window").font(.system(size: 12, weight: .medium))
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

private struct CodexCurrentBlock: View {
    @ObservedObject var model: CodexCurrentModel
    @ObservedObject var settings: AIProfileSettings

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Codex", systemImage: StatusItemIcon.symbolName).font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("Show in menu bar", isOn: $settings.showsCodexInMenuBar)
                    .toggleStyle(.checkbox).font(.system(size: 11))
                    .help("Show Codex quota and icon in the menu bar")
            }
            if case let .available(limits, _) = model.usage {
                ForEach(Array(limits.windows.enumerated()), id: \.offset) { _, window in
                    CodexQuotaRow(window: window, now: now)
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
    @ObservedObject var profiles: ClaudeProfileStore

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Claude", systemImage: StatusItemIcon.claudeSymbolName).font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("Show in menu bar", isOn: $settings.showsClaudeInMenuBar)
                    .toggleStyle(.checkbox).font(.system(size: 11))
                    .help("Show Claude quota and icon in the menu bar")
            }
            if profiles.current.kind == .api {
                Text("API billing has no subscription quota to show.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
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
                ForEach(snapshot.windows, id: \.id) { ClaudeQuotaRow(window: $0, now: now) }
                Text("Subscription quota, not token cost. Checked \(UsageFormat.clock(snapshot.checkedAt, relativeTo: now)).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            }
        }
    }
}

private struct CurrentSection: View {
    @ObservedObject var codex: CodexCurrentModel
    @ObservedObject var claude: ClaudeUsageStore
    @ObservedObject var settings: AIProfileSettings
    @ObservedObject var profiles: ClaudeProfileStore
    let openSettings: () -> Void
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "In use")
                Spacer()
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh Claude usage")
                    .disabled(claude.isRefreshing)
                // App-wide settings: login item, privacy, alerts, updates, quit.
                Button(action: openSettings) { Image(systemName: "gearshape").frame(width: 20, height: 20).contentShape(Rectangle()) }
                    .buttonStyle(.borderless).help("Settings")
                    .accessibilityLabel("Settings")
            }
            CodexCurrentBlock(model: codex, settings: settings)
            Divider()
            ClaudeCurrentBlock(store: claude, settings: settings, profiles: profiles)
        }
        .padding(14)
        .frame(width: 400, alignment: .topLeading)
    }
}

private struct ClaudeProfileInfoRow: View {
    let title: String
    let value: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(value ?? "Unavailable").font(.system(size: 12)).textSelection(.enabled)
                .foregroundStyle(value == nil ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Safe details for one Claude profile. API keys are never read, only whether one is saved.
private struct ClaudeProfileInfo: View {
    let profile: ClaudeProfile
    let account: ClaudeAccount?
    let isConfigured: Bool
    let hasAdminKey: Bool
    let isCurrent: Bool
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: back) { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(.borderless).font(.system(size: 12))
                .accessibilityLabel("Back to Claude profiles")
            ClaudeProfileInfoRow(title: "Name", value: profile.name)
            ClaudeProfileInfoRow(title: "Type", value: profile.kind == .api ? "API" : "Claude Code account")
            ClaudeProfileInfoRow(title: "Status", value: isCurrent ? "Current" : "Not current")
            if profile.kind == .api {
                ClaudeProfileInfoRow(title: "Endpoint", value: profile.baseURL?.nilIfEmpty)
                ClaudeProfileInfoRow(title: "Model", value: profile.model?.nilIfEmpty ?? "Claude Code default")
                ClaudeProfileInfoRow(title: "API key", value: isConfigured ? "Configured" : "Needs setup")
                ClaudeProfileInfoRow(title: "Admin key", value: hasAdminKey ? "Configured" : "Not set")
                ClaudeProfileInfoRow(title: "Monthly limit", value: profile.monthlyLimit.map(ClaudeMoney.format) ?? "Not set")
            } else {
                ClaudeProfileInfoRow(title: "Email", value: account?.email)
                ClaudeProfileInfoRow(title: "Plan", value: account?.plan.map { "Claude \($0.capitalized)" })
                ClaudeProfileInfoRow(title: "Organization", value: account?.organization)
            }
        }
    }
}

enum ClaudeMoney {
    static func format(_ dollars: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        // Whole dollars from $100 keep "$812 of $1,000" inside the row.
        formatter.maximumFractionDigits = dollars >= 100 || dollars.rounded() == dollars ? 0 : 2
        return formatter.string(from: NSNumber(value: dollars)) ?? "$\(dollars)"
    }
}

private func quotaTint(_ level: QuotaLevel) -> Color {
    switch level {
    case .normal: return .green
    case .low: return .orange
    case .critical: return .red
    }
}

/// One compact "5h ▬ 76%" line, the Claude counterpart of a Codex row's usage column.
private struct ClaudeRowMeter: View {
    let label: String
    let fraction: Double
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
            ProgressView(value: min(max(fraction, 0), 1)).tint(tint).frame(width: 52)
            Text(text).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(tint == .red ? .red : .primary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

/// Subscription quota for an account row, or this month's organization spend for an API row.
private struct ClaudeRowUsage: View {
    let quota: ClaudeUsageState?
    let spend: ClaudeSpendState?
    let limit: Double?

    var body: some View {
        let now = Date()
        Group {
            if let quota {
                switch quota {
                case .loading: ProgressView().controlSize(.mini)
                case let .unavailable(reason):
                    Text(reason == .notSignedIn ? "" : "No quota").font(.system(size: 10)).foregroundStyle(.secondary)
                        .help(reason.title)
                case let .available(snapshot):
                    VStack(alignment: .trailing, spacing: 3) {
                        ForEach(snapshot.windows.filter { ["five_hour", "seven_day"].contains($0.id) }, id: \.id) { window in
                            let reset = window.hasReset(at: now)
                            ClaudeRowMeter(label: window.id == "five_hour" ? "5h" : "7d", fraction: reset ? 1 : Double(window.remainingPercent) / 100,
                                           text: reset ? "–" : "\(window.remainingPercent)%", tint: reset ? .secondary : quotaTint(window.level))
                        }
                    }
                    .help("Claude subscription quota left. Checked \(UsageFormat.clock(snapshot.checkedAt, relativeTo: now)).")
                }
            } else if let spend {
                switch spend {
                case .loading: ProgressView().controlSize(.mini)
                case let .unavailable(message):
                    Text("No spend").font(.system(size: 10)).foregroundStyle(.secondary).help(message)
                case let .available(dollars, checkedAt):
                    VStack(alignment: .trailing, spacing: 3) {
                        if let limit {
                            let used = dollars / limit
                            ClaudeRowMeter(label: "Mo", fraction: used, text: "\(Int((used * 100).rounded()))%",
                                           tint: used >= 0.9 ? .red : used >= 0.75 ? .orange : .green)
                        }
                        Text(limit.map { "\(ClaudeMoney.format(dollars)) of \(ClaudeMoney.format($0))" } ?? "\(ClaudeMoney.format(dollars)) this month")
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                    }
                    .help("Organization spend this month (UTC), from the Admin API. Checked \(UsageFormat.clock(checkedAt, relativeTo: now)).")
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ClaudeProfileRow: View {
    let profile: ClaudeProfile
    @ObservedObject var store: ClaudeProfileStore
    let quota: ClaudeUsageState?
    let spend: ClaudeSpendState?
    let accountEmail: String?
    let showInfo: () -> Void
    let edit: () -> Void
    let report: (String?) -> Void
    @State private var confirmingDelete = false

    private var status: String {
        if profile.kind == .api { return store.isConfigured(profile) ? "Configured" : "Needs setup" }
        return accountEmail ?? "Not signed in"
    }

    var body: some View {
        let isCurrent = store.currentID == profile.id
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button(action: showInfo) {
                    Image(systemName: profile.kind == .api ? "key" : "person.crop.circle").frame(width: 16)
                }
                .buttonStyle(.plain)
                .help("Show info for \(profile.name)")
                .accessibilityLabel("Info for \(profile.name)")
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name).font(.system(size: 12, weight: .medium))
                    Text(profile.kind == .api ? "\(profile.baseURL ?? "") · \(profile.model ?? "default model") · \(status)" : status)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                ClaudeRowUsage(quota: quota, spend: spend, limit: profile.monthlyLimit)
                if isCurrent {
                    Text("Current").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
                } else {
                    Button("Switch") { report(store.switchTo(profile.id)) }.controlSize(.small)
                }
                Menu {
                    Button("Open in Terminal") { report(store.open(profile)) }
                    if profile.kind == .account && !profile.isDefaultAccount {
                        Button("Sign in…") { report(store.signIn(profile)) }
                    }
                    if !profile.isDefaultAccount {
                        Button("Edit…", action: edit)
                        Button("Delete…", role: .destructive) { confirmingDelete = true }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Actions for \(profile.name)")
            }
            if confirmingDelete {
                HStack {
                    Text(profile.kind == .api ? "Delete this profile and its saved API key?" : "Delete this profile and its sign-in folder?")
                        .font(.system(size: 11))
                    Spacer()
                    Button("Cancel") { confirmingDelete = false }.controlSize(.small)
                    Button("Delete", role: .destructive) { confirmingDelete = false; report(store.remove(profile.id)) }.controlSize(.small)
                }
            }
        }
    }
}

private struct ClaudeProfileForm: View {
    @ObservedObject var store: ClaudeProfileStore
    let editing: ClaudeProfile?
    let done: () -> Void
    @State private var name = ""
    @State private var kind = ClaudeProfileKind.account
    @State private var baseURL = "https://api.anthropic.com"
    @State private var model = ""
    @State private var apiKey = ""
    @State private var adminKey = ""
    @State private var removeAdminKey = false
    @State private var monthlyLimit = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(editing == nil ? "New Claude profile" : "Edit Claude profile").font(.system(size: 12, weight: .semibold))
            TextField("Name", text: $name)
            if editing == nil {
                Picker("Type", selection: $kind) {
                    Text("Claude Code account").tag(ClaudeProfileKind.account)
                    Text("API").tag(ClaudeProfileKind.api)
                }
                .pickerStyle(.segmented)
            }
            if kind == .api {
                TextField("Endpoint (base URL)", text: $baseURL)
                TextField("Model (optional)", text: $model)
                SecureField(editing == nil ? "API key" : "API key (leave empty to keep the saved key)", text: $apiKey)
                Text("The key is stored in Keychain only.").font(.system(size: 11)).foregroundStyle(.secondary)
                let savedAdmin = editing.map(store.hasAdminKey) ?? false
                SecureField(savedAdmin ? "Admin API key (leave empty to keep the saved key)" : "Admin API key (optional, for monthly spend)", text: $adminKey)
                    .disabled(removeAdminKey)
                if savedAdmin { Toggle("Remove the saved Admin API key", isOn: $removeAdminKey).toggleStyle(.checkbox) }
                TextField("Monthly spend limit in USD (optional)", text: $monthlyLimit)
                Text("An Admin API key (sk-ant-admin…) lets the row show your organization’s spend this month. Only organization admins can create one in the Console. Enter the limit shown under Spend limits; the API doesn’t report it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("Save, then choose Sign in… to log in to this account in its own Claude Code folder.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: done)
                Button(editing == nil ? "Add" : "Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12))
        .onAppear {
            guard let editing else { return }
            name = editing.name
            kind = editing.kind
            baseURL = editing.baseURL ?? ""
            model = editing.model ?? ""
            monthlyLimit = editing.monthlyLimit.map { String(format: $0.rounded() == $0 ? "%.0f" : "%.2f", $0) } ?? ""
        }
    }

    private func save() {
        error = store.validate(name: name, kind: kind, baseURL: baseURL, apiKey: apiKey, editing: editing)
            ?? store.validateSpend(adminKey: adminKey, monthlyLimit: monthlyLimit, kind: kind)
        guard error == nil else { return }
        var profile = ClaudeProfile(id: editing?.id ?? store.newProfileID(), name: name, kind: kind,
                                    baseURL: kind == .api ? baseURL : nil, model: kind == .api ? model : nil)
        profile.monthlyLimit = ClaudeProfileStore.parseLimit(monthlyLimit)
        error = store.upsert(profile, apiKey: apiKey, adminKey: removeAdminKey ? "" : adminKey, removeAdminKey: removeAdminKey)
        if error == nil { apiKey = ""; adminKey = ""; done() }
    }
}

private struct ClaudeProfilesSection: View {
    @ObservedObject var store: ClaudeProfileStore
    @ObservedObject var settings: AIProfileSettings
    @ObservedObject var usage: ClaudeUsageStore
    @ObservedObject var rowUsage: ClaudeProfileUsageStore
    let accounts: (ClaudeProfile) -> ClaudeAccount?
    @State private var infoID: String?
    @State private var editorOpen = false
    @State private var editing: ClaudeProfile?
    @State private var error: String?

    /// Plan comes only from the usage reading, which belongs to the current account profile.
    private func info(for profile: ClaudeProfile) -> ClaudeAccount? {
        guard profile.kind == .account, let account = accounts(profile) else { return nil }
        guard profile.id == store.currentID, store.current.kind == .account, case let .available(snapshot) = usage.state else { return account }
        return ClaudeAccount(email: account.email, organization: account.organization, plan: snapshot.account.plan)
    }

    /// The current account shows the In use reading; other accounts their own.
    private func quota(for profile: ClaudeProfile) -> ClaudeUsageState? {
        guard profile.kind == .account else { return nil }
        return profile.id == store.currentID ? usage.state : rowUsage.quota[profile.id]
    }

    var body: some View {
        let expanded = settings.claudeProfilesExpanded
        VStack(alignment: .leading, spacing: 0) {
            // Same geometry as the Codex header: 44 points tall, 14 leading and 10 trailing.
            HStack(spacing: 8) {
                Button { settings.claudeProfilesExpanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).frame(width: 12)
                        Image(systemName: StatusItemIcon.claudeSymbolName).font(.system(size: 16, weight: .medium)).frame(width: 18)
                        Text("Claude Profiles").font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Claude profiles")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Shows or hides the Claude profiles")
                if expanded && infoID == nil {
                    Button { editing = nil; editorOpen = true } label: { Label("Add", systemImage: "plus").frame(minHeight: 28) }
                        .buttonStyle(.borderless).font(.system(size: 12))
                }
            }
            .frame(height: 44)
            .padding(.leading, 14)
            .padding(.trailing, 10)
            if expanded { Divider() }
            // Collapsed content stays in the hierarchy at zero height so an open form keeps its fields.
            VStack(alignment: .leading, spacing: 8) {
                if editorOpen {
                    ClaudeProfileForm(store: store, editing: editing) {
                        editorOpen = false
                        Task { await rowUsage.refresh(store, force: true) }
                    }
                        .id(editing?.id ?? "new")
                } else if let profile = store.profiles.first(where: { $0.id == infoID }) {
                    ClaudeProfileInfo(profile: profile, account: info(for: profile), isConfigured: store.isConfigured(profile),
                                      hasAdminKey: store.hasAdminKey(profile), isCurrent: store.currentID == profile.id) { infoID = nil }
                } else {
                    ForEach(store.profiles) { profile in
                        ClaudeProfileRow(profile: profile, store: store, quota: quota(for: profile), spend: rowUsage.spend[profile.id],
                                         accountEmail: accounts(profile)?.email,
                                         showInfo: { infoID = profile.id },
                                         edit: { editing = profile; editorOpen = true }) { error = $0 }
                    }
                }
                if let error {
                    HStack(alignment: .top) {
                        Text(error).font(.system(size: 11)).foregroundStyle(.red)
                        Spacer()
                        Button("Dismiss") { self.error = nil }.buttonStyle(.borderless).font(.system(size: 11))
                    }
                }
                Text("Switching changes new Claude Code sessions only. Running sessions and Claude Desktop are unchanged. Account profiles other than Default apply through Open in Terminal.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, expanded ? 12 : 0)
            .padding(.bottom, expanded ? 14 : 0)
            .frame(maxHeight: expanded ? .infinity : 0, alignment: .top)
            .clipped()
            .allowsHitTesting(expanded)
            .accessibilityHidden(!expanded)
        }
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
    private let profiles: ClaudeProfileStore
    private let rowUsage: ClaudeProfileUsageStore
    private var subscriptions: Set<AnyCancellable> = []
    private let current = CodexCurrentModel()
    private let maxHeight: CGFloat = 560
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var scrollHeight: NSLayoutConstraint?
    private var scrollWidth: NSLayoutConstraint?
    var onPreferredContentSizeChange: ((NSSize) -> Void)?

    init(codex: WorkspaceMenuViewController, store: WorkspaceStore, settings: AIProfileSettings, claude: ClaudeUsageStore,
         profiles: ClaudeProfileStore, rowUsage: ClaudeProfileUsageStore? = nil) {
        self.profiles = profiles
        self.rowUsage = rowUsage ?? ClaudeProfileUsageStore()
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
        let section = NSHostingView(rootView: CurrentSection(codex: current, claude: claude, settings: settings, profiles: profiles,
                                                             openSettings: { [weak self] in self?.showAppSettings() }) { [weak self] in
            guard let self else { return }
            Task { await self.claude.refresh(force: true) }
            Task { await self.rowUsage.refresh(self.profiles, force: true) }
        })
        let claudeSection = NSHostingView(rootView: ClaudeProfilesSection(store: profiles, settings: settings, usage: claude, rowUsage: rowUsage) { [weak self] profile in
            guard let self, profile.kind == .account else { return nil }
            return self.claudeAccount(in: self.profiles.accountDirectory(for: profile))
        })
        codex.embedsInCommonScroll = true
        codex.isCollapsed = !settings.codexProfilesExpanded
        codex.onCollapseChange = { [weak self] collapsed in self?.settings.codexProfilesExpanded = !collapsed }
        addChild(codex)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        for subview in [section, divider(), codex.view, divider(), claudeSection] { stack.addArrangedSubview(subview) }
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 480)
        scrollWidth = scroll.widthAnchor.constraint(equalToConstant: 400)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollWidth!,
            scrollHeight!,
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalToConstant: 400),
        ])
        // The clip view narrows when a legacy scroller appears after layout.
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: scroll.contentView)
            .sink { [weak self] _ in Task { @MainActor in self?.fitHeight() } }.store(in: &subscriptions)
        codex.onPreferredContentSizeChange = { [weak self] _ in self?.relayout() }
        let previousChange = codexStore.onChange
        codexStore.onChange = { [weak self] in previousChange?(); self?.refreshCurrent() }
        let previousUsage = codexStore.onStatusUsageChange
        codexStore.onStatusUsageChange = { [weak self] in previousUsage?(); self?.refreshCurrent() }
        settings.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.codex.isCollapsed = !self.settings.codexProfilesExpanded
                self.relayout()
            }
        }.store(in: &subscriptions)
        profiles.objectWillChange.sink { [weak self] in Task { @MainActor in self?.relayout() } }.store(in: &subscriptions)
        refreshCurrent()
        relayout()
    }

    /// The signed-in account recorded in a profile's own Claude Code folder.
    private func claudeAccount(in directory: URL?) -> ClaudeAccount {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let data = try? Data(contentsOf: directory?.appendingPathComponent(".claude.json") ?? home.appendingPathComponent(".claude.json"))
        return ClaudeUsageClient().parseAccount(data, plan: nil)
    }

    /// Mirrors the store's active Codex profile and its default-home reading.
    func refreshCurrent() {
        current.profile = codexStore.activeProfile
        current.usage = codexStore.usage["default"]
        Task { @MainActor in self.relayout() }
    }

    /// SwiftUI sections grow after quota loads or an editor opens; following
    /// each layout pass keeps the viewport matched to the document.
    override func viewDidLayout() {
        super.viewDidLayout()
        fitHeight()
    }

    func relayout() {
        view.layoutSubtreeIfNeeded()
        fitHeight()
    }

    /// Sections are 400 points wide; widen the scroll view by whatever a legacy
    /// scroller takes from the clip view instead of cropping them.
    private func fitHeight() {
        let clip = scroll.contentView.bounds.width
        let width = (scrollWidth?.constant ?? 400) + (clip > 0 ? max(0, 400 - clip) : 0)
        let size = NSSize(width: width, height: min(maxHeight, stack.fittingSize.height))
        guard size != preferredContentSize else { return }
        scrollWidth?.constant = size.width
        scrollHeight?.constant = size.height
        preferredContentSize = size
        onPreferredContentSizeChange?(size)
    }

    func focusMenu() { codex.focusMenu() }

    /// Pops the app-wide settings menu under the pointer, where its gear was clicked.
    func showAppSettings() {
        codex.appSettingsMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Reads quota and spend for the Claude profile rows; throttled unless forced.
    func refreshClaudeRows(force: Bool = false) {
        Task { await rowUsage.refresh(profiles, force: force) }
    }

    func handleShortcut(_ event: NSEvent) -> Bool { codex.handleShortcut(event) }
}
