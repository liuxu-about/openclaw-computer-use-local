import Foundation

enum ObserveMode: String, Codable {
    case ax
    case axWithScreenshot = "ax_with_screenshot"
    case vision
}

struct ObserveRequest: Codable {
    let sessionId: String?
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
    let sessionId: String
    let sceneDigest: String
    let source: String
    let activeApp: String
    let activeWindow: String
    let screen: ScreenInfo
    let tree: [AxNode]
    let elements: [String: AxElementSummary]
    let uiSummary: UISummary
    let recommendedTargets: [RecommendedTarget]
    let screenshot: ScreenshotArtifact?
    let overlay: OverlayArtifact?
    let screenshotError: String?
    let observeError: String?
    let fallbackRecommended: Bool
    let fallbackReason: String?
    let session: SessionContext?
}

struct StoredObservation: Codable {
    let observationId: String
    let sessionId: String?
    let bundleId: String
    let activeApp: String
    let activeWindow: String
    let elements: [String: AxElementSummary]?
    let elementFingerprints: [String: ElementFingerprint]?
    let uiSummary: UISummary?
    let recommendedTargets: [RecommendedTarget]?
    let screenshot: ScreenshotArtifact?
    let overlay: OverlayArtifact?
    let sceneDigest: String?
    let createdAt: String
}

struct ElementFingerprint: Codable {
    let id: String
    let role: String
    let roleFamily: String
    let normalizedName: String
    let normalizedValue: String
    let normalizedDescription: String
    let actionSignature: String
    let bboxBucket: String?
    let ancestorRoles: [String]
    let siblingLabelsBefore: [String]
    let siblingLabelsAfter: [String]
    let descendantText: [String]
    let semanticHash: String
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
    let mark: String?
    let x: Double?
    let y: Double?
    let x2: Double?
    let y2: Double?
    let reason: String?
}

struct UISummary: Codable {
    let focusedElement: String?
    let primaryActions: [String]
    let textInputs: [String]
    let scrollRegions: [String]
    let dangerousActions: [String]
    let tables: [UICollectionSummary]?
    let lists: [UICollectionSummary]?
    let visibleElementCount: Int
}

struct UICollectionSummary: Codable {
    let id: String
    let role: String
    let label: String?
    let rowsVisible: Int?
    let columnsVisible: Int?
    let childrenVisible: Int
    let sampleLabels: [String]
    let bbox: [Double]?
}

struct RecommendedTarget: Codable {
    let id: String
    let kind: String
    let role: String
    let name: String?
    let description: String?
    let score: Double
    let reason: String
    let bbox: [Double]?
    let actions: [String]
}

struct OverlayLegendItem: Codable {
    let mark: String
    let id: String?
    let kind: String
    let role: String
    let name: String?
    let bbox: [Double]?
}

struct OverlayArtifact: Codable {
    let path: String
    let mimeType: String
    let width: Int
    let height: Int
    let createdAt: String
    let legend: [OverlayLegendItem]
}

struct ActionRequest: Codable {
    let sessionId: String?
    let observationId: String
    let actions: [ComputerAction]
}

struct ActionVerification: Codable {
    let verified: Bool
    let confidence: Double
    let evidence: [String]
    let beforeDigest: String?
    let afterDigest: String?
    let visualBeforeDigest: String?
    let visualAfterDigest: String?
    let ocrEvidence: [String]?
}

struct ActionResult: Codable {
    let index: Int
    let type: String
    let route: String
    let status: String
    let message: String
    let id: String?
    let errorCode: String?
    let retryable: Bool?
    let verification: ActionVerification?
    let suggestedNextAction: String?

    init(
        index: Int,
        type: String,
        route: String,
        status: String,
        message: String,
        id: String?,
        errorCode: String?,
        retryable: Bool? = nil,
        verification: ActionVerification? = nil,
        suggestedNextAction: String? = nil
    ) {
        self.index = index
        self.type = type
        self.route = route
        self.status = status
        self.message = message
        self.id = id
        self.errorCode = errorCode
        self.retryable = retryable
        self.verification = verification
        self.suggestedNextAction = suggestedNextAction
    }
}

struct ActionResponse: Codable {
    let ok: Bool
    let sessionId: String?
    let results: [ActionResult]
    let nextObservation: Observation?
    let session: SessionContext?
}

struct StopResponse: Codable {
    let ok: Bool
    let stopped: Bool
    let message: String
}

struct ComputerUseRequest: Codable {
    let sessionId: String?
    let task: String
    let targetApp: String
    let targetWindow: String?
    let approvalMode: String?
    let allowVisionFallback: Bool?
    let autoExecute: Bool?
    let maxSteps: Double?
    let approvalToken: String?
}

struct ComputerUseStep: Codable {
    let index: Int
    let phase: String
    let status: String
    let observationId: String?
    let message: String
}

struct ComputerUseRisk: Codable {
    let level: String
    let reasons: [String]
    let requiresApproval: Bool
    let approvalTokenRequired: Bool
}

struct PlannedComputerAction: Codable {
    let index: Int
    let action: ComputerAction
    let rationale: String
}

struct ComputerUseResponse: Codable {
    let ok: Bool
    let status: String
    let mode: String
    let sessionId: String
    let task: String
    let targetApp: String
    let observation: Observation
    let finalObservation: Observation?
    let session: SessionContext?
    let steps: [ComputerUseStep]
    let risk: ComputerUseRisk
    let plannedActions: [PlannedComputerAction]
    let actionResponse: ActionResponse?
    let actionResponses: [ActionResponse]
    let suggestedNextActions: [String]
    let notes: [String]
}

struct SessionObservationRef: Codable {
    let observationId: String
    let sceneDigest: String
    let activeApp: String
    let activeWindow: String
    let source: String
    let fallbackRecommended: Bool
    let createdAt: String
}

struct SessionActionRef: Codable {
    let actionBatchId: String
    let observationId: String
    let actionTypes: [String]
    let statuses: [String]
    let ok: Bool
    let createdAt: String
}

struct SessionContext: Codable {
    let sessionId: String
    let createdAt: String
    let updatedAt: String
    let targetApp: String?
    let targetWindow: String?
    let observationCount: Int
    let actionCount: Int
    let lastObservationId: String?
    let lastSceneDigest: String?
    let recentObservations: [SessionObservationRef]
    let recentActions: [SessionActionRef]
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
