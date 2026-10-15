import AppKit
import Darwin
import Foundation

enum DefaultProfileSwitchError: LocalizedError {
    case invalidProfile
    case unsafePath(String)
    case desktopAppMissing
    case desktopDidNotQuit
    case reopenFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidProfile: "Choose a named profile to switch to default."
        case let .unsafePath(path): "The authentication path is missing or unsafe: \(path)"
        case .desktopAppMissing: "ChatGPT or Codex Desktop could not be found."
        case .desktopDidNotQuit: "ChatGPT or Codex Desktop did not quit. The default account was not changed."
        case let .reopenFailed(message): message
        }
    }
}

/// Copies opaque credentials without parsing or printing them. The existing
/// default credential is retained under a private, unique backup name.
struct ProfileAuthTransfer {
    func validateSelectedAuth(_ source: URL) throws {
        guard source.lastPathComponent == "auth.json" else {
            throw DefaultProfileSwitchError.unsafePath(source.path)
        }
        let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DefaultProfileSwitchError.unsafePath(source.path) }
        defer { Darwin.close(descriptor) }
        var details = stat()
        guard fstat(descriptor, &details) == 0,
              details.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              details.st_nlink == 1, details.st_size > 0, details.st_size <= 4 * 1024 * 1024 else {
            throw DefaultProfileSwitchError.unsafePath(source.path)
        }
    }

    func installSelectedAuth(_ source: URL, into profile: String, home: URL) throws {
        guard CLIClient.isValidProfileName(profile), profile != "default" else {
            throw DefaultProfileSwitchError.invalidProfile
        }
        try validateSelectedAuth(source)
        let profileHome = home.appendingPathComponent(".codex-\(profile)", isDirectory: true)
        try requireDirectory(profileHome)
        let destination = profileHome.appendingPathComponent("auth.json")
        guard !pathExists(destination) else { throw DefaultProfileSwitchError.unsafePath(destination.path) }

        let inputDescriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
        guard inputDescriptor >= 0 else { throw DefaultProfileSwitchError.unsafePath(source.path) }
        let input = FileHandle(fileDescriptor: inputDescriptor, closeOnDealloc: true)
        var details = stat()
        guard fstat(inputDescriptor, &details) == 0,
              details.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              details.st_nlink == 1, details.st_size > 0, details.st_size <= 4 * 1024 * 1024 else {
            throw DefaultProfileSwitchError.unsafePath(source.path)
        }
        let contents = try input.readToEnd() ?? Data()
        guard !contents.isEmpty, contents.count <= 4 * 1024 * 1024 else {
            throw DefaultProfileSwitchError.unsafePath(source.path)
        }

        let temporary = profileHome.appendingPathComponent(".auth.json.install-\(UUID().uuidString)")
        let outputDescriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard outputDescriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let output = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try output.write(contentsOf: contents)
        try output.synchronize()
        try output.close()
        // link fails if another process created auth.json while we were copying.
        guard Darwin.link(temporary.path, destination.path) == 0 else {
            throw DefaultProfileSwitchError.unsafePath(destination.path)
        }
    }

    @discardableResult
    func replaceSelectedAuth(_ source: URL, in profile: String, home: URL) throws -> URL? {
        guard CLIClient.isValidProfileName(profile), profile != "default" else {
            throw DefaultProfileSwitchError.invalidProfile
        }
        let profileHome = home.appendingPathComponent(".codex-\(profile)", isDirectory: true)
        try requireDirectory(profileHome)
        let destination = profileHome.appendingPathComponent("auth.json")
        guard source.standardizedFileURL != destination.standardizedFileURL else {
            throw DefaultProfileSwitchError.unsafePath(source.path)
        }
        try validateSelectedAuth(source)
        if pathExists(destination) { try requireRegularFile(destination) }

        let inputDescriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
        guard inputDescriptor >= 0 else { throw DefaultProfileSwitchError.unsafePath(source.path) }
        let input = FileHandle(fileDescriptor: inputDescriptor, closeOnDealloc: true)
        var details = stat()
        guard fstat(inputDescriptor, &details) == 0,
              details.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              details.st_nlink == 1, details.st_size > 0, details.st_size <= 4 * 1024 * 1024 else {
            throw DefaultProfileSwitchError.unsafePath(source.path)
        }
        let contents = try input.readToEnd() ?? Data()
        guard !contents.isEmpty, contents.count <= 4 * 1024 * 1024 else {
            throw DefaultProfileSwitchError.unsafePath(source.path)
        }

        let suffix = UUID().uuidString
        let temporary = profileHome.appendingPathComponent(".auth.json.update-\(suffix)")
        let backup = profileHome.appendingPathComponent("auth.json.backup-\(suffix)")
        let outputDescriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard outputDescriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let output = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try output.write(contentsOf: contents)
        try output.synchronize()
        try output.close()

        let hadPrevious = pathExists(destination)
        if hadPrevious {
            try requireRegularFile(destination)
            guard Darwin.rename(destination.path, backup.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            guard Darwin.chmod(backup.path, 0o600) == 0 else {
                _ = Darwin.rename(backup.path, destination.path)
                throw CocoaError(.fileWriteUnknown)
            }
        }
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            if hadPrevious { _ = Darwin.rename(backup.path, destination.path) }
            throw CocoaError(.fileWriteUnknown)
        }
        return hadPrevious ? backup : nil
    }

    func validateSource(_ profile: String, home: URL) throws {
        guard CLIClient.isValidProfileName(profile), profile != "default" else {
            throw DefaultProfileSwitchError.invalidProfile
        }
        let sourceHome = home.appendingPathComponent(".codex-\(profile)", isDirectory: true)
        try requireDirectory(sourceHome)
        let source = sourceHome.appendingPathComponent("auth.json")
        let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DefaultProfileSwitchError.unsafePath(source.path) }
        defer { Darwin.close(descriptor) }
        var details = stat()
        guard fstat(descriptor, &details) == 0,
              details.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), details.st_nlink == 1 else {
            throw DefaultProfileSwitchError.unsafePath(source.path)
        }
    }

    @discardableResult
    func copyToDefault(from profile: String, home: URL) throws -> URL? {
        try validateSource(profile, home: home)
        let source = home.appendingPathComponent(".codex-\(profile)/auth.json")
        let defaultHome = home.appendingPathComponent(".codex", isDirectory: true)
        try requireDirectory(defaultHome)
        let destination = defaultHome.appendingPathComponent("auth.json")
        if pathExists(destination) { try requireRegularFile(destination) }

        let sourceDescriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
        guard sourceDescriptor >= 0 else { throw DefaultProfileSwitchError.unsafePath(source.path) }
        let sourceHandle = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true)
        var sourceDetails = stat()
        guard fstat(sourceDescriptor, &sourceDetails) == 0,
              sourceDetails.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), sourceDetails.st_nlink == 1 else {
            throw DefaultProfileSwitchError.unsafePath(source.path)
        }
        let contents = try sourceHandle.readToEnd() ?? Data()
        guard !contents.isEmpty else { throw DefaultProfileSwitchError.unsafePath(source.path) }

        let suffix = UUID().uuidString
        let temporary = defaultHome.appendingPathComponent(".auth.json.switch-\(suffix)")
        let backup = defaultHome.appendingPathComponent("auth.json.backup-\(suffix)")
        let outputDescriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard outputDescriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let output = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try output.write(contentsOf: contents)
        try output.synchronize()
        try output.close()

        let hadPrevious = pathExists(destination)
        if hadPrevious {
            try requireRegularFile(destination)
            guard Darwin.rename(destination.path, backup.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            guard Darwin.chmod(backup.path, 0o600) == 0 else {
                _ = Darwin.rename(backup.path, destination.path)
                throw CocoaError(.fileWriteUnknown)
            }
        }
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            if hadPrevious { _ = Darwin.rename(backup.path, destination.path) }
            throw CocoaError(.fileWriteUnknown)
        }
        return hadPrevious ? backup : nil
    }

    private func requireDirectory(_ url: URL) throws {
        var details = stat()
        guard lstat(url.path, &details) == 0,
              details.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DefaultProfileSwitchError.unsafePath(url.path)
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        var details = stat()
        guard lstat(url.path, &details) == 0,
              details.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), details.st_nlink == 1 else {
            throw DefaultProfileSwitchError.unsafePath(url.path)
        }
    }

    private func pathExists(_ url: URL) -> Bool {
        var details = stat()
        return lstat(url.path, &details) == 0
    }
}

