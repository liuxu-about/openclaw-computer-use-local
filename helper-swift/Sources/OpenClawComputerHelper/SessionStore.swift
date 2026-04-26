import Foundation

@MainActor
final class SessionStore {
    private struct SessionRecord: Codable {
        var sessionId: String
        var createdAt: String
        var updatedAt: String
        var targetApp: String?
        var targetWindow: String?
        var observations: [SessionObservationRef]
        var actions: [SessionActionRef]
    }

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let isoFormatter = ISO8601DateFormatter()

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-computer-use-local", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    func makeSessionId(bundleId: String?) -> String {
        let base = (bundleId ?? "session")
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let prefix = base.isEmpty ? "session" : base
        return "\(prefix)|session|\(UUID().uuidString)"
    }

    func appendObservation(observation: Observation, targetApp: String?, targetWindow: String?) -> SessionContext {
        var record = loadRecord(sessionId: observation.sessionId)
            ?? newRecord(sessionId: observation.sessionId, targetApp: targetApp, targetWindow: targetWindow)
        let now = isoFormatter.string(from: Date())
        record.updatedAt = now
        record.targetApp = record.targetApp ?? targetApp
        record.targetWindow = record.targetWindow ?? targetWindow
        record.observations.append(
            SessionObservationRef(
                observationId: observation.observationId,
                sceneDigest: observation.sceneDigest,
                activeApp: observation.activeApp,
                activeWindow: observation.activeWindow,
                source: observation.source,
                fallbackRecommended: observation.fallbackRecommended,
                createdAt: now
            )
        )
        record.observations = Array(record.observations.suffix(20))
        save(record)
        return context(from: record)
    }

    func appendAction(
        sessionId: String,
        observationId: String,
        actions: [ComputerAction],
        results: [ActionResult],
        targetApp: String?,
        targetWindow: String?
    ) -> SessionContext {
        var record = loadRecord(sessionId: sessionId)
            ?? newRecord(sessionId: sessionId, targetApp: targetApp, targetWindow: targetWindow)
        let now = isoFormatter.string(from: Date())
        record.updatedAt = now
        record.targetApp = record.targetApp ?? targetApp
        record.targetWindow = record.targetWindow ?? targetWindow
        record.actions.append(
            SessionActionRef(
                actionBatchId: UUID().uuidString,
                observationId: observationId,
                actionTypes: actions.map(\.type),
                statuses: results.map(\.status),
                ok: results.allSatisfy { $0.status == "ok" },
                createdAt: now
            )
        )
        record.actions = Array(record.actions.suffix(20))
        save(record)
        return context(from: record)
    }

    func loadContext(sessionId: String?) -> SessionContext? {
        guard let sessionId else {
            return nil
        }
        return loadRecord(sessionId: sessionId).map(context)
    }

    private func newRecord(sessionId: String, targetApp: String?, targetWindow: String?) -> SessionRecord {
        let now = isoFormatter.string(from: Date())
        return SessionRecord(
            sessionId: sessionId,
            createdAt: now,
            updatedAt: now,
            targetApp: targetApp,
            targetWindow: targetWindow,
            observations: [],
            actions: []
        )
    }

    private func loadRecord(sessionId: String) -> SessionRecord? {
        let url = fileURL(for: sessionId)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? decoder.decode(SessionRecord.self, from: data)
    }

    private func save(_ record: SessionRecord) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            let data = try encoder.encode(record)
            try data.write(to: fileURL(for: record.sessionId), options: .atomic)
        } catch {
            // Session history is useful but should not block computer-use actions.
        }
    }

    private func context(from record: SessionRecord) -> SessionContext {
        SessionContext(
            sessionId: record.sessionId,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            targetApp: record.targetApp,
            targetWindow: record.targetWindow,
            observationCount: record.observations.count,
            actionCount: record.actions.count,
            lastObservationId: record.observations.last?.observationId,
            lastSceneDigest: record.observations.last?.sceneDigest,
            recentObservations: Array(record.observations.suffix(6)),
            recentActions: Array(record.actions.suffix(6))
        )
    }

    private func fileURL(for sessionId: String) -> URL {
        let safe = sessionId.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression)
        return directory.appendingPathComponent(safe).appendingPathExtension("json")
    }
}
