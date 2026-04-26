import Foundation

@MainActor
final class ObservationStore {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let isoFormatter = ISO8601DateFormatter()
    private let fingerprintBuilder = ElementFingerprintBuilder()

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-computer-use-local", isDirectory: true)
            .appendingPathComponent("observations", isDirectory: true)
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    func save(observation: Observation, bundleId: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            let stored = StoredObservation(
                observationId: observation.observationId,
                sessionId: observation.sessionId,
                bundleId: bundleId,
                activeApp: observation.activeApp,
                activeWindow: observation.activeWindow,
                elements: observation.elements,
                elementFingerprints: fingerprintBuilder.fingerprints(
                    tree: observation.tree,
                    elements: observation.elements
                ),
                uiSummary: observation.uiSummary,
                recommendedTargets: observation.recommendedTargets,
                screenshot: observation.screenshot,
                overlay: observation.overlay,
                sceneDigest: observation.sceneDigest,
                createdAt: isoFormatter.string(from: Date())
            )
            let data = try encoder.encode(stored)
            try data.write(to: fileURL(for: observation.observationId), options: .atomic)
        } catch {
            // Best effort only for the skeleton.
        }
    }

    func load(observationId: String) -> StoredObservation? {
        let url = fileURL(for: observationId)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? decoder.decode(StoredObservation.self, from: data)
    }

    private func fileURL(for observationId: String) -> URL {
        let safe = observationId.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression)
        return directory.appendingPathComponent(safe).appendingPathExtension("json")
    }
}