/// Reads only the access token's local JWT expiry claim for the Info page.
/// The token and all other credential fields stay in memory and are never logged.
struct ProfileAccessTokenExpiry {
    func read(for profile: String, home: URL) -> Date? {
        guard CLIClient.isValidProfileName(profile) else { return nil }
        let directory = profile == "default" ? ".codex" : ".codex-\(profile)"
        let profileHome = home.appendingPathComponent(directory)
        var homeDetails = stat()
        guard lstat(profileHome.path, &homeDetails) == 0,
              homeDetails.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return nil }
        let path = profileHome.appendingPathComponent("auth.json").path
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var details = stat()
        guard fstat(descriptor, &details) == 0,
              details.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              details.st_nlink == 1, details.st_size > 0, details.st_size <= 4 * 1024 * 1024,
              let contents = try? file.read(upToCount: 4 * 1024 * 1024 + 1),
              !contents.isEmpty, contents.count <= 4 * 1024 * 1024,
              let auth = try? JSONSerialization.jsonObject(with: contents) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String else { return nil }

        let segments = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, !segments[1].isEmpty, segments[1].count <= 16_384 else { return nil }
        let payload = String(segments[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = payload + String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { return nil }
        struct Claims: Decodable { let exp: TimeInterval }
        guard let expiry = try? JSONDecoder().decode(Claims.self, from: data).exp,
              expiry.isFinite, expiry > 0, expiry < 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: expiry)
    }
}

