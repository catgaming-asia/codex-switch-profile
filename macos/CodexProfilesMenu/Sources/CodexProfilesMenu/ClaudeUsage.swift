import Foundation

/// One Claude subscription quota window (5-hour session, weekly, …) as
/// reported by Anthropic. Percentages are subscription quota, never token cost.
struct ClaudeQuotaWindow: Equatable, Sendable {
    let id: String
    let title: String
    let shortLabel: String
    let usedPercent: Double
    let resetsAt: Date?

    var remainingPercent: Int {
        Int((100 - min(100, max(0, usedPercent))).rounded(.down))
    }

    var level: QuotaLevel { QuotaLevel(remainingPercent: remainingPercent) }

    func hasReset(at date: Date) -> Bool {
        resetsAt.map { $0 <= date } ?? false
    }

    func resetDescription(at date: Date) -> String {
        guard let resetsAt else { return "Reset time unavailable" }
        let clock = UsageFormat.clock(resetsAt, relativeTo: date)
        guard !hasReset(at: date) else { return "Reset at \(clock)" }
        return "Resets in \(UsageFormat.countdown(to: resetsAt, from: date, style: .short)) (\(clock))"
    }
}

struct ClaudeAccount: Equatable, Sendable {
    let email: String?
    let organization: String?
    let plan: String?
}

struct ClaudeSnapshot: Equatable, Sendable {
    let account: ClaudeAccount
    let windows: [ClaudeQuotaWindow]
    let checkedAt: Date

    /// Lowest remaining level among the live five-hour and weekly windows.
    func menuBarLevel(at now: Date) -> QuotaLevel {
        windows.filter { ["five_hour", "seven_day"].contains($0.id) && !$0.hasReset(at: now) }.map(\.level).max() ?? .normal
    }

