import Darwin
import Foundation

/// Where one Claude Code account keeps its OAuth credential: a Keychain item,
/// or `.credentials.json` in its config directory when Keychain is not used.
struct ClaudeCredentialLocation: Sendable {
    let configDirectory: URL
    let service: String

    var file: URL { configDirectory.appendingPathComponent(".credentials.json") }

    /// The stored JSON and whether it came from Keychain.
    func read() -> (data: Data, inKeychain: Bool)? {
        // `security -w` ends the secret with a newline that is not part of it.
        if var data = runSecurity(["find-generic-password", "-s", service, "-w"]) {
            if data.last == UInt8(ascii: "\n") { data.removeLast() }
            return (data, true)
        }
        return (try? Data(contentsOf: file)).map { ($0, false) }
    }

    /// Replaces the stored JSON where it was read from, as Claude Code does:
    /// `security add-generic-password -U` with hex data, or an atomic 0600 file.
    func write(_ data: Data, inKeychain: Bool) -> Bool {
        guard inKeychain else {
            let temporary = configDirectory.appendingPathComponent(".credentials.json.ai-profile-\(UUID().uuidString)")
            let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { return false }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (try? handle.write(contentsOf: data)) != nil, (try? handle.synchronize()) != nil,
                  (try? handle.close()) != nil else { return false }
            return Darwin.rename(temporary.path, file.path) == 0
        }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let account = keychainAccount()
        // Short payloads go through stdin so the token never appears in process
        // arguments; `security -i` rejects lines over 4 KB, like Claude Code's limit.
        let command = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n"
        if command.utf8.count <= 4000 {
            return runSecurity(["-i"], input: Data(command.utf8)) != nil
        }
        return runSecurity(["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex]) != nil
    }

    /// The existing item's account, so `-U` updates it instead of adding a second item.
    private func keychainAccount() -> String {
        let attributes = runSecurity(["find-generic-password", "-s", service], includeErrors: true)
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if let line = attributes.split(separator: "\n").first(where: { $0.contains("\"acct\"<blob>=\"") }),
           let start = line.range(of: "<blob>=\"")?.upperBound, line.hasSuffix("\"") {
            return String(line[start..<line.index(before: line.endIndex)])
        }
        // Claude Code's own fallback when it creates the item.
        let name = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        return name.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) == nil ? "claude-code-user" : name
    }
}

/// Renews an expired Claude Code access token with its refresh token, the way
/// Claude Code does when it runs, so quota keeps loading while Claude Code is
/// idle. It takes Claude Code's own refresh and storage locks, re-reads the
/// credential under them, and only contacts Anthropic after a test write of the
/// unchanged credential succeeds, so a rotated refresh token is never lost.
/// Tokens are held in memory only and never logged.
struct ClaudeTokenRenewal: Sendable {
    var session: URLSession = .shared
    var tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Claude Code renews this long before expiry; matching it avoids a request with a token about to lapse.
    static let renewalMargin: TimeInterval = 300

    func renew(_ location: ClaudeCredentialLocation, now: @Sendable () -> Date = Date.init) async -> Data? {
        let directory = location.configDirectory
        let refreshLocks = [directory.appendingPathComponent(".oauth_refresh.lock"),
                            URL(fileURLWithPath: directory.resolvingSymlinksInPath().path + ".lock")]
        var held: [URL] = []
        defer { held.forEach(release) }
        for attempt in 0..<5 {
            held = refreshLocks.compactMap(acquire)
            if held.count == refreshLocks.count { break }
            held.forEach(release)
            held = []
            // Another process is renewing; its result may already be stored.
            if let stored = location.read(), !Self.needsRenewal(stored.data, at: now()) { return stored.data }
            guard attempt < 4 else { return nil }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        guard let stored = location.read(),
              var root = (try? JSONSerialization.jsonObject(with: stored.data)) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any],
              let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty else { return nil }
        guard Self.needsRenewal(stored.data, at: now()) else { return stored.data }
        guard await withStorageLock(directory, { location.write(stored.data, inKeychain: stored.inKeychain) }) else { return nil }

        let scopes = (oauth["scopes"] as? [String]) ?? []
        var request = URLRequest(url: tokenURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": refreshToken,
            "client_id": Self.clientID, "scope": scopes.joined(separator: " "),
        ])
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = body["access_token"] as? String, !accessToken.isEmpty,
              let expiresIn = (body["expires_in"] as? NSNumber)?.doubleValue else { return nil }

        let issued = now().timeIntervalSince1970
        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = (body["refresh_token"] as? String) ?? refreshToken
        oauth["expiresAt"] = Int64((issued + expiresIn) * 1000)
        if let refreshExpiresIn = (body["refresh_token_expires_in"] as? NSNumber)?.doubleValue {
            oauth["refreshTokenExpiresAt"] = Int64((issued + refreshExpiresIn) * 1000)
        }
        if let granted = body["scope"] as? String, !granted.isEmpty {
            oauth["scopes"] = granted.split(separator: " ").map(String.init)
        }
        root["claudeAiOauth"] = oauth
        guard let renewed = try? JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes]) else { return nil }
        _ = await withStorageLock(directory) { location.write(renewed, inKeychain: stored.inKeychain) }
        return renewed
    }

    static func needsRenewal(_ data: Data, at now: Date) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue else { return false }
        return Date(timeIntervalSince1970: expiresAt / 1000) <= now.addingTimeInterval(renewalMargin)
    }

    /// Runs one write under Claude Code's `.storage-write` lock.
    private func withStorageLock(_ directory: URL, _ body: () -> Bool) async -> Bool {
        let lock = directory.appendingPathComponent(".storage-write.lock")
        for _ in 0..<10 {
            if let held = acquire(lock) {
                defer { release(held) }
                return body()
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    /// proper-lockfile's protocol, which Claude Code uses: a lock is a directory created atomically.
    private func acquire(_ lock: URL) -> URL? {
        Darwin.mkdir(lock.path, 0o755) == 0 ? lock : nil
    }

    private func release(_ lock: URL) {
        _ = Darwin.rmdir(lock.path)
    }
}

private func runSecurity(_ arguments: [String], input: Data? = nil, includeErrors: Bool = false) -> Data? {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = includeErrors ? output : FileHandle.nullDevice
    let stdin = input.map { _ in Pipe() }
    process.standardInput = stdin ?? FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    if let stdin, let input {
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? data : nil
}
