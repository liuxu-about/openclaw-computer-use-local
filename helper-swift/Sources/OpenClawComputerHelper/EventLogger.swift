import Foundation

final class EventLogger: @unchecked Sendable {
    static let shared = EventLogger()

    let logPath: String
    private let fileURL: URL
    private let logFullPayloads: Bool

    private init() {
        let configured = ProcessInfo.processInfo.environment["COMPUTER_USE_EVENT_LOG_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured, !configured.isEmpty {
            self.fileURL = URL(fileURLWithPath: configured)
        } else {
            self.fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("openclaw-computer-use-local-events.jsonl", isDirectory: false)
        }
        self.logPath = fileURL.path
        self.logFullPayloads = ProcessInfo.processInfo.environment["COMPUTER_USE_LOG_FULL_PAYLOADS"] == "1"
    }

    func log(_ type: String, payload: [String: Any] = [:]) {
        var record: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "pid": ProcessInfo.processInfo.processIdentifier,
            "type": type,
        ]
        for (key, value) in payload {
            record[key] = sanitize(value, key: key)
        }

        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record),
              let line = String(data: data, encoding: .utf8)
        else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )

            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }

            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            handle.write(Data((line + "\n").utf8))
        } catch {
            // Best effort only.
        }
    }

    private func sanitize(_ value: Any, depth: Int = 0, key: String = "") -> Any {
        if let redacted = redactedPlaceholder(for: value, key: key) {
            return redacted
        }

        if depth > 4 {
            return "[max-depth]"
        }

        switch value {
        case let value as String:
            return value.count > 1200 ? String(value.prefix(1199)) + "…" : value
        case let value as NSNumber:
            return value
        case let value as Bool:
            return value
        case let value as Int:
            return value
        case let value as Double:
            return value
        case let value as [Any]:
            return Array(value.prefix(32)).map { sanitize($0, depth: depth + 1, key: key) }
        case let value as [String: Any]:
            var out: [String: Any] = [:]
            for (key, item) in value.prefix(64) {
                out[key] = sanitize(item, depth: depth + 1, key: key)
            }
            return out
        case let value as Error:
            return [
                "message": value.localizedDescription,
                "type": String(describing: type(of: value)),
            ]
        case Optional<Any>.none:
            return NSNull()
        default:
            return String(describing: value)
        }
    }

    private func redactedPlaceholder(for value: Any, key: String) -> String? {
        guard !logFullPayloads else {
            return nil
        }

        let normalized = key.lowercased()
        if ["matched_text", "query", "task", "text", "value"].contains(normalized) {
            return "[redacted]"
        }
        if normalized == "tree" || normalized == "elements" {
            if let array = value as? [Any] {
                return "[redacted:\(normalized):\(array.count)]"
            }
            if let object = value as? [String: Any] {
                return "[redacted:\(normalized):\(object.count)]"
            }
            return "[redacted:\(normalized)]"
        }
        if normalized == "path",
           let path = value as? String,
           path.contains("openclaw-computer-use-local")
        {
            return "[redacted:path]"
        }
        return nil
    }
}