    /// Compact menu-bar text such as "5h 76% · W 69%", from real windows only.
    func menuBarText(at now: Date) -> String? {
        let parts = [("five_hour", "5h"), ("seven_day", "W")].compactMap { id, label -> String? in
            guard let window = windows.first(where: { $0.id == id && !$0.hasReset(at: now) }) else { return nil }
            return "\(label) \(window.remainingPercent)%"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum ClaudeUnavailableReason: Equatable, Sendable {
    case notSignedIn
    case signInExpired
    case network
    case rateLimited
    case unexpectedResponse

    var title: String {
        switch self {
        case .notSignedIn: return "Not signed in to Claude Code"
        case .signInExpired: return "Claude Code sign-in expired"
        case .network: return "Can’t reach Claude"
        case .rateLimited: return "Claude usage is rate limited"
        case .unexpectedResponse: return "Claude usage is unavailable"
        }
    }

    var detail: String {
        switch self {
        case .notSignedIn: return "Run claude and sign in with your Claude subscription, then refresh."
        case .signInExpired: return "Open Claude Code once to renew its sign-in, then refresh."
        case .network: return "Check your connection, then refresh."
        case .rateLimited: return "Try again in a few minutes."
        case .unexpectedResponse: return "Claude returned usage in a format this app doesn’t understand. No numbers are shown."
        }
    }
}

enum ClaudeUsageState: Equatable, Sendable {
    case loading
    case available(ClaudeSnapshot)
    case unavailable(ClaudeUnavailableReason)
}

struct ClaudeCredential: Sendable {
    let accessToken: String
    let expiresAt: Date?
    let plan: String?
}

/// Reads the signed-in Claude Code account and its subscription quota. The
/// token is read at run time, held in memory for one request, and never
/// logged or stored. Only Anthropic's own usage endpoint is contacted.
struct ClaudeUsageClient: Sendable {
    var session: URLSession = .shared
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    func parseCredential(_ data: Data) -> ClaudeCredential? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expires = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return ClaudeCredential(accessToken: token, expiresAt: expires, plan: oauth["subscriptionType"] as? String)
    }

    func parseAccount(_ data: Data?, plan: String?) -> ClaudeAccount {
        let root = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let oauth = root?["oauthAccount"] as? [String: Any]
        return ClaudeAccount(email: oauth?["emailAddress"] as? String,
                             organization: oauth?["organizationName"] as? String, plan: plan)
    }

    func parseWindows(_ data: Data) -> [ClaudeQuotaWindow] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let known = [("five_hour", "5-hour session", "5h"), ("seven_day", "Weekly", "W"),
                     ("seven_day_opus", "Weekly · Opus", "Opus"), ("seven_day_sonnet", "Weekly · Sonnet", "Sonnet")]
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return known.compactMap { id, title, label -> ClaudeQuotaWindow? in
            guard let window = root[id] as? [String: Any], let used = window["utilization"] as? Double else { return nil }
            let reset = (window["resets_at"] as? String).flatMap { withFraction.date(from: $0) ?? plain.date(from: $0) }
            return ClaudeQuotaWindow(id: id, title: title, shortLabel: label, usedPercent: used, resetsAt: reset)
        }
    }

    func fetch(now: Date = Date()) async -> ClaudeUsageState {
        let home = homeDirectory
        let loaded = await Task.detached(priority: .utility) { () -> (ClaudeCredential?, Data?) in
            let keychain = runCapturing("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
            let file = try? Data(contentsOf: home.appendingPathComponent(".claude/.credentials.json"))
            let credential = (keychain.flatMap { parseCredential($0) }) ?? (file.flatMap { parseCredential($0) })
            return (credential, try? Data(contentsOf: home.appendingPathComponent(".claude.json")))
        }.value
        guard let credential = loaded.0 else { return .unavailable(.notSignedIn) }
        if let expiresAt = credential.expiresAt, expiresAt <= now { return .unavailable(.signInExpired) }
        var request = URLRequest(url: usageURL, timeoutInterval: 10)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .unavailable(.network) }
        switch status {
        case 200: break
        case 401, 403: return .unavailable(.signInExpired)
        case 429: return .unavailable(.rateLimited)
        default: return .unavailable(.unexpectedResponse)
        }
        let windows = parseWindows(data)
        guard !windows.isEmpty else { return .unavailable(.unexpectedResponse) }
        return .available(ClaudeSnapshot(account: parseAccount(loaded.1, plan: credential.plan), windows: windows, checkedAt: now))
    }
}

private func runCapturing(_ path: String, _ arguments: [String]) -> Data? {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? data : nil
}

/// Persistent menu-bar preferences. Each AI has its own checkbox, so the menu
/// bar can show Codex, Claude, both, or neither. Auto Codex is a separate
/// Codex setting and is not stored here.
@MainActor
final class AIProfileSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var showsCodexInMenuBar: Bool {
        didSet { defaults.set(showsCodexInMenuBar, forKey: "menuBarShowsCodex"); onMenuBarChange?() }
    }
    @Published var showsClaudeInMenuBar: Bool {
        didSet { defaults.set(showsClaudeInMenuBar, forKey: "menuBarShowsClaude"); onMenuBarChange?() }
    }
    var onMenuBarChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Earlier builds stored one provider; keep that choice until a checkbox is saved.
        let legacy = defaults.string(forKey: "menuBarProvider")
        showsCodexInMenuBar = defaults.object(forKey: "menuBarShowsCodex") as? Bool ?? (legacy != "claude")
        showsClaudeInMenuBar = defaults.object(forKey: "menuBarShowsClaude") as? Bool ?? (legacy == "claude")
    }
}

@MainActor
final class ClaudeUsageStore: ObservableObject {
    @Published private(set) var state: ClaudeUsageState = .loading
    @Published private(set) var isRefreshing = false
    var onChange: (() -> Void)?
    private let client: ClaudeUsageClient
    private var lastAttempt: Date?

    init(client: ClaudeUsageClient = ClaudeUsageClient()) { self.client = client }

    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < 60 { return }
        isRefreshing = true
        lastAttempt = Date()
        let result = await client.fetch()
        isRefreshing = false
        state = result
        onChange?()
    }
}
