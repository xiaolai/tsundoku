import Foundation

/// Append-only JSONL evidence for the companion gates.
///
/// Disabled unless the app is launched with `--diagnostics <path>`. It records
/// window and focus state, never page text, questions, answers or secrets.
public final class TsundokuDiagnostics: @unchecked Sendable {
    public static let shared = TsundokuDiagnostics()

    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()
    private var handle: FileHandle?
    private var stateURL: URL?
    private var enabled = false
    private var droppedEvents = 0
    private var lastWriteError: String?

    private init() {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    /// Diagnostics that silently lose records are worse than diagnostics that
    /// say so; the counters are exposed to the state snapshot.
    public var droppedEventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedEvents
    }

    public var lastError: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastWriteError
    }

    public func start(path: String) {
        lock.lock()
        defer { lock.unlock() }
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            return
        }
        self.handle = handle
        self.stateURL = URL(
            fileURLWithPath: path.hasSuffix(".jsonl")
                ? String(path.dropLast(6)) + ".state.json"
                : path + ".state.json")
        self.enabled = true
        try? handle.seekToEnd()
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        enabled = false
    }

    public func event(_ name: String, _ fields: [String: Any] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, let handle else { return }
        var payload: [String: Any] = [
            "ts": formatter.string(from: Date()),
            "event": name,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "process": ProcessInfo.processInfo.processName,
        ]
        for (key, value) in fields {
            payload[key] = value
        }
        guard
            JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys]),
            var line = String(data: data, encoding: .utf8)
        else {
            droppedEvents += 1
            lastWriteError = "event \(name) could not be encoded"
            return
        }
        line += "\n"
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.synchronize()
        } catch {
            droppedEvents += 1
            lastWriteError = "event \(name): \(error)"
        }
    }

    /// Overwrites one state document so a gate can read the latest snapshot
    /// without replaying the log.
    public func writeState(_ state: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, let stateURL else { return }
        var payload = state
        payload["updated_at"] = formatter.string(from: Date())
        guard
            JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys])
        else {
            lastWriteError = "state snapshot could not be encoded"
            return
        }
        do {
            try data.write(to: stateURL, options: .atomic)
        } catch {
            lastWriteError = "state snapshot: \(error)"
        }
    }
}
