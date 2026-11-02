import AppKit
import CryptoKit
import Foundation

/// Semantic version "x.y.z"; a leading "v" and "+build" are ignored, and a
/// "-pre" suffix only orders versions whose numbers are equal.
struct AppVersion: CustomStringConvertible, Equatable {
    let numbers: [Int]
    let prerelease: String?

    init?(_ text: String) {
        var core = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if core.hasPrefix("v") || core.hasPrefix("V") { core.removeFirst() }
        if let plus = core.firstIndex(of: "+") { core = String(core[..<plus]) }
        var pre: String?
        if let dash = core.firstIndex(of: "-") {
            pre = String(core[core.index(after: dash)...])
            core = String(core[..<dash])
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var list: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            list.append(number)
        }
        while list.count < 3 { list.append(0) }
        numbers = list
        prerelease = pre?.isEmpty == true ? nil : pre
    }

    var description: String {
        numbers.map(String.init).joined(separator: ".") + (prerelease.map { "-\($0)" } ?? "")
    }

    func isOlder(than other: AppVersion) -> Bool {
        if numbers != other.numbers { return numbers.lexicographicallyPrecedes(other.numbers) }
        switch (prerelease, other.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (mine?, theirs?): return mine.compare(theirs, options: .numeric) == .orderedAscending
        }
    }
}

/// An unreadable version is never offered.
func isNewerVersion(_ latest: String, than current: String) -> Bool {
    guard let latest = AppVersion(latest), let current = AppVersion(current) else { return false }
    return current.isOlder(than: latest)
}

/// `latest.json` in the update folder, beside the zip it names:
/// {"version","build","date","notes","file","size","sha256"}.
struct UpdateManifest: Equatable {
    let version: String
    let notes: String
    let file: String
    let size: Int64
    let sha256: String
    let fileURL: URL
}

enum AppUpdate {
    /// The public release folder (Cloudflare R2 behind data.catgaming.asia).
    static let baseURL = URL(string: "https://data.catgaming.asia/AiProfile/release/")!
    static let bundleID = "asia.catgaming.aiprofile"

    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// A fresh query each time so the CDN never answers from cache.
    static func manifestURL(_ base: URL, time: Int) -> URL {
        var parts = URLComponents(url: base.appendingPathComponent("latest.json"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "t", value: String(time))]
        return parts.url!
    }

