import Foundation

/// Update checks against an in-process release folder; installs that fail
/// verification must never reach the swap script.
@main
@MainActor
struct AppUpdaterTests {
    static func main() async {
        expect(isNewerVersion("1.3.1", than: "1.3.0") && isNewerVersion("v2.0", than: "1.9.9") && isNewerVersion("1.4.0", than: "1.4.0-beta"),
               "newer versions are offered")
        expect(!isNewerVersion("1.3.0", than: "1.3.0") && !isNewerVersion("1.2.9", than: "1.3.0") && !isNewerVersion("junk", than: "1.0.0"),
               "same, older and unreadable versions are not offered")
        let base = AppUpdate.baseURL
        expect(base.absoluteString == "https://data.catgaming.asia/AiProfile/release/" && AppUpdate.bundleID == "asia.catgaming.aiprofile", "release folder and identity")
        expect(AppUpdate.manifestURL(base, time: 42).absoluteString == "https://data.catgaming.asia/AiProfile/release/latest.json?t=42", "manifest URL defeats caches")
        let hash = String(repeating: "a", count: 64)
        let good = manifest(version: "v1.4.0", file: "AIProfile-1.4.0.zip", size: 10, sha: hash)
        guard case let .success(parsed) = AppUpdate.parseManifest(good, base: base) else { return fail("a valid manifest parses") }
        expect(parsed.version == "1.4.0" && parsed.fileURL.absoluteString == "https://data.catgaming.asia/AiProfile/release/AIProfile-1.4.0.zip", "manifest fields")
        for (file, size, sha) in [("../evil.zip", 10, hash), ("x.dmg", 10, hash), ("ok.zip", 0, hash), ("ok.zip", 10, "abc")] {
            guard case .failure = AppUpdate.parseManifest(manifest(version: "1.4.0", file: file, size: size, sha: sha), base: base) else {
                return fail("manifest with \(file) \(size) \(sha) must be refused")
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseFolder.self]
        let session = URLSession(configuration: configuration)
        let updater = AppUpdater(current: "1.3.0", session: session)
        var phases: [AppUpdatePhase] = []
        updater.onChange = { phases.append($0) }

        ReleaseFolder.files = [:]
        expect(await updater.check() == .failed("No release is published at https://data.catgaming.asia/AiProfile/release/ yet."), "missing release folder")
        ReleaseFolder.files = ["latest.json": manifest(version: "1.3.0", file: "AIProfile-1.3.0.zip", size: 1, sha: hash)]
        expect(await updater.check() == .upToDate, "the same version is up to date")

        // A real zip of a fake app, served with a wrong hash and then with a foreign bundle identifier.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("updater-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = makeZip(in: root, bundleID: "example.other", version: "1.4.0")
        let data = try! Data(contentsOf: zip)
        let realHash = AppUpdate.sha256(of: zip)!
        ReleaseFolder.files = ["latest.json": manifest(version: "1.4.0", file: "AIProfile-1.4.0.zip", size: data.count, sha: hash),
                               "AIProfile-1.4.0.zip": data]
        guard case let .available(offered) = await updater.check() else { return fail("a newer version is offered") }
        expect(updater.availableUpdate == offered, "the offer is remembered")
        let target = root.appendingPathComponent("Applications/AI Profile.app")
        try! FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        var quit = false
        updater.install(offered, target: target) { quit = true }
        await waitWhileBusy(updater)
        expect(updater.phase == .failed("The download’s SHA-256 doesn’t match latest.json. Nothing was installed.") && !quit, "a wrong hash is refused")

        ReleaseFolder.files["latest.json"] = manifest(version: "1.4.0", file: "AIProfile-1.4.0.zip", size: data.count, sha: realHash)
        guard case let .available(signed) = await updater.check() else { return fail("the corrected release is offered") }
        updater.install(signed, target: target) { quit = true }
        await waitWhileBusy(updater)
        expect(updater.phase == .failed("The downloaded app isn’t AI Profile. Nothing was installed.") && !quit, "a foreign app is refused")
        expect(FileManager.default.fileExists(atPath: target.path), "a refused update leaves the installed app alone")
        expect(phases.contains { if case .downloading = $0 { return true } else { return false } }, "progress is reported")

        updater.install(signed, target: URL(fileURLWithPath: "/System/AI Profile.app")) { quit = true }
        guard case let .failed(message) = updater.phase, message.contains("can’t replace itself") else { return fail("a read-only folder is refused") }

        let defaults = UserDefaults(suiteName: "legacy-\(UUID().uuidString)")!
        defaults.set("terminal", forKey: "openDestination")
        LegacyDefaults.migrate(into: defaults, from: ["openDestination": "chatGPT", "workspacePins": ["a"]])
        expect(defaults.string(forKey: "openDestination") == "terminal" && defaults.stringArray(forKey: "workspacePins") == ["a"],
               "old settings fill gaps without overwriting new ones")
        LegacyDefaults.migrate(into: defaults, from: ["hideProfileNames": true])
        expect(!defaults.bool(forKey: "hideProfileNames"), "settings migrate only once")
        print("App updater tests passed.")
    }

    private static func manifest(version: String, file: String, size: Int, sha: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["version": version, "file": file, "size": size, "sha256": sha, "notes": "Notes"])
    }

    private static func makeZip(in root: URL, bundleID: String, version: String) -> URL {
        let app = root.appendingPathComponent("stage/AI Profile.app/Contents")
        try! FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version]
        info.write(to: app.appendingPathComponent("Info.plist"), atomically: true)
        let zip = root.appendingPathComponent("AIProfile.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", root.appendingPathComponent("stage/AI Profile.app").path, zip.path]
        try! process.run()
        process.waitUntilExit()
        return zip
    }

    private static func waitWhileBusy(_ updater: AppUpdater) async {
        for _ in 0..<100 where updater.isBusy { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    private static func fail(_ message: String) { fatalError(message) }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("Failed: \(message)") }
    }
}

/// Serves `files` by name from the release folder; anything else is 404.
final class ReleaseFolder: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var files: [String: Data] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let name = request.url?.lastPathComponent ?? ""
        let body = Self.files[name]
        let response = HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}
