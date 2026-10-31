import Foundation

@main
@MainActor
struct ClaudeUsageTests {
    static func main() async {
        let client = ClaudeUsageClient()
        let usage = Data("""
        {"five_hour":{"utilization":24.0,"resets_at":"2030-01-01T10:00:00.500+00:00"},
         "seven_day":{"utilization":31.5,"resets_at":"2030-01-05T10:00:00+00:00"},
         "seven_day_opus":null}
        """.utf8)
        let windows = client.parseWindows(usage)
        expect(windows.map(\.id) == ["five_hour", "seven_day"], "known non-null windows only")
        expect(windows[0].remainingPercent == 76 && windows[1].remainingPercent == 68, "remaining percent")
        expect(windows.allSatisfy { $0.resetsAt != nil }, "reset dates parse")
        let snapshot = ClaudeSnapshot(account: ClaudeAccount(email: nil, organization: nil, plan: nil),
                                      windows: windows, checkedAt: Date())
        expect(snapshot.menuBarText(at: Date()) == "5h 76% · W 68%", "menu bar text")
        expect(client.parseWindows(Data("{}".utf8)).isEmpty && client.parseWindows(Data("x".utf8)).isEmpty, "no invented numbers")
        let credential = client.parseCredential(Data(#"{"claudeAiOauth":{"accessToken":"t","expiresAt":1000,"subscriptionType":"max"}}"#.utf8))
        expect(credential?.plan == "max" && credential?.expiresAt == Date(timeIntervalSince1970: 1), "credential shape")
        expect(client.parseCredential(Data("{}".utf8)) == nil, "missing credential")
        let account = client.parseAccount(Data(#"{"oauthAccount":{"emailAddress":"a@example.com"}}"#.utf8), plan: "pro")
        expect(account.email == "a@example.com" && account.plan == "pro", "account")
        let defaults = UserDefaults(suiteName: "claude-usage-test-\(UUID().uuidString)")!
        let settings = AIProfileSettings(defaults: defaults)
        expect(settings.showsCodexInMenuBar && !settings.showsClaudeInMenuBar, "defaults keep Codex only")
        settings.showsClaudeInMenuBar = true
        expect(AIProfileSettings(defaults: defaults).showsCodexInMenuBar && AIProfileSettings(defaults: defaults).showsClaudeInMenuBar, "both persisted")
        settings.showsCodexInMenuBar = false
        settings.showsClaudeInMenuBar = false
        let reloaded = AIProfileSettings(defaults: defaults)
        expect(!reloaded.showsCodexInMenuBar && !reloaded.showsClaudeInMenuBar, "none persisted")
        let legacy = UserDefaults(suiteName: "claude-usage-legacy-\(UUID().uuidString)")!
        legacy.set("claude", forKey: "menuBarProvider")
        let migrated = AIProfileSettings(defaults: legacy)
        expect(!migrated.showsCodexInMenuBar && migrated.showsClaudeInMenuBar, "legacy provider migrates")
        let now = Date()
        let low = ClaudeSnapshot(account: account, windows: [ClaudeQuotaWindow(id: "five_hour", title: "5h", shortLabel: "5h", usedPercent: 95, resetsAt: now.addingTimeInterval(600))], checkedAt: now)
        expect(low.menuBarLevel(at: now) == .critical, "claude level from claude windows")
        expect(ClaudeSnapshot(account: account, windows: [], checkedAt: now).menuBarLevel(at: now) == .normal, "no windows neutral")
        ClaudeProfileSmoke().run()
        // A reading started before select must not overwrite the newly selected account.
        let gate = ReadingGate()
        let oldDirectory = URL(fileURLWithPath: "/tmp/claude-race-old")
        let newDirectory = URL(fileURLWithPath: "/tmp/claude-race-new")
        let racing = ClaudeUsageStore(client: ClaudeUsageClient(configDirectory: oldDirectory)) { client in
            if client.configDirectory == oldDirectory { await gate.wait(); return .unavailable(.network) }
            return .unavailable(.rateLimited)
        }
        let stale = Task { await racing.refresh(force: true) }
        while !gate.isWaiting { try? await Task.sleep(nanoseconds: 1_000_000) }
        racing.select(configDirectory: newDirectory)
        await racing.refresh()
        expect(racing.state == .unavailable(.rateLimited) && !racing.isRefreshing, "new profile refreshes right after select")
        gate.open()
        await stale.value
        expect(racing.state == .unavailable(.rateLimited) && !racing.isRefreshing, "stale reading is dropped")
        await renewalSmoke(usage: usage)
        print("Claude usage smoke tests passed.")
    }

    /// An idle account's expired token is renewed and stored back, keeping the
    /// rest of the credential; a busy lock or a refused renewal changes nothing.
    private static func renewalSmoke(usage: Data) async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-renewal-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".credentials.json")
        let expired = Data(#"{"claudeAiOauth":{"accessToken":"old-access","refreshToken":"old-refresh","expiresAt":1000,"scopes":["user:inference","user:profile"],"subscriptionType":"max"},"mcpOAuth":{"server":"kept"}}"#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = ClaudeUsageClient(session: session, configDirectory: directory,
                                       renewal: ClaudeTokenRenewal(session: session))
        let now = Date()

        try! expired.write(to: file)
        StubProtocol.reset(tokenStatus: 200, tokenBody: #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":28800,"scope":"user:inference user:profile"}"#, usage: usage)
        guard case .available = await client.fetch(now: now) else { return fail("an expired token must be renewed and quota loaded") }
        let sent = (try? JSONSerialization.jsonObject(with: StubProtocol.tokenRequests.first ?? Data())) as? [String: String]
        expect(sent == ["grant_type": "refresh_token", "refresh_token": "old-refresh",
                        "client_id": ClaudeTokenRenewal.clientID, "scope": "user:inference user:profile"], "refresh request matches Claude Code: \(sent ?? [:])")
        expect(StubProtocol.usageTokens == ["Bearer new-access"], "usage must use the renewed token")
        let stored = (try! JSONSerialization.jsonObject(with: Data(contentsOf: file))) as! [String: Any]
        let oauth = stored["claudeAiOauth"] as! [String: Any]
        expect(oauth["accessToken"] as? String == "new-access" && oauth["refreshToken"] as? String == "new-refresh"
            && (oauth["expiresAt"] as? NSNumber)?.doubleValue == ((now.timeIntervalSince1970 + 28800) * 1000).rounded(.down)
            && oauth["subscriptionType"] as? String == "max"
            && (stored["mcpOAuth"] as? [String: String]) == ["server": "kept"], "renewal must store the new token and keep every other field")
        let mode = (try! FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber).intValue
        expect(mode == 0o600, "the stored credential stays private")
        let leftovers = try! FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != ".credentials.json" }
        expect(leftovers.isEmpty && !FileManager.default.fileExists(atPath: directory.path + ".lock"), "locks are released: \(leftovers)")

        // Claude Code holds its refresh lock: wait for it, never refresh alongside it.
        try! expired.write(to: file)
        StubProtocol.reset(tokenStatus: 200, tokenBody: "{}", usage: usage)
        let lock = directory.appendingPathComponent(".oauth_refresh.lock")
        try! FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        expect(await client.fetch(now: now) == .unavailable(.signInExpired) && StubProtocol.tokenRequests.isEmpty
            && (try! Data(contentsOf: file)) == expired && FileManager.default.fileExists(atPath: lock.path),
            "a busy refresh lock must leave the credential and the other holder's lock alone")
        try! FileManager.default.removeItem(at: lock)

        // A refused renewal reports the sign-in as expired and keeps the stored credential.
        StubProtocol.reset(tokenStatus: 400, tokenBody: #"{"error":"invalid_grant"}"#, usage: usage)
        expect(await client.fetch(now: now) == .unavailable(.signInExpired) && StubProtocol.tokenRequests.count == 1
            && (try! Data(contentsOf: file)) == expired, "a refused renewal must not change the credential")
    }

    private static func fail(_ message: String) {
        fatalError(message)
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("Failed: \(message)") }
    }
}

final class ReadingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { lock.lock(); defer { lock.unlock() }; return continuation != nil }
    func wait() async {
        await withCheckedContinuation { next in lock.lock(); continuation = next; lock.unlock() }
    }
    func open() { lock.lock(); let next = continuation; continuation = nil; lock.unlock(); next?.resume() }
}

/// Answers the token and usage endpoints in process and records what was sent.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var tokenStatus = 200
    nonisolated(unsafe) static var tokenBody = Data()
    nonisolated(unsafe) static var usage = Data()
    nonisolated(unsafe) static var tokenRequests: [Data] = []
    nonisolated(unsafe) static var usageTokens: [String] = []

    static func reset(tokenStatus: Int, tokenBody: String, usage: Data) {
        self.tokenStatus = tokenStatus
        self.tokenBody = Data(tokenBody.utf8)
        self.usage = usage
        tokenRequests = []
        usageTokens = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let isToken = request.url?.path == "/v1/oauth/token"
        if isToken {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    body.append(buffer, count: count)
                }
                stream.close()
            }
            Self.tokenRequests.append(body)
        } else {
            Self.usageTokens.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: isToken ? Self.tokenStatus : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: isToken ? Self.tokenBody : Self.usage)
        client?.urlProtocolDidFinishLoading(self)
    }
}