    /// One path component ending in .zip, so the manifest can't point outside its folder.
    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
            && !name.contains("?") && !name.contains("#") && name.lowercased().hasSuffix(".zip")
    }

    static func parseManifest(_ data: Data, base: URL) -> Result<UpdateManifest, AppUpdateError> {
        let bad: (String) -> Result<UpdateManifest, AppUpdateError> = { .failure(AppUpdateError("latest.json is not valid: \($0).")) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return bad("not a JSON object") }
        guard let text = object["version"] as? String, let version = AppVersion(text) else { return bad("missing or wrong \"version\"") }
        guard let file = object["file"] as? String, isSafeFileName(file) else { return bad("\"file\" must be a .zip name in the same folder") }
        guard let size = (object["size"] as? NSNumber)?.int64Value, size > 0 else { return bad("missing or wrong \"size\"") }
        let hash = ((object["sha256"] as? String) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return bad("\"sha256\" must be 64 hex characters") }
        let fileURL = base.appendingPathComponent(file)
        guard fileURL.scheme == "https", fileURL.host == base.host else { return bad("\"file\" must be a .zip name in the same folder") }
        return .success(UpdateManifest(version: version.description,
                                       notes: ((object["notes"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                       file: file, size: size, sha256: hash, fileURL: fileURL))
    }

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // nil marks the end of the file; a read error throws.
            guard case let .success(chunk) = Result(catching: { try handle.read(upToCount: 1 << 20) }) else { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Waits for the app to quit, swaps the bundle (restoring the old one on
    /// failure) and reopens it. Arguments: pid, new app, target app, work folder.
    static let installScript = """
    #!/bin/sh
    pid="$1"; new="$2"; target="$3"; work="$4"
    old="$target.old"
    i=0
    while kill -0 "$pid" 2>/dev/null; do
      i=$((i + 1))
      [ "$i" -gt 600 ] && exit 1
      sleep 0.1
    done
    rm -rf "$old"
    if mv "$target" "$old"; then
      if mv "$new" "$target"; then
        rm -rf "$old"
      else
        rm -rf "$target"
        mv "$old" "$target"
      fi
    fi
    open "$target"
    rm -rf "$work"
    """
}

struct AppUpdateError: Error, Equatable {
    let text: String
    init(_ text: String) { self.text = text }
}

enum AppUpdatePhase: Equatable {
    case idle
    case checking
    case upToDate
    case failed(String)
    case available(UpdateManifest)
    case downloading(UpdateManifest, fraction: Double?)
    case installing(UpdateManifest)
}

/// Checks the public release folder for a newer AI Profile and installs it:
/// download, size and SHA-256 check, unzip, bundle identifier and version
/// check, then a script swaps the bundle after this app quits. No credentials
/// are sent, and only https is followed.
@MainActor
final class AppUpdater {
    private(set) var phase: AppUpdatePhase = .idle { didSet { onChange?(phase) } }
    var onChange: ((AppUpdatePhase) -> Void)?
    private let base: URL
    private let current: String
    private let session: URLSession
    private var work: Task<Void, Never>?

    init(base: URL = AppUpdate.baseURL, current: String = AppUpdate.currentVersion, session: URLSession? = nil) {
        self.base = base
        self.current = current
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration, delegate: HTTPSOnlyRedirects(), delegateQueue: nil)
        }
    }

    var availableUpdate: UpdateManifest? {
        if case let .available(manifest) = phase { return manifest }
        return nil
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    @discardableResult
    func check() async -> AppUpdatePhase {
        guard !isBusy else { return phase }
        phase = .checking
        let request = Self.request(AppUpdate.manifestURL(base, time: Int(Date().timeIntervalSince1970)))
        guard let (data, response) = try? await session.data(for: request) else {
            phase = .failed("Couldn’t reach \(base.host ?? "the update server"). Check your connection, then try again.")
            return phase
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            phase = .failed(status == 404 ? "No release is published at \(base.absoluteString) yet." : "The update server answered HTTP \(status).")
            return phase
        }
        switch AppUpdate.parseManifest(data, base: base) {
        case let .failure(error): phase = .failed(error.text)
        case let .success(manifest): phase = isNewerVersion(manifest.version, than: current) ? .available(manifest) : .upToDate
        }
        return phase
    }

    /// Downloads and verifies `manifest`, then quits so the script can swap the bundle.
    func install(_ manifest: UpdateManifest, target: URL = Bundle.main.bundleURL, quit: (() -> Void)? = nil) {
        let parent = target.deletingLastPathComponent()
        guard target.pathExtension == "app", FileManager.default.isWritableFile(atPath: parent.path) else {
            phase = .failed("AI Profile can’t replace itself in “\(parent.path)”. Move it to a folder you can write to, such as Applications, then try again.")
            return
        }
        phase = .downloading(manifest, fraction: nil)
        work = Task { [weak self] in
            guard let self else { return }
            switch await self.prepare(manifest, target: target) {
            case let .failure(error): self.phase = .failed(error.text)
            case let .success(script):
                self.phase = .installing(manifest)
                guard (try? script.run()) != nil else {
                    self.phase = .failed("Couldn’t start the update installer.")
                    return
                }
                (quit ?? Self.quitForInstall)()
            }
        }
    }

    /// The script waits for this process to exit; force it if an open alert keeps AppKit from terminating.
    private static func quitForInstall() {
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    }

    private func prepare(_ manifest: UpdateManifest, target: URL) async -> Result<Process, AppUpdateError> {
        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory.appendingPathComponent("AIProfileUpdate-\(UUID().uuidString)", isDirectory: true)
        guard (try? fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)) != nil else {
            return .failure(AppUpdateError("Couldn’t create a temporary folder for the update."))
        }
        let fail: (String) -> Result<Process, AppUpdateError> = { text in
            try? fileManager.removeItem(at: workDirectory)
            return .failure(AppUpdateError(text))
        }
        let zip = workDirectory.appendingPathComponent(manifest.file)
        guard let (downloaded, response) = try? await session.download(for: Self.request(manifest.fileURL)) else {
            return fail("Couldn’t download \(manifest.file). Check your connection, then try again.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), (try? fileManager.moveItem(at: downloaded, to: zip)) != nil else {
            try? fileManager.removeItem(at: downloaded)
            return fail("Downloading \(manifest.file) failed (HTTP \(status)).")
        }
        let size = ((try? fileManager.attributesOfItem(atPath: zip.path))?[.size] as? NSNumber)?.int64Value ?? -1
        guard size == manifest.size else { return fail("The download is \(size) bytes but latest.json says \(manifest.size). Nothing was installed.") }
        let hash = await Task.detached { AppUpdate.sha256(of: zip) }.value
        guard hash == manifest.sha256 else { return fail("The download’s SHA-256 doesn’t match latest.json. Nothing was installed.") }

        let unpacked = workDirectory.appendingPathComponent("app", isDirectory: true)
        guard await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) == 0 else { return fail("Couldn’t unpack \(manifest.file).") }
        try? fileManager.removeItem(at: zip)
        let apps = ((try? fileManager.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
        guard apps.count == 1, let newApp = apps.first else { return fail("\(manifest.file) must contain exactly one app.") }
        let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == AppUpdate.bundleID else { return fail("The downloaded app isn’t AI Profile. Nothing was installed.") }
        guard info?["CFBundleShortVersionString"] as? String == manifest.version else {
            return fail("The downloaded app isn’t version \(manifest.version). Nothing was installed.")
        }

        let script = workDirectory.appendingPathComponent("install.sh")
        guard (try? Data(AppUpdate.installScript.utf8).write(to: script)) != nil else { return fail("Couldn’t write the update installer.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, target.path, workDirectory.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return .success(process)
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("AIProfile/\(AppUpdate.currentVersion)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func run(_ path: String, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            if (try? process.run()) == nil {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
            }
        }
    }
}

private final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }
}

/// Settings saved under the app's former bundle identifier. They are copied
/// once into the current domain before anything reads them; keys already set
/// under the new identifier win, and the old domain is left untouched.
enum LegacyDefaults {
    static let domain = "dev.ducksss.codex-profiles.menu"
    static let migratedKey = "migratedLegacyDefaults"

    static func migrate(into defaults: UserDefaults, from legacy: [String: Any]?) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        for (key, value) in legacy ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: migratedKey)
    }
}
