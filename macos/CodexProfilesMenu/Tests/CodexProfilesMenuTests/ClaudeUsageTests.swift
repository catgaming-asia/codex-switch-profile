import Foundation

@main
@MainActor
struct ClaudeUsageTests {
    static func main() {
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
        print("Claude usage smoke tests passed.")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("Failed: \(message)") }
    }
}