@MainActor
struct DefaultProfileSwitcher {
    func switchToDefault(from profile: String, client: CLIClient) async throws -> (backup: URL?, restarted: Bool) {
        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
        let transfer = ProfileAuthTransfer()
        try transfer.validateSource(profile, home: home)
        let appURL = try desktopAppURL()
        try await client.createProfile("default")

        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == appURL.resolvingSymlinksInPath().standardizedFileURL
                && !$0.isTerminated
        }
        let shouldRestart = !running.isEmpty
        for application in running {
            guard application.terminate() else { throw DefaultProfileSwitchError.desktopDidNotQuit }
        }
        for _ in 0..<50 {
            if running.allSatisfy(\.isTerminated) { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard running.allSatisfy(\.isTerminated) else { throw DefaultProfileSwitchError.desktopDidNotQuit }

        let backup: URL?
        do {
            backup = try transfer.copyToDefault(from: profile, home: home)
        } catch {
            if shouldRestart { try? await client.launch(.profile("default"), in: .chatGPT) }
            throw error
        }
        if shouldRestart {
            do {
                try await client.launch(.profile("default"), in: .chatGPT)
            } catch {
                let recovery = backup.map { "The previous default authentication is saved at \($0.path)." }
                    ?? "There was no previous default authentication."
                throw DefaultProfileSwitchError.reopenFailed("Default authentication was changed, but Desktop could not reopen: \(error.localizedDescription) \(recovery)")
            }
        }
        return (backup, shouldRestart)
    }

    private func desktopAppURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let candidates: [String]
        if let value = environment["CHATGPT_APP"], !value.isEmpty { candidates = [value] }
        else if let value = environment["CODEX_APP"], !value.isEmpty { candidates = [value] }
        else if let value = environment["CODEX_APP_BIN"], !value.isEmpty {
            if let range = value.range(of: "/Contents/MacOS/") { candidates = [String(value[..<range.lowerBound])] }
            else { candidates = [] }
        } else { candidates = ["/Applications/ChatGPT.app", "/Applications/Codex.app"] }
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            if Bundle(url: url)?.executableURL != nil { return url }
        }
        throw DefaultProfileSwitchError.desktopAppMissing
    }
}
