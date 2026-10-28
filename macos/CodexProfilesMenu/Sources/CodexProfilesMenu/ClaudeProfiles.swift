import Foundation
import Security

let claudeAPIKeyService = "dev.ducksss.codex-profiles.claude-api"
let defaultClaudeProfileID = "default"

enum ClaudeProfileKind: String, Codable, Equatable, Sendable {
    case account
    case api
}

/// A named way of running Claude Code. Account profiles own a private
/// `CLAUDE_CONFIG_DIR` (the built-in default profile uses `~/.claude`); API
/// profiles hold an endpoint and model here and the API key only in Keychain.
struct ClaudeProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var kind: ClaudeProfileKind
    var baseURL: String?
    var model: String?

    var isDefaultAccount: Bool { id == defaultClaudeProfileID }

    static var defaultAccount: ClaudeProfile {
        ClaudeProfile(id: defaultClaudeProfileID, name: "Default account", kind: .account, baseURL: nil, model: nil)
    }
}

protocol ClaudeSecretStore: Sendable {
    func save(_ secret: String, id: String) -> Bool
    func exists(id: String) -> Bool
    func delete(id: String)
}

/// Keychain-backed API keys. The item trusts this app and `/usr/bin/security`,
/// so the `apiKeyHelper` command Claude Code runs can read it without a prompt.
struct KeychainClaudeSecrets: ClaudeSecretStore {
    private func query(_ id: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: claudeAPIKeyService, kSecAttrAccount: id]
    }

    func save(_ secret: String, id: String) -> Bool {
        SecItemDelete(query(id) as CFDictionary)
        var attributes = query(id)
        attributes[kSecValueData] = Data(secret.utf8)
        var mine: SecTrustedApplication?
        var tool: SecTrustedApplication?
        SecTrustedApplicationCreateFromPath(nil, &mine)
        SecTrustedApplicationCreateFromPath("/usr/bin/security", &tool)
        var access: SecAccess?
        let trusted = [mine, tool].compactMap { $0 } as CFArray
        if SecAccessCreate("Claude API key" as CFString, trusted, &access) == errSecSuccess, let access {
            attributes[kSecAttrAccess] = access
        }
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    func exists(id: String) -> Bool {
        SecItemCopyMatching(query(id) as CFDictionary, nil) == errSecSuccess
    }

    func delete(id: String) {
        SecItemDelete(query(id) as CFDictionary)
    }
}

/// Which Claude Code settings keys an API profile owns, and what the user had
/// there before, so switching away restores the original values.
struct ClaudeManagedState: Codable, Equatable {
    var touched: [String] = []
    var originals: [String: String] = [:]
}

private let managedSettingKeys = ["env.ANTHROPIC_BASE_URL", "env.ANTHROPIC_MODEL", "apiKeyHelper"]

/// Edits only the keys an API profile owns in Claude Code's user settings file
/// and keeps everything else. A private backup is written before each change.
struct ClaudeSettingsApplier: Sendable {
    let settingsFile: URL
    let backupDirectory: URL
    let stateFile: URL

    func helperCommand(for profile: ClaudeProfile) -> String {
        "/usr/bin/security find-generic-password -s \(claudeAPIKeyService) -a \(profile.id) -w"
    }

    /// Desired values for one profile; nil restores the user's own settings.
    func desired(for profile: ClaudeProfile?) -> [String: String] {
        guard let profile, profile.kind == .api, let baseURL = profile.baseURL else { return [:] }
        var values = ["env.ANTHROPIC_BASE_URL": baseURL, "apiKeyHelper": helperCommand(for: profile)]
        if let model = profile.model, !model.isEmpty { values["env.ANTHROPIC_MODEL"] = model }
        return values
    }

    /// Returns an error message, or nil when the settings now match `profile`.
    func apply(_ profile: ClaudeProfile?) -> String? {
        let fileManager = FileManager.default
        var root: [String: Any] = [:]
        if fileManager.fileExists(atPath: settingsFile.path) {
            guard let data = try? Data(contentsOf: settingsFile),
                  let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return "Claude Code settings.json isn’t valid JSON, so nothing was changed. Fix or move the file, then switch again."
            }
            root = parsed
            guard backup(data) else { return "Couldn’t write a private backup of settings.json, so nothing was changed." }
        }
        var state = (try? Data(contentsOf: stateFile)).flatMap { try? JSONDecoder().decode(ClaudeManagedState.self, from: $0) } ?? ClaudeManagedState()
        var env = root["env"] as? [String: Any] ?? [:]
        let wanted = desired(for: profile)
        for key in managedSettingKeys {
            let name = key.replacingOccurrences(of: "env.", with: "")
            let isEnv = key.hasPrefix("env.")
            let existing = (isEnv ? env[name] : root[name]) as? String
            if let value = wanted[key] {
                if !state.touched.contains(key) {
                    state.touched.append(key)
                    if let existing { state.originals[key] = existing }
                }
                if isEnv { env[name] = value } else { root[name] = value }
            } else if state.touched.contains(key) {
                if let original = state.originals[key] {
                    if isEnv { env[name] = original } else { root[name] = original }
                } else if isEnv {
                    env[name] = nil
                } else {
                    root[name] = nil
                }
                state.touched.removeAll { $0 == key }
                state.originals[key] = nil
            }
        }
        if env.isEmpty { root["env"] = nil } else { root["env"] = env }
        let directory = settingsFile.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let output = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              (try? output.write(to: settingsFile, options: .atomic)) != nil,
              let stateData = try? JSONEncoder().encode(state),
              (try? stateData.write(to: stateFile, options: .atomic)) != nil else {
            return "Couldn’t write Claude Code settings.json. Check its permissions, then switch again."
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
        return nil
    }

