import Foundation

final class MemorySecrets: ClaudeSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func save(_ secret: String, id: String) -> Bool { lock.lock(); defer { lock.unlock() }; values[id] = secret; return true }
    func exists(id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return values[id] != nil }
    func delete(id: String) { lock.lock(); defer { lock.unlock() }; values[id] = nil }
}

/// Isolated smoke checks: a temp directory stands in for the home folder and
/// an in-memory store for Keychain, so no real account or setting is touched.
@MainActor
struct ClaudeProfileSmoke {
    func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("Failed: \(message)") }
    }

    func readJSON(_ url: URL) -> [String: Any] {
        ((try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
    }

    func run() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-profile-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let claudeDir = root.appendingPathComponent(".claude")
        let support = root.appendingPathComponent("support")
        try? FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settings = claudeDir.appendingPathComponent("settings.json")
        let original = #"{"theme":"dark","env":{"KEEP_ME":"1","ANTHROPIC_MODEL":"user-model"},"permissions":{"allow":["Bash(ls)"]}}"#
        try? Data(original.utf8).write(to: settings)
        let secrets = MemorySecrets()
        let opened = OpenedCommands()
        let store = ClaudeProfileStore(directory: support, claudeDirectory: claudeDir, secrets: secrets) { opened.add($0); return nil }

        expect(store.validate(name: "", kind: .api, baseURL: "", apiKey: "", editing: nil) != nil, "empty name rejected")
        expect(store.validate(name: "A", kind: .api, baseURL: "ftp://x", apiKey: "k", editing: nil) != nil, "bad URL rejected")
        expect(store.validate(name: "A", kind: .api, baseURL: "https://api.example.com", apiKey: "", editing: nil) != nil, "key required")
        let api = ClaudeProfile(id: "api1", name: "Proxy", kind: .api, baseURL: "https://api.example.com", model: "claude-sonnet-5-5")
        expect(store.upsert(api, apiKey: "sk-secret-value") == nil, "api profile saved")
        let account = ClaudeProfile(id: "acct1", name: "Work", kind: .account, baseURL: nil, model: nil)
        expect(store.upsert(account, apiKey: "") == nil, "account profile saved")
        expect(store.isConfigured(api), "api configured")

        expect(store.switchTo("api1") == nil && store.currentID == "api1", "switch to api")
        let applied = readJSON(settings)
        let env = applied["env"] as? [String: Any] ?? [:]
        expect(applied["theme"] as? String == "dark" && (applied["permissions"] as? [String: Any]) != nil, "unrelated settings kept")
        expect(env["KEEP_ME"] as? String == "1" && env["ANTHROPIC_MODEL"] as? String == "claude-sonnet-5-5", "env merged")
        expect(env["ANTHROPIC_BASE_URL"] as? String == "https://api.example.com", "endpoint applied")
        expect((applied["apiKeyHelper"] as? String)?.contains("find-generic-password") == true, "helper reads keychain")
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: support.appendingPathComponent("backups").path)) ?? []
        expect(backups.count == 1, "one backup before change")
        let backupPath = support.appendingPathComponent("backups").appendingPathComponent(backups.first ?? "").path
        let mode = (try? FileManager.default.attributesOfItem(atPath: backupPath))?[.posixPermissions] as? Int
        expect(mode == 0o600, "backup is private")
        expect((try? Data(contentsOf: URL(fileURLWithPath: backupPath))).flatMap { String(data: $0, encoding: .utf8) } == original, "backup is the original")

        expect(store.switchTo("acct1") == nil && store.currentID == "acct1", "switch to account")
        let restored = readJSON(settings)
        let restoredEnv = restored["env"] as? [String: Any] ?? [:]
        expect(restoredEnv["ANTHROPIC_MODEL"] as? String == "user-model" && restoredEnv["KEEP_ME"] as? String == "1", "user env restored")
        expect(restoredEnv["ANTHROPIC_BASE_URL"] == nil && restored["apiKeyHelper"] == nil, "managed keys removed")
        expect(restored["theme"] as? String == "dark", "unrelated settings kept after restore")

        let everything = [settings, support.appendingPathComponent("claude-profiles.json"), support.appendingPathComponent("managed-settings.json")]
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
        expect(!everything.contains("sk-secret-value"), "no plaintext key in files")
        _ = store.switchTo("api1")
        expect(!(try? String(contentsOf: settings, encoding: .utf8))!.contains("sk-secret-value"), "no key in settings")

        expect(store.open(account) == nil && store.signIn(account) == nil && store.open(api) == nil, "launch actions")
        let commands = opened.all
        expect(commands[0].contains("CLAUDE_CONFIG_DIR=") && commands[0].contains("/accounts/acct1") && !commands[0].contains("auth login"), "account launch uses own config dir")
        expect(commands[1].hasSuffix("claude auth login") && commands[1].contains("/accounts/acct1"), "sign in uses own config dir")
        expect(commands[2].contains("--settings") && commands[2].contains("ANTHROPIC_BASE_URL") && !commands[2].contains("sk-secret-value"), "api launch has no key")
        expect(store.command(for: .defaultAccount).hasPrefix("env -u CLAUDE_CONFIG_DIR claude"), "default account launch")

        let reloaded = ClaudeProfileStore(directory: support, claudeDirectory: claudeDir, secrets: secrets) { _ in nil }
        expect(reloaded.profiles.map(\.id) == ["default", "api1", "acct1"] && reloaded.currentID == "api1", "profiles persist")
        expect(reloaded.remove("api1") == nil && reloaded.currentID == "default", "removing current restores default")
        expect(!secrets.exists(id: "api1"), "key removed with profile")
        expect((readJSON(settings)["env"] as? [String: Any])?["ANTHROPIC_BASE_URL"] == nil, "settings restored on delete")

        try? Data("{not json".utf8).write(to: settings)
        expect(store.switchTo("api1") != nil || store.profiles.first { $0.id == "api1" } == nil, "invalid settings left untouched")
        expect((try? String(contentsOf: settings, encoding: .utf8)) == "{not json", "invalid settings not overwritten")
    }
}

final class OpenedCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []
    func add(_ command: String) { lock.lock(); commands.append(command); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return commands }
}
