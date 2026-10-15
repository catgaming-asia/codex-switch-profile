import CoreServices
import Darwin
import Foundation

/// A quota observation written by a Codex CLI or Desktop session. Session
/// content other than this one rate-limit field is never retained or reported.
struct SessionQuotaSignal {
    let remainingPercent: Int?
    let exhausted: Bool

    init?(line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any],
              limits["limit_id"] as? String == "codex" else { return nil }
        exhausted = (limits["rate_limit_reached_type"] as? String) != nil
            || limits["spend_control_reached"] as? Bool == true
        let windows = [limits["primary"], limits["secondary"]].compactMap { $0 as? [String: Any] }
        remainingPercent = windows.compactMap { window -> Int? in
            guard let used = window["used_percent"] as? Double, used.isFinite else { return nil }
            return Int((100 - min(100, max(0, used))).rounded(.down))
        }.min()
        guard exhausted || remainingPercent != nil else { return nil }
    }

    func meetsThreshold(_ threshold: Int) -> Bool {
        exhausted || (remainingPercent.map { $0 <= threshold } ?? false)
    }
}

/// FSEvents watches local session writes without querying quota. It watches
/// default and named profile homes, then reads only newly appended JSONL lines.
@MainActor
final class SessionQuotaMonitor {
    var onSignal: ((String, SessionQuotaSignal) -> Void)?

    private var stream: FSEventStreamRef?
    private var roots: [String: String] = [:]
    private var observedSizes: [String: UInt64] = [:]
    private let fileManager = FileManager.default

    func update(profiles: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        var next: [String: String] = [:]
        for profile in Set(profiles).union(["default"]) {
            let profilePath = home.appendingPathComponent(profile == "default" ? ".codex" : ".codex-\(profile)").path
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: profilePath, isDirectory: &isDirectory), isDirectory.boolValue {
                next[canonicalPath(profilePath)] = profile
            }
        }
        guard next != roots else { return }
        stop()
        roots = next
        for root in next.keys { scan(root: root, reportChanges: false) }
        guard !next.isEmpty else { return }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let paths = NSArray(array: next.keys.sorted()) as CFArray
        stream = FSEventStreamCreate(kCFAllocatorDefault, { _, context, count, eventPaths, _, _ in
            guard let context else { return }
            let monitor = Unmanaged<SessionQuotaMonitor>.fromOpaque(context).takeUnretainedValue()
            let pointers = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let changed = (0..<count).map { String(cString: pointers[$0]) }
            Task { @MainActor in monitor.handle(paths: changed) }
        }, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            if !FSEventStreamStart(stream) { stop() }
        }
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        roots = [:]
        observedSizes = [:]
    }

    private func canonicalPath(_ path: String) -> String {
        guard let resolved = path.withCString({ realpath($0, nil) }) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func handle(paths: [String]) {
        for path in paths where path.contains("/sessions/") || path.hasSuffix("/sessions") {
            guard let root = roots.keys.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
            scan(root: root, reportChanges: true)
        }
    }

    private func scan(root: String, reportChanges: Bool) {
        let sessions = URL(fileURLWithPath: root).appendingPathComponent("sessions")
        guard let rootValues = try? sessions.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { return }
        guard let enumerator = fileManager.enumerator(at: sessions, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return }
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size >= 0 else { continue }
            let path = file.path
            let previous = observedSizes[path]
            if !reportChanges {
                observedSizes[path] = UInt64(size)
                continue
            }
            if UInt64(size) == previous { continue }
            let from = previous.map { UInt64(size) < $0 ? 0 : $0 } ?? 0
            readAppendedLines(at: file, from: from, size: UInt64(size), profile: roots[root] ?? "default")
        }
    }

    private func readAppendedLines(at file: URL, from: UInt64, size: UInt64, profile: String) {
        let start = max(from, size > 262_144 ? size - 262_144 : 0)
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: start)
            let bytes = try handle.read(upToCount: Int(size - start)) ?? Data()
            guard let lastNewline = bytes.lastIndex(of: 10) else { return }
            let complete = bytes.prefix(through: lastNewline)
            observedSizes[file.path] = start + UInt64(complete.count)
            let lines = complete.split(separator: 10)
            for line in lines {
                if let signal = SessionQuotaSignal(line: Data(line)) { onSignal?(profile, signal) }
            }
        } catch { return }
    }
}