    private func backup(_ data: Data) -> Bool {
        let fileManager = FileManager.default
        guard (try? fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])) != nil else { return false }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let target = backupDirectory.appendingPathComponent("settings-\(stamp)-\(UUID().uuidString.prefix(6)).json")
        guard (try? data.write(to: target, options: .atomic)) != nil else { return false }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return true
    }
}

private let terminalScript = """
on run argv
    tell application "Terminal"
        activate
        do script (item 1 of argv)
    end tell
end run
"""

/// Builds the shell command that runs Claude Code with a profile. Nothing here
/// contains a secret: API keys are read by `apiKeyHelper` from Keychain.
struct ClaudeLauncher: Sendable {
    let applier: ClaudeSettingsApplier
    let accountDirectory: @Sendable (ClaudeProfile) -> URL?

    func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func command(for profile: ClaudeProfile, signIn: Bool = false) -> String {
        switch profile.kind {
        case .account:
            let directory = accountDirectory(profile)
            let prefix = directory.map { "CLAUDE_CONFIG_DIR=\(shellQuote($0.path))" } ?? "env -u CLAUDE_CONFIG_DIR"
            return "\(prefix) claude" + (signIn ? " auth login" : "")
        case .api:
            let values = applier.desired(for: profile)
            var env: [String: String] = [:]
            if let value = values["env.ANTHROPIC_BASE_URL"] { env["ANTHROPIC_BASE_URL"] = value }
            if let value = values["env.ANTHROPIC_MODEL"] { env["ANTHROPIC_MODEL"] = value }
            let settings: [String: Any] = ["env": env, "apiKeyHelper": values["apiKeyHelper"] ?? ""]
            let json = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return "env -u CLAUDE_CONFIG_DIR claude --settings \(shellQuote(json))"
        }
    }

    /// Opens Terminal on `command`. Returns an error message on failure.
    func openTerminal(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", terminalScript, command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "Couldn’t start Terminal." }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? nil : "Terminal didn’t open. Allow AI Profile to control Terminal in System Settings, then try again."
    }
}

struct ClaudeProfilesFile: Codable, Equatable {
    var profiles: [ClaudeProfile] = []
    var currentID = defaultClaudeProfileID
}

/// Claude profile list, current selection and the real switch into Claude
/// Code's configuration. A switch changes only new Claude Code sessions; it
/// never touches a running session or Claude Desktop.
@MainActor
final class ClaudeProfileStore: ObservableObject {
    @Published private(set) var profiles: [ClaudeProfile] = [.defaultAccount]
    @Published private(set) var currentID = defaultClaudeProfileID
    @Published var notice: String?
    var onCurrentChange: (() -> Void)?

    private let directory: URL
    private let secrets: ClaudeSecretStore
    private let applier: ClaudeSettingsApplier
    private let launcher: ClaudeLauncher
    private let openTerminal: @Sendable (String) -> String?

    init(directory: URL, claudeDirectory: URL, secrets: ClaudeSecretStore = KeychainClaudeSecrets(),
         openTerminal: (@Sendable (String) -> String?)? = nil) {
        self.directory = directory
        self.secrets = secrets
        let applier = ClaudeSettingsApplier(settingsFile: claudeDirectory.appendingPathComponent("settings.json"),
                                            backupDirectory: directory.appendingPathComponent("backups"),
                                            stateFile: directory.appendingPathComponent("managed-settings.json"))
        self.applier = applier
        let accounts = directory.appendingPathComponent("accounts")
        let launcher = ClaudeLauncher(applier: applier) { profile in
            profile.isDefaultAccount ? nil : accounts.appendingPathComponent(profile.id)
        }
        self.launcher = launcher
        self.openTerminal = openTerminal ?? { launcher.openTerminal($0) }
        load()
    }

    var current: ClaudeProfile { profiles.first { $0.id == currentID } ?? .defaultAccount }

    /// `nil` means the default `~/.claude` account.
    func accountDirectory(for profile: ClaudeProfile) -> URL? {
        profile.isDefaultAccount ? nil : directory.appendingPathComponent("accounts").appendingPathComponent(profile.id)
    }

