import Foundation

enum ObserveMode: String, Codable {
    case ax
    case axWithScreenshot = "ax_with_screenshot"
    case vision
}

struct ObserveRequest: Codable {
    let targetApp: String?
    let targetWindow: String?
    let mode: ObserveMode?
    let maxNodes: Double?
    let includeScreenshot: Bool?
}

struct ScreenInfo: Codable {
    let width: Double
    let height: Double
    let scale: Double
    let displayId: String
}

struct ScreenshotArtifact: Codable {
    let path: String
    let mimeType: String
    let width: Int
    let height: Int
    let captureKind: String
    let screenFrame: [Double]?
    let createdAt: String
}

struct AxNode: Codable {
    let id: String?
    let role: String
    let name: String?
    let value: String?
    let description: String?
    let enabled: Bool
    let focused: Bool
    let bbox: [Double]?
    let actions: [String]
    let path: String
    let children: [AxNode]
}

struct AxElementSummary: Codable {
    let id: String
    let role: String
    let name: String?
    let value: String?
    let description: String?
    let enabled: Bool
    let focused: Bool
    let bbox: [Double]?
    let actions: [String]
    let path: String
}

struct Observation: Codable {
    let observationId: String
    let source: String
    let activeApp: String
    let activeWindow: String
    let screen: ScreenInfo
    let tree: [AxNode]
    let elements: [String: AxElementSummary]
    let screenshot: ScreenshotArtifact?
    let screenshotError: String?
    let observeError: String?
    let fallbackRecommended: Bool
    let fallbackReason: String?
}

struct StoredObservation: Codable {
    let observationId: String
    let bundleId: String
    let activeApp: String
    let activeWindow: String
    let elements: [String: AxElementSummary]?
    let screenshot: ScreenshotArtifact?
    let createdAt: String
}

struct ComputerAction: Codable {
    let type: String
    let id: String?
    let text: String?
    let value: String?
    let keys: [String]?
    let strategy: String?
    let direction: String?
    let amount: Double?
    let ms: Double?
    let retryCount: Double?
    let x: Double?
    let y: Double?
    let x2: Double?
    let y2: Double?
    let reason: String?
}

struct ActionRequest: Codable {
    let observationId: String
    let actions: [ComputerAction]
}

struct ActionResult: Codable {
    let index: Int
    let type: String
    let route: String
    let status: String
    let message: String
    let id: String?
    let errorCode: String?
}

struct ActionResponse: Codable {
    let ok: Bool
    let results: [ActionResult]
    let nextObservation: Observation?
}

struct StopResponse: Codable {
    let ok: Bool
    let stopped: Bool
    let message: String
}

struct ComputerUseRequest: Codable {
    let task: String
    let targetApp: String
    let targetWindow: String?
    let approvalMode: String?
    let allowVisionFallback: Bool?
}

struct ComputerUseResponse: Codable {
    let ok: Bool
    let status: String
    let mode: String
    let task: String
    let targetApp: String
    let observation: Observation
    let notes: [String]
}

struct HealthResponse: Codable {
    let ok: Bool
    let helper: String
    let axTrusted: Bool
    let screenRecordingTrusted: Bool
    let frontmostApp: String
    let frontmostBundleId: String
    let eventLogPath: String?
}

struct VisionDecision {
    let source: String
    let fallbackRecommended: Bool
    let fallbackReason: String?
}

enum HelperCLIError: Error, CustomStringConvertible, LocalizedError {
    case usage(String)
    case invalidInput(String)

    var description: String {
        switch self {
        case .usage(let message):
            return message
        case .invalidInput(let message):
            return message
        }
    }

    var errorDescription: String? {
        description
    }
}
