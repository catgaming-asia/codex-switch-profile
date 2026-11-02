import Foundation

enum ClaudeSpendState: Equatable, Sendable {
    case loading
    /// Organization cost so far this calendar month (UTC), in US dollars.
    case available(dollars: Double, checkedAt: Date)
    case unavailable(String)
}

/// Reads an organization's cost for the current month through the Admin API
/// (Usage and Cost Analytics). The admin key is read at run time, held in
/// memory for one request, and never logged. The API reports spend but not
/// the Console's monthly limit, which the user enters on the profile instead.
struct ClaudeSpendClient: Sendable {
    var session: URLSession = .shared
    var costURL = URL(string: "https://api.anthropic.com/v1/organizations/analytics/cost")!
    static let beta = "analytics-usage-cost-2026-08-24"

    /// Amounts are decimal strings in cents: "41280.000000" is $412.80.
    func parseDollars(_ data: Data) -> Double? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else { return nil }
        var cents = 0.0
        for row in rows {
            guard let cost = row["cost"] as? [String: Any], (cost["currency"] as? String ?? "USD") == "USD",
                  let amount = (cost["amount"] as? String).flatMap(Double.init) ?? (cost["amount"] as? NSNumber)?.doubleValue else { return nil }
            cents += amount
        }
        return cents / 100
    }

    static func monthStart(_ now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
    }

    func fetch(adminKey: String, now: Date = Date()) async -> ClaudeSpendState {
        let formatter = ISO8601DateFormatter()
        var components = URLComponents(url: costURL, resolvingAgainstBaseURL: false)!
        // No grouping or buckets: one row totals the month so far.
        components.queryItems = [URLQueryItem(name: "starting_at", value: formatter.string(from: Self.monthStart(now)))]
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue(adminKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(Self.beta, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .unavailable("Can’t reach Anthropic") }
        switch status {
        case 200: break
        case 401, 403: return .unavailable("Admin API key rejected")
        case 429: return .unavailable("Spend is rate limited")
        default: return .unavailable("Spend unavailable")
        }
        guard let dollars = parseDollars(data) else { return .unavailable("Spend unavailable") }
        return .available(dollars: dollars, checkedAt: now)
    }
}

/// Quota for each Claude account profile and spend for each API profile with
/// an admin key, for the rows of the Claude profiles list. The current account
/// keeps using the In use reading, so it is not fetched twice.
@MainActor
final class ClaudeProfileUsageStore: ObservableObject {
    @Published private(set) var quota: [String: ClaudeUsageState] = [:]
    @Published private(set) var spend: [String: ClaudeSpendState] = [:]
    private var lastAttempt: Date?
    private var isRefreshing = false
    private let fetchQuota: @Sendable (URL?) async -> ClaudeUsageState
    private let fetchSpend: @Sendable (String) async -> ClaudeSpendState

    init(fetchQuota: @escaping @Sendable (URL?) async -> ClaudeUsageState = { await ClaudeUsageClient(configDirectory: $0).fetch() },
         fetchSpend: @escaping @Sendable (String) async -> ClaudeSpendState = { await ClaudeSpendClient().fetch(adminKey: $0) }) {
        self.fetchQuota = fetchQuota
        self.fetchSpend = fetchSpend
    }

    func refresh(_ store: ClaudeProfileStore, force: Bool = false) async {
        guard !isRefreshing else { return }
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < 60 { return }
        isRefreshing = true
        lastAttempt = Date()
        defer { isRefreshing = false }
        let accounts = store.profiles.filter { $0.kind == .account && $0.id != store.currentID }
            .map { ($0.id, store.accountDirectory(for: $0)) }
        let admins = store.profiles.filter { $0.kind == .api }.compactMap { profile in store.adminKey(for: profile).map { (profile.id, $0) } }
        // Removed profiles, the current account and API profiles without a key drop their readings.
        let accountIDs = Set(accounts.map(\.0))
        let adminIDs = Set(admins.map(\.0))
        quota = quota.filter { accountIDs.contains($0.key) }
        spend = spend.filter { adminIDs.contains($0.key) }
        for (id, _) in accounts where quota[id] == nil { quota[id] = .loading }
        for (id, _) in admins where spend[id] == nil { spend[id] = .loading }
        let fetchQuota = self.fetchQuota
        let fetchSpend = self.fetchSpend
        await withTaskGroup(of: (String, ClaudeUsageState?, ClaudeSpendState?).self) { group in
            for (id, directory) in accounts { group.addTask { (id, await fetchQuota(directory), nil) } }
            for (id, key) in admins { group.addTask { (id, nil, await fetchSpend(key)) } }
            for await (id, reading, cost) in group {
                if let reading { quota[id] = reading }
                if let cost { spend[id] = cost }
            }
        }
    }
}
