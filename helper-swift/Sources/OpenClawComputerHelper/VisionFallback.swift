import Foundation

final class VisionFallbackPlanner {
    func decide(
        requestMode: ObserveMode?,
        accessibilityTrusted: Bool,
        screenRecordingTrusted: Bool,
        screenshotAvailable: Bool,
        tree: [AxNode],
        elements: [String: AxElementSummary]
    ) -> VisionDecision {
        if requestMode == .vision {
            if screenshotAvailable {
                return VisionDecision(source: "vision", fallbackRecommended: false, fallbackReason: nil)
            }
            if screenRecordingTrusted {
                return VisionDecision(source: "ax", fallbackRecommended: true, fallbackReason: "screenshot_capture_failed")
            }
            return VisionDecision(source: "ax", fallbackRecommended: true, fallbackReason: "vision_requested_but_screen_recording_unavailable")
        }

        if !accessibilityTrusted {
            if screenshotAvailable {
                return VisionDecision(source: "ax+vision", fallbackRecommended: true, fallbackReason: "accessibility_not_trusted")
            }
            if screenRecordingTrusted {
                return VisionDecision(source: "ax", fallbackRecommended: true, fallbackReason: "accessibility_not_trusted_and_screenshot_capture_failed")
            }
            return VisionDecision(source: "ax", fallbackRecommended: true, fallbackReason: "accessibility_not_trusted")
        }

        let totalNodes = tree.reduce(0) { $0 + countNodes($1) }
        if elements.isEmpty || totalNodes < 2 {
            if screenshotAvailable {
                return VisionDecision(source: requestMode == .axWithScreenshot ? "ax+vision" : "ax", fallbackRecommended: true, fallbackReason: "ax_surface_too_sparse")
            }
            if screenRecordingTrusted {
                return VisionDecision(source: "ax", fallbackRecommended: true, fallbackReason: "ax_surface_too_sparse_and_screenshot_capture_failed")
            }
            return VisionDecision(source: "ax", fallbackRecommended: true, fallbackReason: "ax_surface_too_sparse_and_no_screen_recording")
        }

        if requestMode == .axWithScreenshot {
            if screenshotAvailable {
                return VisionDecision(source: "ax+vision", fallbackRecommended: false, fallbackReason: nil)
            }
            if screenRecordingTrusted {
                return VisionDecision(source: "ax", fallbackRecommended: true, fallbackReason: "screenshot_capture_failed")
            }
        }

        return VisionDecision(source: "ax", fallbackRecommended: false, fallbackReason: nil)
    }

    private func countNodes(_ node: AxNode) -> Int {
        1 + node.children.reduce(0) { $0 + countNodes($1) }
    }
}