    func isConfigured(_ profile: ClaudeProfile) -> Bool {
        profile.kind == .api && !(profile.baseURL ?? "").isEmpty && secrets.exists(id: profile.id)
    }

    private var file: URL { directory.appendingPathComponent("claude-profiles.json") }

    private func load() {
        let stored = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(ClaudeProfilesFile.self, from: $0) }
        profiles = [.defaultAccount] + (stored?.profiles ?? []).filter { !$0.isDefaultAccount }
        currentID = profiles.contains { $0.id == stored?.currentID } ? stored?.currentID ?? defaultClaudeProfileID : defaultClaudeProfileID
    }

    private func save() -> Bool {
        let stored = ClaudeProfilesFile(profiles: profiles.filter { !$0.isDefaultAccount }, currentID: currentID)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(stored), (try? data.write(to: file, options: .atomic)) != nil else {
            notice = "Couldn’t save Claude profiles. Check the disk, then try again."
            return false
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return true
    }

    /// Returns an inline error for the form, or nil when the profile is valid.
    func validate(name: String, kind: ClaudeProfileKind, baseURL: String, apiKey: String, editing: ClaudeProfile?) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter a name for this profile." }
        if profiles.contains(where: { $0.id != editing?.id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "A Claude profile named “\(trimmed)” already exists. Choose another name."
        }
        guard kind == .api else { return nil }
        let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        if url?.scheme != "https" && url?.scheme != "http" || url?.host == nil {
            return "Enter the endpoint as a full URL, such as https://api.anthropic.com."
        }
        if apiKey.isEmpty && (editing == nil || !secrets.exists(id: editing?.id ?? "")) { return "Enter the API key for this endpoint." }
        return nil
    }

    /// Adds or updates a profile. A non-empty `apiKey` replaces the saved key.
    func upsert(_ profile: ClaudeProfile, apiKey: String) -> String? {
        var stored = profile
        stored.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        stored.baseURL = profile.kind == .api ? profile.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        stored.model = profile.kind == .api ? profile.model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty : nil
        if stored.kind == .api, !apiKey.isEmpty, !secrets.save(apiKey, id: stored.id) {
            return "Couldn’t save the API key to Keychain. Unlock your login keychain, then try again."
        }
        if let index = profiles.firstIndex(where: { $0.id == stored.id }) { profiles[index] = stored } else { profiles.append(stored) }
        guard save() else { return notice }
        // An edited current API profile must reach Claude Code too.
        return stored.id == currentID ? applySwitch(stored) : nil
    }

    func newProfileID() -> String { "p" + UUID().uuidString.lowercased().prefix(8) }

    func remove(_ id: String) -> String? {
        guard let profile = profiles.first(where: { $0.id == id }), !profile.isDefaultAccount else { return nil }
        if id == currentID, let error = switchTo(defaultClaudeProfileID) { return error }
        secrets.delete(id: id)
        if let directory = accountDirectory(for: profile) { try? FileManager.default.removeItem(at: directory) }
        profiles.removeAll { $0.id == id }
        return save() ? nil : notice
    }

    /// Makes `id` the current profile. API profiles are written into Claude
    /// Code's user settings (with a private backup); account profiles restore
    /// the user's own settings and are applied by Open in Terminal.
    func switchTo(_ id: String) -> String? {
        guard let profile = profiles.first(where: { $0.id == id }) else { return nil }
        if let error = applySwitch(profile) { return error }
        currentID = id
        onCurrentChange?()
        return save() ? nil : notice
    }

    private func applySwitch(_ profile: ClaudeProfile) -> String? {
        if profile.kind == .api && !isConfigured(profile) {
            return "This API profile has no saved key or endpoint. Edit it to finish setup."
        }
        return applier.apply(profile.kind == .api ? profile : nil)
    }

    /// Opens Terminal running Claude Code with this profile. A profile that
    /// isn't current is switched to first, so user settings left by an API
    /// profile can't leak into an account, and Current matches what opens.
    func open(_ profile: ClaudeProfile) -> String? {
        if let directory = accountDirectory(for: profile) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        if profile.id != currentID, let error = switchTo(profile.id) { return error }
        if profile.kind == .api && !isConfigured(profile) { return "This API profile has no saved key or endpoint. Edit it to finish setup." }
        return openTerminal(launcher.command(for: profile))
    }

    /// Starts `claude auth login` for an account profile in its own config folder.
    func signIn(_ profile: ClaudeProfile) -> String? {
        guard profile.kind == .account else { return nil }
        if let directory = accountDirectory(for: profile) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        return openTerminal(launcher.command(for: profile, signIn: true))
    }

    func command(for profile: ClaudeProfile, signIn: Bool = false) -> String { launcher.command(for: profile, signIn: signIn) }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
