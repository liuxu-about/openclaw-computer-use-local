import ApplicationServices
import Foundation

final class ActionExecutor {
    private let accessibilityService: AccessibilityService
    private let ocrTextService = OCRTextService()
    private let visualVerifier = VisualVerifier()
    private let fingerprintBuilder = ElementFingerprintBuilder()

    private struct TargetedElement {
        let element: AXUIElement
        let summary: AxElementSummary
        let resolution: ResolvedElement?
    }

    private enum TargetResolution {
        case success(TargetedElement)
        case failure(ActionResult)
    }

    private struct VerificationSnapshot {
        let focused: AxElementSummary?
        let sceneDigest: String
        let elements: [String: AxElementSummary]
    }

    private struct SubmitAssessment {
        let success: Bool
        let residualDraft: Bool
        let sentEchoDetected: Bool
        let message: String
    }

    private struct ResolvedElement {
        let element: AXUIElement
        let summary: AxElementSummary
        let requestedId: String
        let remappedFromId: String?

        var wasRemapped: Bool {
            remappedFromId != nil
        }
    }

    init(accessibilityService: AccessibilityService) {
        self.accessibilityService = accessibilityService
    }

    func execute(
        request: ActionRequest,
        targetHint: String?,
        windowHint: String?,
        storedObservation: StoredObservation?
    ) -> [ActionResult] {
        var scene = accessibilityService.captureScene(targetNamed: targetHint, windowNamed: windowHint, maxNodes: 300)

        return request.actions.enumerated().map { index, action in
            let beforeScene = scene
            let visualBefore = visualSnapshotIfUseful(action: action, scene: beforeScene)
            let result = executeSingle(
                index: index,
                action: action,
                scene: scene,
                storedObservation: storedObservation
            )
            var afterScene: SceneSnapshot?
            var visualAfter: VisualVerificationSnapshot?
            if result.status == "ok" || result.status == "retryable" {
                let refreshed = accessibilityService.captureScene(targetNamed: targetHint, windowNamed: windowHint, maxNodes: 300)
                scene = refreshed
                afterScene = refreshed
                visualAfter = visualSnapshotIfUseful(action: action, scene: refreshed)
            }
            return enrichResult(result, before: beforeScene, after: afterScene, visualBefore: visualBefore, visualAfter: visualAfter)
        }
    }

    private func executeSingle(
        index: Int,
        action: ComputerAction,
        scene: SceneSnapshot,
        storedObservation: StoredObservation?
    ) -> ActionResult {
        let action = actionResolvingOverlayMark(action, storedObservation: storedObservation)
        let route = routeForAction(action.type)

        switch action.type {
        case "wait":
            let milliseconds = max(0, action.ms ?? action.amount ?? 250)
            Thread.sleep(forTimeInterval: milliseconds / 1000.0)
            return ActionResult(
                index: index,
                type: action.type,
                route: route,
                status: "ok",
                message: "Waited for \(Int(milliseconds))ms.",
                id: action.id,
                errorCode: nil
            )
        case "vision_click":
            if let guardResult = frontmostGuard(index: index, action: action, scene: scene, route: "vision") {
                return guardResult
            }
            return performVisionClick(index: index, action: action, scene: scene, storedObservation: storedObservation)
        case "vision_click_text":
            if let guardResult = frontmostGuard(index: index, action: action, scene: scene, route: "vision") {
                return guardResult
            }
            return performVisionClickText(index: index, action: action, scene: scene, storedObservation: storedObservation)
        case "vision_drag":
            if let guardResult = frontmostGuard(index: index, action: action, scene: scene, route: "vision") {
                return guardResult
            }
            return performVisionDrag(index: index, action: action, storedObservation: storedObservation)
        case "key", "type", "keypress":
            if let guardResult = frontmostGuard(index: index, action: action, scene: scene, route: "keyboard") {
                return guardResult
            }
            return performKey(index: index, action: action)
        case "scroll":
            if let guardResult = frontmostGuard(index: index, action: action, scene: scene, route: "scroll") {
                return guardResult
            }
            return performScroll(index: index, action: action, scene: scene, storedObservation: storedObservation)
        case "scroll_to_bottom":
            if let guardResult = frontmostGuard(index: index, action: action, scene: scene, route: "scroll") {
                return guardResult
            }
            return performScrollToBottom(index: index, action: action, scene: scene, storedObservation: storedObservation)
        case "scroll_until_text_visible":
            if let guardResult = frontmostGuard(index: index, action: action, scene: scene, route: "scroll") {
                return guardResult
            }
            return performScrollUntilTextVisible(index: index, action: action, scene: scene, storedObservation: storedObservation)
        case "clear_focused_text":
            if let guardResult = frontmostGuard(index: index, action: action, scene: scene, route: "text_pipeline") {
                return guardResult
            }
            return performClearFocusedText(index: index, action: action, scene: scene, storedObservation: storedObservation)
        case "paste_text":
            if let guardResult = frontmostGuard(index: index, action: action, scene: scene, route: "text_pipeline") {
                return guardResult
            }
            return performPasteText(index: index, action: action, scene: scene, storedObservation: storedObservation)
        case "replace_text":
            if let guardResult = frontmostGuard(index: index, action: action, scene: scene, route: "text_pipeline") {
                return guardResult
            }
            return performReplaceText(index: index, action: action, scene: scene, storedObservation: storedObservation)
        case "compose_and_submit", "compose_and_send", "send_message":
            if let guardResult = frontmostGuard(index: index, action: action, scene: scene, route: "text_pipeline") {
                return guardResult
            }
            return performComposeAndSubmit(index: index, action: action, scene: scene, storedObservation: storedObservation)
        case "submit":
            if let guardResult = frontmostGuard(index: index, action: action, scene: scene, route: "text_pipeline") {
                return guardResult
            }
            return performSubmit(index: index, action: action, scene: scene, storedObservation: storedObservation)
        default:
            guard accessibilityService.accessibilityTrusted() else {
                return ActionResult(
                    index: index,
                    type: action.type,
                    route: route,
                    status: "blocked",
                    message: "Accessibility permission is missing, so AX-native action execution is blocked.",
                    id: action.id,
                    errorCode: "permission_denied"
                )
            }

            guard let elementId = action.id else {
                return ActionResult(
                    index: index,
                    type: action.type,
                    route: route,
                    status: "invalid",
                    message: "This action requires an element id from the latest observation.",
                    id: nil,
                    errorCode: "missing_id"
                )
            }

            guard let resolved = resolveElement(
                requestedId: elementId,
                scene: scene,
                storedObservation: storedObservation
            ) else {
                return ActionResult(
                    index: index,
                    type: action.type,
                    route: route,
                    status: "stale",
                    message: "Element id \(elementId) is not available in the current AX snapshot.",
                    id: elementId,
                    errorCode: "stale_id"
                )
            }

            if resolved.summary.enabled == false && action.type != "focus" {
                return ActionResult(
                    index: index,
                    type: action.type,
                    route: route,
                    status: "blocked",
                    message: "Element \(resolved.summary.id) is disabled.",
                    id: resolved.summary.id,
                    errorCode: "not_enabled"
                )
            }

            switch action.type {
            case "press":
                return withResolutionContext(
                    performPress(index: index, element: resolved.element, summary: resolved.summary),
                    resolution: resolved
                )
            case "focus":
                return withResolutionContext(
                    performFocus(index: index, element: resolved.element, summary: resolved.summary),
                    resolution: resolved
                )
            case "select":
                return withResolutionContext(
                    performSelect(index: index, element: resolved.element, summary: resolved.summary),
                    resolution: resolved
                )
            case "set_value":
                return withResolutionContext(
                    performSetValue(
                        index: index,
                        element: resolved.element,
                        summary: resolved.summary,
                        text: action.text ?? action.value ?? "",
                        replace: true
                    ),
                    resolution: resolved
                )
            case "append_text":
                return withResolutionContext(
                    performSetValue(
                        index: index,
                        element: resolved.element,
                        summary: resolved.summary,
                        text: action.text ?? action.value ?? "",
                        replace: false
                    ),
                    resolution: resolved
                )
            default:
                return ActionResult(
                    index: index,
                    type: action.type,
                    route: route,
                    status: "unsupported",
                    message: "Action type \(action.type) is not implemented in the helper yet.",
                    id: resolved.summary.id,
                    errorCode: "not_implemented"
                )
            }
        }
    }

    private func frontmostGuard(index: Int, action: ComputerAction, scene: SceneSnapshot, route: String) -> ActionResult? {
        guard let target = scene.target else {
            return nil
        }
        let frontmost = accessibilityService.frontmostWindowInfo()
        guard frontmost.bundleId == target.bundleId else {
            return ActionResult(
                index: index,
                type: action.type,
                route: route,
                status: "blocked",
                message: "Frontmost app changed before event synthesis. Expected \(target.appName) (\(target.bundleId)), but frontmost is \(frontmost.name) (\(frontmost.bundleId)).",
                id: action.id,
                errorCode: "target_not_frontmost"
            )
        }

        if let expectedTitle = target.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !expectedTitle.isEmpty,
           let actualTitle = frontmost.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !actualTitle.isEmpty,
           !titlesProbablyMatch(expectedTitle, actualTitle)
        {
            return ActionResult(
                index: index,
                type: action.type,
                route: route,
                status: "blocked",
                message: "Frontmost window changed before event synthesis. Expected \"\(expectedTitle)\", but frontmost window is \"\(actualTitle)\".",
                id: action.id,
                errorCode: "target_window_changed"
            )
        }
        return nil
    }

    private func actionResolvingOverlayMark(_ action: ComputerAction, storedObservation: StoredObservation?) -> ComputerAction {
        guard let mark = action.mark?.trimmingCharacters(in: .whitespacesAndNewlines), !mark.isEmpty else {
            return action
        }
        guard let item = storedObservation?.overlay?.legend.first(where: { $0.mark.caseInsensitiveCompare(mark) == .orderedSame }) else {
            return action
        }

        let bboxCenter = item.id == nil && action.x == nil && action.y == nil ? center(of: item.bbox) : nil
        return ComputerAction(
            type: action.type,
            id: action.id ?? item.id,
            text: action.text,
            value: action.value,
            keys: action.keys,
            strategy: action.strategy,
            direction: action.direction,
            amount: action.amount,
            ms: action.ms,
            retryCount: action.retryCount,
            mark: action.mark,
            x: action.x ?? bboxCenter?.x,
            y: action.y ?? bboxCenter?.y,
            x2: action.x2,
            y2: action.y2,
            reason: action.reason
        )
    }

    private func center(of bbox: [Double]?) -> (x: Double, y: Double)? {
        guard let bbox, bbox.count == 4 else {
            return nil
        }
        return (bbox[0] + bbox[2] / 2.0, bbox[1] + bbox[3] / 2.0)
    }

    private func titlesProbablyMatch(_ expected: String, _ actual: String) -> Bool {
        let lhs = normalizedText(expected)
        let rhs = normalizedText(actual)
        guard !lhs.isEmpty, !rhs.isEmpty else {
            return true
        }
        return lhs == rhs || lhs.contains(rhs) || rhs.contains(lhs)
    }

    private func performVisionClick(
        index: Int,
        action: ComputerAction,
        scene: SceneSnapshot,
        storedObservation: StoredObservation?
    ) -> ActionResult {
        guard accessibilityService.accessibilityTrusted() else {
            return ActionResult(
                index: index,
                type: "vision_click",
                route: "vision",
                status: "blocked",
                message: "Accessibility permission is required for coordinate fallback actions.",
                id: nil,
                errorCode: "permission_denied"
            )
        }

        if let elementId = action.id, action.x == nil || action.y == nil {
            guard let resolved = resolveElement(
                requestedId: elementId,
                scene: scene,
                storedObservation: storedObservation
            ) else {
                return ActionResult(
                    index: index,
                    type: "vision_click",
                    route: "vision_mark",
                    status: "stale",
                    message: "Overlay mark resolved to element \(elementId), but that element is not available in the current AX snapshot.",
                    id: elementId,
                    errorCode: "stale_id"
                )
            }
            let pressed = performPress(index: index, element: resolved.element, summary: resolved.summary)
            return withResolutionContext(
                ActionResult(
                    index: pressed.index,
                    type: "vision_click",
                    route: "vision_mark_ax",
                    status: pressed.status,
                    message: "Overlay mark resolved to \(resolved.summary.id). \(pressed.message)",
                    id: pressed.id,
                    errorCode: pressed.errorCode
                ),
                resolution: resolved
            )
        }

        guard let x = action.x, let y = action.y else {
            return ActionResult(
                index: index,
                type: "vision_click",
                route: "vision",
                status: "invalid",
                message: "vision_click requires x and y coordinates.",
                id: nil,
                errorCode: "missing_coordinates"
            )
        }

        guard let point = translatedVisionPoint(x: x, y: y, storedObservation: storedObservation) else {
            return ActionResult(
                index: index,
                type: "vision_click",
                route: "vision",
                status: "invalid",
                message: "vision_click could not translate screenshot-relative coordinates into screen coordinates.",
                id: nil,
                errorCode: "coordinate_translation_failed"
            )
        }

        if let hitElement = accessibilityService.elementAtPosition(point, applicationElement: scene.target?.appElement) ?? accessibilityService.elementAtPosition(point),
           accessibilityService.actionNames(hitElement).contains(kAXPressAction as String)
        {
            let error = accessibilityService.performAction(hitElement, action: kAXPressAction as CFString)
            let result = resultFromAXError(
                error,
                index: index,
                type: "vision_click",
                route: "vision_ax_hit",
                id: nil,
                successMessage: "Translated screenshot-relative click to screen point (\(Int(point.x)), \(Int(point.y))) and activated the hit-tested AX element."
            )
            if result.status == "ok" {
                return result
            }
        }

        if accessibilityService.postLeftClick(at: point) {
            return ActionResult(
                index: index,
                type: "vision_click",
                route: "vision_cg_event",
                status: "ok",
                message: "Posted a left click at screen point (\(Int(point.x)), \(Int(point.y))).",
                id: nil,
                errorCode: nil
            )
        }

        return ActionResult(
            index: index,
            type: "vision_click",
            route: "vision",
            status: "error",
            message: "Failed to dispatch a coordinate click at (\(Int(point.x)), \(Int(point.y))).",
            id: nil,
            errorCode: "cg_event_failed"
        )
    }

    private func performVisionClickText(
        index: Int,
        action: ComputerAction,
        scene: SceneSnapshot,
        storedObservation: StoredObservation?
    ) -> ActionResult {
        guard accessibilityService.accessibilityTrusted() else {
            return ActionResult(
                index: index,
                type: "vision_click_text",
                route: "vision",
                status: "blocked",
                message: "Accessibility permission is required for OCR-guided coordinate actions.",
                id: nil,
                errorCode: "permission_denied"
            )
        }

        guard let query = action.text ?? action.value, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ActionResult(
                index: index,
                type: "vision_click_text",
                route: "vision",
                status: "invalid",
                message: "vision_click_text requires a non-empty text query.",
                id: nil,
                errorCode: "missing_text"
            )
        }

        guard let screenshot = storedObservation?.screenshot else {
            return ActionResult(
                index: index,
                type: "vision_click_text",
                route: "vision",
                status: "invalid",
                message: "vision_click_text requires a prior observation with screenshot metadata.",
                id: nil,
                errorCode: "missing_screenshot"
            )
        }

        guard let match = ocrTextService.bestMatch(screenshot: screenshot, query: query) else {
            return ActionResult(
                index: index,
                type: "vision_click_text",
                route: "vision",
                status: "retryable",
                message: "OCR could not find text matching \"\(query)\" in the stored screenshot.",
                id: nil,
                errorCode: "text_not_found"
            )
        }

        let center = CGPoint(x: match.boundingBox.midX, y: match.boundingBox.midY)
        let clickAction = ComputerAction(
            type: "vision_click",
            id: nil,
            text: nil,
            value: nil,
            keys: nil,
            strategy: nil,
            direction: nil,
            amount: nil,
            ms: action.ms,
            retryCount: action.retryCount,
            mark: nil,
            x: Double(center.x),
            y: Double(center.y),
            x2: nil,
            y2: nil,
            reason: action.reason ?? "OCR matched text \(match.text)"
        )

        let clicked = performVisionClick(
            index: index,
            action: clickAction,
            scene: scene,
            storedObservation: storedObservation
        )
        return remapResultType(
            clicked,
            to: "vision_click_text",
            route: clicked.route,
            prefix: "Matched OCR text \"\(match.text)\" and attempted a click near its center."
        )
    }

    private func performVisionDrag(
        index: Int,
        action: ComputerAction,
        storedObservation: StoredObservation?
    ) -> ActionResult {
        guard accessibilityService.accessibilityTrusted() else {
            return ActionResult(
                index: index,
                type: "vision_drag",
                route: "vision",
                status: "blocked",
                message: "Accessibility permission is required for coordinate drag actions.",
                id: nil,
                errorCode: "permission_denied"
            )
        }

        guard let startX = action.x, let startY = action.y, let endX = action.x2, let endY = action.y2 else {
            return ActionResult(
                index: index,
                type: "vision_drag",
                route: "vision",
                status: "invalid",
                message: "vision_drag requires x, y, x2, and y2 coordinates.",
                id: nil,
                errorCode: "missing_coordinates"
            )
        }

        guard let start = translatedVisionPoint(x: startX, y: startY, storedObservation: storedObservation),
              let end = translatedVisionPoint(x: endX, y: endY, storedObservation: storedObservation) else {
            return ActionResult(
                index: index,
                type: "vision_drag",
                route: "vision",
                status: "invalid",
                message: "vision_drag could not translate screenshot-relative coordinates into screen coordinates.",
                id: nil,
                errorCode: "coordinate_translation_failed"
            )
        }

        let steps = max(4, min(48, Int((action.ms ?? 180) / 16.0)))
        if accessibilityService.postLeftDrag(from: start, to: end, steps: steps) {
            return ActionResult(
                index: index,
                type: "vision_drag",
                route: "vision_cg_drag",
                status: "ok",
                message: "Dragged from (\(Int(start.x)), \(Int(start.y))) to (\(Int(end.x)), \(Int(end.y))).",
                id: nil,
                errorCode: nil
            )
        }

        return ActionResult(
            index: index,
            type: "vision_drag",
            route: "vision",
            status: "error",
            message: "Failed to dispatch a drag gesture from (\(Int(start.x)), \(Int(start.y))) to (\(Int(end.x)), \(Int(end.y))).",
            id: nil,
            errorCode: "cg_event_failed"
        )
    }

    private func performKey(index: Int, action: ComputerAction) -> ActionResult {
        guard accessibilityService.accessibilityTrusted() else {
            return ActionResult(
                index: index,
                type: action.type,
                route: "keyboard",
                status: "blocked",
                message: "Accessibility permission is required for synthesized keyboard input.",
                id: action.id,
                errorCode: "permission_denied"
            )
        }

        let text = action.text ?? action.value
        do {
            try accessibilityService.postKeySequence(keys: action.keys ?? [], text: text)
            let message: String
            if let text, !text.isEmpty, !(action.keys ?? []).isEmpty {
                message = "Posted keyboard shortcut \(action.keys!.joined(separator: "+")) and typed text."
            } else if let text, !text.isEmpty {
                message = "Typed text via CGEvent keyboard synthesis."
            } else {
                message = "Posted keyboard shortcut \(action.keys?.joined(separator: "+") ?? "")."
            }
            return ActionResult(index: index, type: action.type, route: "keyboard", status: "ok", message: message, id: action.id, errorCode: nil)
        } catch {
            return ActionResult(
                index: index,
                type: action.type,
                route: "keyboard",
                status: "error",
                message: "Keyboard synthesis failed: \(error.localizedDescription).",
                id: action.id,
                errorCode: "cg_event_failed"
            )
        }
    }

    private func performClearFocusedText(
        index: Int,
        action: ComputerAction,
        scene: SceneSnapshot,
        storedObservation: StoredObservation?
    ) -> ActionResult {
        let targetResult = resolveTextTarget(
            index: index,
            action: action,
            scene: scene,
            storedObservation: storedObservation,
            actionType: "clear_focused_text"
        )

        guard case .success(let target) = targetResult else {
            if case .failure(let failure) = targetResult {
                return failure
            }
            fatalError("Unreachable target resolution state.")
        }

        if accessibilityService.isAttributeSettable(target.element, attribute: kAXValueAttribute as CFString) {
            let axResult = withResolutionContext(
                resultFromAXError(
                    accessibilityService.setAttribute(target.element, attribute: kAXValueAttribute as CFString, value: "" as CFString),
                    index: index,
                    type: "clear_focused_text",
                    route: "text_pipeline",
                    id: target.summary.id,
                    successMessage: "Cleared the target text value through AX."
                ),
                resolution: target.resolution
            )
            if axResult.status == "ok" {
                wait(milliseconds: action.ms ?? 60)
                return axResult
            }
        }

        guard prepareElementForKeyboardInput(element: target.element, summary: target.summary) else {
            return withResolutionContext(
                ActionResult(
                    index: index,
                    type: "clear_focused_text",
                    route: "text_pipeline",
                    status: "unsupported",
                    message: "The current target is not focusable enough for keyboard-based clearing.",
                    id: target.summary.id,
                    errorCode: "focus_unavailable"
                ),
                resolution: target.resolution
            )
        }

        do {
            try accessibilityService.postKeySequence(keys: ["cmd", "a"], text: nil)
            try accessibilityService.postKeySequence(keys: ["delete"], text: nil)
            wait(milliseconds: action.ms ?? 80)
            return withResolutionContext(
                ActionResult(
                    index: index,
                    type: "clear_focused_text",
                    route: "text_pipeline",
                    status: "ok",
                    message: "Focused the target and cleared its current draft via keyboard selection + delete.",
                    id: target.summary.id,
                    errorCode: nil
                ),
                resolution: target.resolution
            )
        } catch {
            return withResolutionContext(
                ActionResult(
                    index: index,
                    type: "clear_focused_text",
                    route: "text_pipeline",
                    status: "error",
                    message: "Failed to clear the current draft: \(error.localizedDescription).",
                    id: target.summary.id,
                    errorCode: "cg_event_failed"
                ),
                resolution: target.resolution
            )
        }
    }

    private func performPasteText(
        index: Int,
        action: ComputerAction,
        scene: SceneSnapshot,
        storedObservation: StoredObservation?
    ) -> ActionResult {
        guard let text = action.text ?? action.value, !text.isEmpty else {
            return ActionResult(
                index: index,
                type: "paste_text",
                route: "text_pipeline",
                status: "invalid",
                message: "paste_text requires a non-empty text payload.",
                id: action.id,
                errorCode: "missing_text"
            )
        }

        let targetResult = resolveTextTarget(
            index: index,
            action: action,
            scene: scene,
            storedObservation: storedObservation,
            actionType: "paste_text"
        )

        guard case .success(let target) = targetResult else {
            if case .failure(let failure) = targetResult {
                return failure
            }
            fatalError("Unreachable target resolution state.")
        }

        guard prepareElementForKeyboardInput(element: target.element, summary: target.summary) else {
            return withResolutionContext(
                ActionResult(
                    index: index,
                    type: "paste_text",
                    route: "text_pipeline",
                    status: "unsupported",
                    message: "The current target is not focusable enough for paste_text.",
                    id: target.summary.id,
                    errorCode: "focus_unavailable"
                ),
                resolution: target.resolution
            )
        }

        do {
            try accessibilityService.postPasteText(text)
            wait(milliseconds: action.ms ?? 180)
            let verification = verifyTextCommitted(
                expected: text,
                replace: false,
                target: target
            )

            return withResolutionContext(
                ActionResult(
                    index: index,
                    type: "paste_text",
                    route: "text_pipeline",
                    status: verification.status,
                    message: verification.message,
                    id: target.summary.id,
                    errorCode: verification.errorCode
                ),
                resolution: target.resolution
            )
        } catch {
            return withResolutionContext(
                ActionResult(
                    index: index,
                    type: "paste_text",
                    route: "text_pipeline",
                    status: "error",
                    message: "Paste failed: \(error.localizedDescription).",
                    id: target.summary.id,
                    errorCode: "paste_failed"
                ),
                resolution: target.resolution
            )
        }
    }

    private func performReplaceText(
        index: Int,
        action: ComputerAction,
        scene: SceneSnapshot,
        storedObservation: StoredObservation?
    ) -> ActionResult {
        guard let text = action.text ?? action.value, !text.isEmpty else {
            return ActionResult(
                index: index,
                type: "replace_text",
                route: "text_pipeline",
                status: "invalid",
                message: "replace_text requires a non-empty text payload.",
                id: action.id,
                errorCode: "missing_text"
            )
        }

        let targetResult = resolveTextTarget(
            index: index,
            action: action,
            scene: scene,
            storedObservation: storedObservation,
            actionType: "replace_text"
        )

        guard case .success(let target) = targetResult else {
            if case .failure(let failure) = targetResult {
                return failure
            }
            fatalError("Unreachable target resolution state.")
        }

        let maxAttempts = max(1, min(3, Int(action.retryCount ?? 0) + 1))
        for attempt in 1...maxAttempts {
            let clearResult = clearTargetContents(index: index, target: target, settleMilliseconds: 60)
            if clearResult.status != "ok" {
                return withResolutionContext(clearResult, resolution: target.resolution)
            }

            do {
                try accessibilityService.postPasteText(text)
            } catch {
                return withResolutionContext(
                    ActionResult(
                        index: index,
                        type: "replace_text",
                        route: "text_pipeline",
                        status: "error",
                        message: "Replace failed while pasting new text: \(error.localizedDescription).",
                        id: target.summary.id,
                        errorCode: "paste_failed"
                    ),
                    resolution: target.resolution
                )
            }

            wait(milliseconds: action.ms ?? 180)
            let verification = verifyTextCommitted(
                expected: text,
                replace: true,
                target: target
            )
            if verification.status == "ok" || verification.status == "best_effort" || attempt == maxAttempts {
                return withResolutionContext(
                    ActionResult(
                        index: index,
                        type: "replace_text",
                        route: "text_pipeline",
                        status: verification.status == "best_effort" ? "ok" : verification.status,
                        message: attempt > 1
                            ? "Replaced text after \(attempt) attempts. \(verification.message)"
                            : verification.message,
                        id: target.summary.id,
                        errorCode: verification.errorCode
                    ),
                    resolution: target.resolution
                )
            }
        }

        return withResolutionContext(
            ActionResult(
                index: index,
                type: "replace_text",
                route: "text_pipeline",
                status: "retryable",
                message: "replace_text did not expose a verifiable text change after the requested retries.",
                id: target.summary.id,
                errorCode: "verification_failed"
            ),
            resolution: target.resolution
        )
    }

    private func performComposeAndSubmit(
        index: Int,
        action: ComputerAction,
        scene: SceneSnapshot,
        storedObservation: StoredObservation?
    ) -> ActionResult {
        guard let text = action.text ?? action.value, !text.isEmpty else {
            return ActionResult(
                index: index,
                type: "compose_and_submit",
                route: "text_pipeline",
                status: "invalid",
                message: "compose_and_submit requires a non-empty text payload.",
                id: action.id,
                errorCode: "missing_text"
            )
        }

        let replaceAction = derivedAction(
            from: action,
            type: "replace_text",
            ms: action.ms ?? 180,
            retryCount: action.retryCount
        )
        let firstReplace = performReplaceText(
            index: index,
            action: replaceAction,
            scene: scene,
            storedObservation: storedObservation
        )
        guard firstReplace.status == "ok" else {
            return remapResultType(
                firstReplace,
                to: "compose_and_submit",
                route: "text_pipeline",
                prefix: "compose_and_submit could not stage the outgoing text."
            )
        }

        let refreshTargetHint = scene.target?.bundleId ?? scene.target?.appName
        let refreshWindowHint = scene.target?.windowTitle
        let stagedScene = accessibilityService.captureScene(
            targetNamed: refreshTargetHint,
            windowNamed: refreshWindowHint,
            maxNodes: 260
        )

        let submitAction = derivedAction(
            from: action,
            type: "submit",
            text: text,
            ms: max(120, action.ms ?? 220),
            retryCount: action.retryCount
        )
        let firstSubmit = performSubmit(
            index: index,
            action: submitAction,
            scene: stagedScene,
            storedObservation: storedObservation
        )
        if firstSubmit.status == "ok" {
            return remapResultType(
                firstSubmit,
                to: "compose_and_submit",
                route: "text_pipeline",
                prefix: "Composed and submitted the requested text."
            )
        }

        let shouldRepair = firstSubmit.status == "retryable" || firstSubmit.errorCode == "submission_unverified"
        guard shouldRepair else {
            return remapResultType(
                firstSubmit,
                to: "compose_and_submit",
                route: "text_pipeline",
                prefix: "compose_and_submit staged the text but the submit step failed."
            )
        }

        let refreshedScene = accessibilityService.captureScene(
            targetNamed: refreshTargetHint,
            windowNamed: refreshWindowHint,
            maxNodes: 260
        )
        let repairReplace = performReplaceText(
            index: index,
            action: replaceAction,
            scene: refreshedScene,
            storedObservation: storedObservation
        )
        guard repairReplace.status == "ok" else {
            return remapResultType(
                repairReplace,
                to: "compose_and_submit",
                route: "text_pipeline",
                prefix: "compose_and_submit detected a residual draft and attempted one repair pass, but re-staging the text failed."
            )
        }

        let repairScene = accessibilityService.captureScene(
            targetNamed: refreshTargetHint,
            windowNamed: refreshWindowHint,
            maxNodes: 260
        )
        let secondSubmit = performSubmit(
            index: index,
            action: submitAction,
            scene: repairScene,
            storedObservation: storedObservation
        )
        if secondSubmit.status == "ok" {
            return remapResultType(
                secondSubmit,
                to: "compose_and_submit",
                route: "text_pipeline",
                prefix: "Composed and submitted the requested text after one residual-draft repair pass."
            )
        }

        return remapResultType(
            secondSubmit,
            to: "compose_and_submit",
            route: "text_pipeline",
            prefix: "compose_and_submit staged the text and retried once after a residual draft, but the send transition still could not be verified."
        )
    }

    private func performSubmit(
        index: Int,
        action: ComputerAction,
        scene: SceneSnapshot,
        storedObservation: StoredObservation?
    ) -> ActionResult {
        guard accessibilityService.accessibilityTrusted() else {
            return ActionResult(
                index: index,
                type: "submit",
                route: "text_pipeline",
                status: "blocked",
                message: "Accessibility permission is required for synthesized submit actions.",
                id: action.id,
                errorCode: "permission_denied"
            )
        }

        let targetResult = resolveTextTarget(
            index: index,
            action: action,
            scene: scene,
            storedObservation: storedObservation,
            actionType: "submit"
        )

        guard case .success(let target) = targetResult else {
            if case .failure(let failure) = targetResult {
                return failure
            }
            fatalError("Unreachable target resolution state.")
        }

        guard prepareElementForKeyboardInput(element: target.element, summary: target.summary) else {
            return withResolutionContext(
                ActionResult(
                    index: index,
                    type: "submit",
                    route: "text_pipeline",
                    status: "unsupported",
                    message: "The current target is not focusable enough for submit.",
                    id: target.summary.id,
                    errorCode: "focus_unavailable"
                ),
                resolution: target.resolution
            )
        }

        let strategy = normalizedSubmitStrategy(action.strategy)
        let keys = submitKeys(for: action, strategy: strategy)
        let allowsButtonFallback = submitAllowsButtonFallback(action: action, strategy: strategy)
        let buttonOnly = submitButtonOnly(strategy: strategy)
        guard !keys.isEmpty || allowsButtonFallback else {
            return withResolutionContext(
                ActionResult(
                    index: index,
                    type: "submit",
                    route: "text_pipeline",
                    status: "invalid",
                    message: "submit requires a supported strategy, explicit keys, or a button-based fallback mode.",
                    id: target.summary.id,
                    errorCode: "invalid_strategy"
                ),
                resolution: target.resolution
            )
        }

        let settleMilliseconds = max(80, action.ms ?? 180)
        let maxAttempts = max(1, min(3, Int(action.retryCount ?? 0) + 1))
        let targetHint = scene.target?.bundleId ?? scene.target?.appName
        let windowHint = scene.target?.windowTitle
        let baseline = verificationSnapshot(targetHint: targetHint, windowHint: windowHint, currentScene: scene)

        for attempt in 1...maxAttempts {
            if !buttonOnly {
                if settleMilliseconds > 0 {
                    wait(milliseconds: settleMilliseconds)
                }

                do {
                    try accessibilityService.postKeySequence(keys: keys, text: nil)
                } catch {
                    return withResolutionContext(
                        ActionResult(
                            index: index,
                            type: "submit",
                            route: "text_pipeline",
                            status: "error",
                            message: "Submit keyboard synthesis failed: \(error.localizedDescription).",
                            id: target.summary.id,
                            errorCode: "cg_event_failed"
                        ),
                        resolution: target.resolution
                    )
                }

                wait(milliseconds: settleMilliseconds)
                let post = verificationSnapshot(targetHint: targetHint, windowHint: windowHint)
                let assessment = submitAssessment(before: baseline, after: post, target: target)
                if assessment.success {
                    let strategyDescription = action.strategy ?? (action.keys != nil ? keys.joined(separator: "+") : "auto")
                    return withResolutionContext(
                        ActionResult(
                            index: index,
                            type: "submit",
                            route: "text_pipeline",
                            status: "ok",
                            message: "Submitted using \(strategyDescription) after a \(Int(settleMilliseconds))ms settle window. \(assessment.message)",
                            id: target.summary.id,
                            errorCode: nil
                        ),
                        resolution: target.resolution
                    )
                }

                if allowsButtonFallback {
                    let buttonResult = attemptSubmitButtonFallback(
                        index: index,
                        target: target,
                        targetHint: targetHint,
                        windowHint: windowHint,
                        baseline: baseline,
                        settleMilliseconds: settleMilliseconds
                    )
                    if let buttonResult {
                        return withResolutionContext(buttonResult, resolution: target.resolution)
                    }
                }

                if !assessment.residualDraft && attempt < maxAttempts {
                    continue
                }
            }

            if buttonOnly || (allowsButtonFallback && attempt < maxAttempts) {
                let buttonResult = attemptSubmitButtonFallback(
                    index: index,
                    target: target,
                    targetHint: targetHint,
                    windowHint: windowHint,
                    baseline: baseline,
                    settleMilliseconds: settleMilliseconds
                )
                if let buttonResult {
                    return withResolutionContext(buttonResult, resolution: target.resolution)
                }
            }
        }

        let post = verificationSnapshot(targetHint: targetHint, windowHint: windowHint)
        let assessment = submitAssessment(before: baseline, after: post, target: target)
        let tail = assessment.residualDraft
            ? " A residual draft still appears to be present in the input region."
            : ""
        return withResolutionContext(
            ActionResult(
                index: index,
                type: "submit",
                route: "text_pipeline",
                status: "retryable",
                message: "submit did not produce a verifiable committed-send transition after \(maxAttempts) attempt(s). \(assessment.message)\(tail)",
                id: target.summary.id,
                errorCode: "submission_unverified"
            ),
            resolution: target.resolution
        )
    }

    private func performPress(index: Int, element: AXUIElement, summary: AxElementSummary) -> ActionResult {
        guard summary.actions.contains(kAXPressAction as String) else {
            return ActionResult(
                index: index,
                type: "press",
                route: "ax",
                status: "unsupported",
                message: "Element \(summary.id) does not expose AXPress.",
                id: summary.id,
                errorCode: "action_unsupported"
            )
        }

        let error = accessibilityService.performAction(element, action: kAXPressAction as CFString)
        return resultFromAXError(
            error,
            index: index,
            type: "press",
            route: "ax",
            id: summary.id,
            successMessage: "Pressed \(summary.role) \(summary.name ?? summary.description ?? summary.id)."
        )
    }

    private func performSelect(index: Int, element: AXUIElement, summary: AxElementSummary) -> ActionResult {
        if accessibilityService.isAttributeSettable(element, attribute: kAXSelectedAttribute as CFString) {
            let error = accessibilityService.setAttribute(element, attribute: kAXSelectedAttribute as CFString, value: kCFBooleanTrue)
            let result = resultFromAXError(
                error,
                index: index,
                type: "select",
                route: "ax",
                id: summary.id,
                successMessage: "Selected \(summary.role) \(summary.name ?? summary.description ?? summary.id)."
            )
            if result.status == "ok" {
                return result
            }
        }

        if summary.actions.contains(kAXPressAction as String) {
            let error = accessibilityService.performAction(element, action: kAXPressAction as CFString)
            return resultFromAXError(
                error,
                index: index,
                type: "select",
                route: "ax",
                id: summary.id,
                successMessage: "Selected \(summary.role) \(summary.name ?? summary.description ?? summary.id) through AXPress fallback."
            )
        }

        return ActionResult(
            index: index,
            type: "select",
            route: "ax",
            status: "unsupported",
            message: "Element \(summary.id) cannot be selected and does not expose AXPress.",
            id: summary.id,
            errorCode: "action_unsupported"
        )
    }

    private func performFocus(index: Int, element: AXUIElement, summary: AxElementSummary) -> ActionResult {
        guard accessibilityService.isAttributeSettable(element, attribute: kAXFocusedAttribute as CFString) else {
            return ActionResult(
                index: index,
                type: "focus",
                route: "ax",
                status: "unsupported",
                message: "Element \(summary.id) does not allow setting AXFocused.",
                id: summary.id,
                errorCode: "attribute_not_settable"
            )
        }

        let error = accessibilityService.setAttribute(element, attribute: kAXFocusedAttribute as CFString, value: kCFBooleanTrue)
        return resultFromAXError(
            error,
            index: index,
            type: "focus",
            route: "ax",
            id: summary.id,
            successMessage: "Focused \(summary.role) \(summary.name ?? summary.description ?? summary.id)."
        )
    }

    private func performSetValue(index: Int, element: AXUIElement, summary: AxElementSummary, text: String, replace: Bool) -> ActionResult {
        let type = replace ? "set_value" : "append_text"
        guard !text.isEmpty else {
            return ActionResult(
                index: index,
                type: type,
                route: "ax",
                status: "invalid",
                message: "Text payload is required.",
                id: summary.id,
                errorCode: "missing_text"
            )
        }

        if accessibilityService.isAttributeSettable(element, attribute: kAXValueAttribute as CFString) {
            let nextValue: String
            if replace {
                nextValue = text
            } else {
                let current = accessibilityService.stringValue(element, attribute: kAXValueAttribute as CFString) ?? ""
                nextValue = current + text
            }

            let error = accessibilityService.setAttribute(element, attribute: kAXValueAttribute as CFString, value: nextValue as CFString)
            let result = resultFromAXError(
                error,
                index: index,
                type: type,
                route: "ax",
                id: summary.id,
                successMessage: replace
                    ? "Updated value for \(summary.role) \(summary.name ?? summary.description ?? summary.id)."
                    : "Appended text to \(summary.role) \(summary.name ?? summary.description ?? summary.id)."
            )

            if result.status == "ok" || result.status == "stale" || result.status == "blocked" || result.status == "invalid" {
                return result
            }
        }

        return performKeyboardTextFallback(index: index, element: element, summary: summary, text: text, replace: replace)
    }

    private func performKeyboardTextFallback(
        index: Int,
        element: AXUIElement,
        summary: AxElementSummary,
        text: String,
        replace: Bool
    ) -> ActionResult {
        guard prepareElementForKeyboardInput(element: element, summary: summary) else {
            return ActionResult(
                index: index,
                type: replace ? "set_value" : "append_text",
                route: "keyboard_fallback",
                status: "unsupported",
                message: "Element \(summary.id) is not focusable enough for keyboard fallback.",
                id: summary.id,
                errorCode: "focus_unavailable"
            )
        }

        do {
            if replace {
                try accessibilityService.postKeySequence(keys: ["cmd", "a"], text: nil)
                try accessibilityService.postKeySequence(keys: ["delete"], text: nil)
            }
            try accessibilityService.postKeySequence(keys: [], text: text)
            return ActionResult(
                index: index,
                type: replace ? "set_value" : "append_text",
                route: "keyboard_fallback",
                status: "ok",
                message: replace
                    ? "Focused \(summary.id) and replaced its contents with synthesized keyboard input."
                    : "Focused \(summary.id) and appended text with synthesized keyboard input.",
                id: summary.id,
                errorCode: nil
            )
        } catch {
            return ActionResult(
                index: index,
                type: replace ? "set_value" : "append_text",
                route: "keyboard_fallback",
                status: "error",
                message: "Keyboard fallback failed: \(error.localizedDescription).",
                id: summary.id,
                errorCode: "cg_event_failed"
            )
        }
    }

    private func prepareElementForKeyboardInput(element: AXUIElement, summary: AxElementSummary) -> Bool {
        if summary.focused {
            return true
        }

        if accessibilityService.isAttributeSettable(element, attribute: kAXFocusedAttribute as CFString) {
            let focusError = accessibilityService.setAttribute(element, attribute: kAXFocusedAttribute as CFString, value: kCFBooleanTrue)
            if focusError == .success {
                return true
            }
        }

        if summary.actions.contains(kAXPressAction as String) {
            let pressError = accessibilityService.performAction(element, action: kAXPressAction as CFString)
            if pressError == .success {
                return true
            }
        }

        return false
    }

    private func clearTargetContents(index: Int, target: TargetedElement, settleMilliseconds: Double) -> ActionResult {
        if accessibilityService.isAttributeSettable(target.element, attribute: kAXValueAttribute as CFString) {
            let error = accessibilityService.setAttribute(target.element, attribute: kAXValueAttribute as CFString, value: "" as CFString)
            let result = resultFromAXError(
                error,
                index: index,
                type: "clear_focused_text",
                route: "text_pipeline",
                id: target.summary.id,
                successMessage: "Cleared the target text value through AX."
            )
            if result.status == "ok" {
                wait(milliseconds: settleMilliseconds)
                return result
            }
        }

        guard prepareElementForKeyboardInput(element: target.element, summary: target.summary) else {
            return ActionResult(
                index: index,
                type: "clear_focused_text",
                route: "text_pipeline",
                status: "unsupported",
                message: "The current target is not focusable enough for keyboard-based clearing.",
                id: target.summary.id,
                errorCode: "focus_unavailable"
            )
        }

        do {
            try accessibilityService.postKeySequence(keys: ["cmd", "a"], text: nil)
            try accessibilityService.postKeySequence(keys: ["delete"], text: nil)
            wait(milliseconds: settleMilliseconds)
            return ActionResult(
                index: index,
                type: "clear_focused_text",
                route: "text_pipeline",
                status: "ok",
                message: "Focused the target and cleared its current draft via keyboard selection + delete.",
                id: target.summary.id,
                errorCode: nil
            )
        } catch {
            return ActionResult(
                index: index,
                type: "clear_focused_text",
                route: "text_pipeline",
                status: "error",
                message: "Failed to clear the current draft: \(error.localizedDescription).",
                id: target.summary.id,
                errorCode: "cg_event_failed"
            )
        }
    }

    private func performScroll(
        index: Int,
        action: ComputerAction,
        scene: SceneSnapshot,
        storedObservation: StoredObservation?
    ) -> ActionResult {
        guard accessibilityService.accessibilityTrusted() else {
            return ActionResult(
                index: index,
                type: "scroll",
                route: "scroll",
                status: "blocked",
                message: "Accessibility permission is required for scroll actions.",
                id: action.id,
                errorCode: "permission_denied"
            )
        }

        var fallbackPoint = pointFromCoordinates(action: action, storedObservation: storedObservation)
        var resolvedElement: ResolvedElement?

        if let elementId = action.id {
            resolvedElement = resolveElement(
                requestedId: elementId,
                scene: scene,
                storedObservation: storedObservation
            )

            if resolvedElement == nil {
                if fallbackPoint == nil {
                    return ActionResult(
                        index: index,
                        type: "scroll",
                        route: "scroll",
                        status: "stale",
                        message: "Element id \(elementId) is not available in the current AX snapshot.",
                        id: elementId,
                        errorCode: "stale_id"
                    )
                }
            }

            if let resolvedElement {
                fallbackPoint = fallbackPoint ?? centerPoint(from: resolvedElement.summary.bbox)

                let actionName = "AXScrollToVisible"
                if resolvedElement.summary.actions.contains(actionName) {
                    let error = accessibilityService.performAction(resolvedElement.element, action: actionName as CFString)
                    let result = withResolutionContext(
                        resultFromAXError(
                        error,
                        index: index,
                        type: "scroll",
                        route: "ax",
                        id: resolvedElement.summary.id,
                        successMessage: "Requested scroll-to-visible for \(resolvedElement.summary.role) \(resolvedElement.summary.name ?? resolvedElement.summary.description ?? resolvedElement.summary.id)."
                        ),
                        resolution: resolvedElement
                    )
                    if result.status == "ok" {
                        return result
                    }
                }
            }
        }

        let point = fallbackPoint ?? centerPoint(from: scene.target?.windowFrame) ?? CGPoint(x: 400, y: 300)
        let deltas = scrollDeltas(direction: action.direction, amount: action.amount)
        guard deltas.deltaX != 0 || deltas.deltaY != 0 else {
            return ActionResult(
                index: index,
                type: "scroll",
                route: "scroll_cg_event",
                status: "invalid",
                message: "Scroll direction must be one of up, down, left, or right.",
                id: resolvedElement?.summary.id ?? action.id,
                errorCode: "invalid_direction"
            )
        }

        if accessibilityService.postScroll(at: point, deltaX: deltas.deltaX, deltaY: deltas.deltaY) {
            return withResolutionContext(
                ActionResult(
                index: index,
                type: "scroll",
                route: "scroll_cg_event",
                status: "ok",
                message: "Posted a \(action.direction?.lowercased() ?? "down") scroll gesture at (\(Int(point.x)), \(Int(point.y))).",
                id: resolvedElement?.summary.id ?? action.id,
                errorCode: nil
                ),
                resolution: resolvedElement
            )
        }

        return withResolutionContext(
            ActionResult(
            index: index,
            type: "scroll",
            route: "scroll_cg_event",
            status: "error",
            message: "Failed to dispatch a CGEvent scroll gesture.",
            id: resolvedElement?.summary.id ?? action.id,
            errorCode: "cg_event_failed"
            ),
            resolution: resolvedElement
        )
    }

    private func performScrollToBottom(
        index: Int,
        action: ComputerAction,
        scene: SceneSnapshot,
        storedObservation: StoredObservation?
    ) -> ActionResult {
        guard accessibilityService.accessibilityTrusted() else {
            return ActionResult(
                index: index,
                type: "scroll_to_bottom",
                route: "scroll",
                status: "blocked",
                message: "Accessibility permission is required for high-level scroll actions.",
                id: action.id,
                errorCode: "permission_denied"
            )
        }

        let anchorPoint = scrollAnchorPoint(action: action, scene: scene, storedObservation: storedObservation)
        let settleMilliseconds = max(80, action.ms ?? 140)
        let maxSteps = max(2, min(16, Int(action.retryCount ?? 7) + 1))
        let deltas = scrollDeltas(direction: action.direction ?? "down", amount: action.amount ?? 6)
        guard deltas.deltaX != 0 || deltas.deltaY != 0 else {
            return ActionResult(
                index: index,
                type: "scroll_to_bottom",
                route: "scroll",
                status: "invalid",
                message: "scroll_to_bottom requires a usable scroll direction.",
                id: action.id,
                errorCode: "invalid_direction"
            )
        }

        var currentScene = scene
        var previousDigest = sceneDigest(scene)
        var changedSteps = 0
        var stableCount = 0

        for _ in 1...maxSteps {
            guard accessibilityService.postScroll(at: anchorPoint, deltaX: deltas.deltaX, deltaY: deltas.deltaY) else {
                return ActionResult(
                    index: index,
                    type: "scroll_to_bottom",
                    route: "scroll_cg_event",
                    status: "error",
                    message: "Failed to dispatch a scroll gesture while trying to reach the bottom.",
                    id: action.id,
                    errorCode: "cg_event_failed"
                )
            }

            wait(milliseconds: settleMilliseconds)
            currentScene = refreshedScene(from: currentScene)
            let digest = sceneDigest(currentScene)
            if digest == previousDigest {
                stableCount += 1
                if stableCount >= 2 {
                    return ActionResult(
                        index: index,
                        type: "scroll_to_bottom",
                        route: "scroll_cg_event",
                        status: "ok",
                        message: changedSteps > 0
                            ? "Scrolled toward the bottom until the visible scene stopped changing."
                            : "The scene was already stable at the requested scroll anchor, which usually means the view is already at the bottom.",
                        id: action.id,
                        errorCode: nil
                    )
                }
            } else {
                changedSteps += 1
                stableCount = 0
                previousDigest = digest
            }
        }

        return ActionResult(
            index: index,
            type: "scroll_to_bottom",
            route: "scroll_cg_event",
            status: changedSteps > 0 ? "ok" : "retryable",
            message: changedSteps > 0
                ? "Scrolled downward for \(maxSteps) step(s); the view moved, but the bottom could not be conclusively verified."
                : "Repeated scroll gestures did not produce a visible scene change, so the helper could not verify movement.",
            id: action.id,
            errorCode: changedSteps > 0 ? nil : "scroll_unverified"
        )
    }

    private func performScrollUntilTextVisible(
        index: Int,
        action: ComputerAction,
        scene: SceneSnapshot,
        storedObservation: StoredObservation?
    ) -> ActionResult {
        guard accessibilityService.accessibilityTrusted() else {
            return ActionResult(
                index: index,
                type: "scroll_until_text_visible",
                route: "scroll",
                status: "blocked",
                message: "Accessibility permission is required for OCR-guided scroll actions.",
                id: action.id,
                errorCode: "permission_denied"
            )
        }

        guard let query = action.text ?? action.value, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ActionResult(
                index: index,
                type: "scroll_until_text_visible",
                route: "scroll",
                status: "invalid",
                message: "scroll_until_text_visible requires a non-empty text query.",
                id: action.id,
                errorCode: "missing_text"
            )
        }

        let settleMilliseconds = max(80, action.ms ?? 140)
        let maxSteps = max(1, min(16, Int(action.retryCount ?? 7) + 1))
        let deltas = scrollDeltas(direction: action.direction ?? "down", amount: action.amount ?? 5)
        guard deltas.deltaX != 0 || deltas.deltaY != 0 else {
            return ActionResult(
                index: index,
                type: "scroll_until_text_visible",
                route: "scroll",
                status: "invalid",
                message: "scroll_until_text_visible requires a usable scroll direction.",
                id: action.id,
                errorCode: "invalid_direction"
            )
        }

        let anchorPoint = scrollAnchorPoint(action: action, scene: scene, storedObservation: storedObservation)
        var currentScene = scene

        for step in 0...maxSteps {
            if let match = ocrTextService.bestMatch(query: query, within: currentScene.target?.windowFrame) {
                return ActionResult(
                    index: index,
                    type: "scroll_until_text_visible",
                    route: "scroll_ocr",
                    status: "ok",
                    message: step == 0
                        ? "Text \"\(match.text)\" is already visible."
                        : "Scrolled until text \"\(match.text)\" became visible after \(step) scroll step(s).",
                    id: action.id,
                    errorCode: nil
                )
            }

            if step == maxSteps {
                break
            }

            guard accessibilityService.postScroll(at: anchorPoint, deltaX: deltas.deltaX, deltaY: deltas.deltaY) else {
                return ActionResult(
                    index: index,
                    type: "scroll_until_text_visible",
                    route: "scroll_cg_event",
                    status: "error",
                    message: "Failed to dispatch a scroll gesture while searching for the requested text.",
                    id: action.id,
                    errorCode: "cg_event_failed"
                )
            }

            wait(milliseconds: settleMilliseconds)
            currentScene = refreshedScene(from: currentScene)
        }

        return ActionResult(
            index: index,
            type: "scroll_until_text_visible",
            route: "scroll_ocr",
            status: "retryable",
            message: "Scrolled \(maxSteps) step(s) but still could not find text matching \"\(query)\".",
            id: action.id,
            errorCode: "text_not_found"
        )
    }

    private func translatedVisionPoint(x: Double, y: Double, storedObservation: StoredObservation?) -> CGPoint? {
        guard x.isFinite, y.isFinite else {
            return nil
        }

        if let screenshot = storedObservation?.screenshot,
           let frame = rect(from: screenshot.screenFrame) {
            let widthScale = screenshot.width > 0 ? frame.width / CGFloat(screenshot.width) : 1
            let heightScale = screenshot.height > 0 ? frame.height / CGFloat(screenshot.height) : 1
            return CGPoint(
                x: frame.origin.x + (CGFloat(x) * widthScale),
                y: frame.origin.y + (CGFloat(y) * heightScale)
            )
        }

        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    private func pointFromCoordinates(action: ComputerAction, storedObservation: StoredObservation?) -> CGPoint? {
        guard let x = action.x, let y = action.y else {
            return nil
        }
        return translatedVisionPoint(x: x, y: y, storedObservation: storedObservation)
    }

    private func scrollAnchorPoint(action: ComputerAction, scene: SceneSnapshot, storedObservation: StoredObservation?) -> CGPoint {
        if let point = pointFromCoordinates(action: action, storedObservation: storedObservation) {
            return point
        }
        if let elementId = action.id,
           let summary = scene.elements[elementId],
           let point = centerPoint(from: summary.bbox)
        {
            return point
        }
        return centerPoint(from: scene.target?.windowFrame) ?? CGPoint(x: 400, y: 300)
    }

    private func refreshedScene(from scene: SceneSnapshot, maxNodes: Int = 240) -> SceneSnapshot {
        accessibilityService.captureScene(
            targetNamed: scene.target?.bundleId ?? scene.target?.appName,
            windowNamed: scene.target?.windowTitle,
            maxNodes: maxNodes
        )
    }

    private func centerPoint(from raw: [Double]?) -> CGPoint? {
        guard let rect = rect(from: raw) else {
            return nil
        }
        return centerPoint(from: rect)
    }

    private func centerPoint(from rect: CGRect?) -> CGPoint? {
        guard let rect else {
            return nil
        }
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    private func rect(from raw: [Double]?) -> CGRect? {
        guard let raw, raw.count == 4 else {
            return nil
        }
        return CGRect(x: raw[0], y: raw[1], width: raw[2], height: raw[3])
    }

    private func scrollDeltas(direction: String?, amount: Double?) -> (deltaX: Int32, deltaY: Int32) {
        let steps = Int32(max(1, min(16, Int(amount ?? 3))))
        switch direction?.lowercased() ?? "down" {
        case "up":
            return (0, steps)
        case "down":
            return (0, -steps)
        case "left":
            return (steps, 0)
        case "right":
            return (-steps, 0)
        default:
            return (0, 0)
        }
    }

    private func resolveElement(
        requestedId: String,
        scene: SceneSnapshot,
        storedObservation: StoredObservation?
    ) -> ResolvedElement? {
        if let element = scene.nodesById[requestedId], let summary = scene.elements[requestedId] {
            return ResolvedElement(element: element, summary: summary, requestedId: requestedId, remappedFromId: nil)
        }

        guard let priorSummary = storedObservation?.elements?[requestedId] else {
            return nil
        }

        let currentFingerprints = fingerprintBuilder.fingerprints(tree: scene.tree, elements: scene.elements)
        let priorFingerprint = storedObservation?.elementFingerprints?[requestedId]

        let candidates = scene.elements.values
            .filter { $0.enabled || priorSummary.enabled == false || $0.focused || $0.role == priorSummary.role }
            .map { candidate -> (summary: AxElementSummary, score: Double) in
                (
                    candidate,
                    remapScore(
                        from: priorSummary,
                        priorFingerprint: priorFingerprint,
                        to: candidate,
                        candidateFingerprint: currentFingerprints[candidate.id]
                    )
                )
            }
            .filter { $0.score >= 55 }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.summary.id < rhs.summary.id
                }
                return lhs.score > rhs.score
            }

        guard let best = candidates.first else {
            return nil
        }

        if candidates.count > 1, (best.score - candidates[1].score) < 8 {
            return nil
        }

        guard let element = scene.nodesById[best.summary.id] else {
            return nil
        }

        return ResolvedElement(
            element: element,
            summary: best.summary,
            requestedId: requestedId,
            remappedFromId: requestedId
        )
    }

    private func remapScore(
        from previous: AxElementSummary,
        priorFingerprint: ElementFingerprint?,
        to candidate: AxElementSummary,
        candidateFingerprint: ElementFingerprint?
    ) -> Double {
        var score = 0.0

        if previous.role == candidate.role {
            score += 35
        } else if roleFamily(previous.role) == roleFamily(candidate.role) {
            score += 12
        } else {
            score -= 20
        }

        score += textSimilarity(previous.name, candidate.name) * 18
        score += textSimilarity(previous.description, candidate.description) * 22
        score += textSimilarity(previous.value, candidate.value) * 10
        score += pathSimilarity(previous.path, candidate.path) * 16
        score += bboxSimilarity(previous.bbox, candidate.bbox) * 18

        if previous.enabled == candidate.enabled {
            score += 3
        }
        if previous.focused == candidate.focused {
            score += 2
        }
        if previous.actions.contains(kAXPressAction as String) == candidate.actions.contains(kAXPressAction as String) {
            score += 4
        }
        score += fingerprintSimilarity(priorFingerprint, candidateFingerprint) * 34
        if let priorFingerprint,
           let candidateFingerprint,
           priorFingerprint.semanticHash == candidateFingerprint.semanticHash
        {
            score += 16
        }
        if let priorFingerprint,
           let candidateFingerprint,
           !priorFingerprint.actionSignature.isEmpty,
           priorFingerprint.actionSignature == candidateFingerprint.actionSignature
        {
            score += 6
        }

        return score
    }

    private func fingerprintSimilarity(_ lhs: ElementFingerprint?, _ rhs: ElementFingerprint?) -> Double {
        guard let lhs, let rhs else {
            return 0
        }

        var score = 0.0
        if lhs.role == rhs.role {
            score += 0.18
        } else if lhs.roleFamily == rhs.roleFamily {
            score += 0.08
        }
        if !lhs.normalizedName.isEmpty {
            score += tokenSimilarity(lhs.normalizedName, rhs.normalizedName) * 0.16
        }
        if !lhs.normalizedValue.isEmpty {
            score += tokenSimilarity(lhs.normalizedValue, rhs.normalizedValue) * 0.14
        }
        if !lhs.normalizedDescription.isEmpty {
            score += tokenSimilarity(lhs.normalizedDescription, rhs.normalizedDescription) * 0.12
        }
        score += tokenSetSimilarity(lhs.ancestorRoles, rhs.ancestorRoles) * 0.10
        score += tokenSetSimilarity(lhs.siblingLabelsBefore, rhs.siblingLabelsBefore) * 0.10
        score += tokenSetSimilarity(lhs.siblingLabelsAfter, rhs.siblingLabelsAfter) * 0.10
        score += tokenSetSimilarity(lhs.descendantText, rhs.descendantText) * 0.16
        if lhs.bboxBucket != nil, lhs.bboxBucket == rhs.bboxBucket {
            score += 0.04
        }
        return min(1.0, score)
    }

    private func roleFamily(_ role: String) -> String {
        switch role {
        case "AXButton", "AXMenuButton", "AXMenuItem", "AXLink", "AXTab", "AXDisclosureTriangle":
            return "pressable"
        case "AXTextField", "AXTextArea":
            return "text"
        case "AXScrollArea":
            return "scroll"
        default:
            return role
        }
    }

    private func enrichResult(
        _ result: ActionResult,
        before: SceneSnapshot,
        after: SceneSnapshot?,
        visualBefore: VisualVerificationSnapshot?,
        visualAfter: VisualVerificationSnapshot?
    ) -> ActionResult {
        let beforeDigest = sceneDigest(before)
        let afterDigest = after.map(sceneDigest)
        let sceneChanged = afterDigest != nil && afterDigest != beforeDigest
        let visualChanged = visualBefore?.digest != nil &&
            visualAfter?.digest != nil &&
            visualBefore?.digest != visualAfter?.digest
        var evidence: [String] = []
        var ocrEvidence: [String] = []

        switch result.status {
        case "ok":
            evidence.append("helper_status_ok")
        case "retryable":
            evidence.append("helper_status_retryable")
        case "stale":
            evidence.append("element_id_stale")
        case "blocked":
            evidence.append("blocked_before_dispatch")
        case "invalid":
            evidence.append("invalid_request")
        default:
            evidence.append("helper_status_\(result.status)")
        }

        if after == nil {
            evidence.append("no_post_action_observation")
        } else if sceneChanged {
            evidence.append("scene_digest_changed")
        } else {
            evidence.append("scene_digest_unchanged")
        }

        if after != nil, focusedElementId(before) != focusedElementId(after) {
            evidence.append("focused_element_changed")
        }
        if visualChanged {
            evidence.append("visual_digest_changed")
        } else if visualBefore != nil || visualAfter != nil {
            evidence.append("visual_digest_unchanged")
        }
        ocrEvidence.append(contentsOf: visualBefore?.ocrTexts.map { "before:\($0)" } ?? [])
        ocrEvidence.append(contentsOf: visualAfter?.ocrTexts.map { "after:\($0)" } ?? [])
        if !ocrEvidence.isEmpty {
            evidence.append("ocr_evidence_available")
        }

        let retryable = result.status == "retryable" || result.status == "stale"
        let verified = result.status == "ok"
        let confidence: Double
        if result.status == "ok" {
            if sceneChanged && visualChanged {
                confidence = 0.94
            } else if sceneChanged || visualChanged {
                confidence = 0.86
            } else if !ocrEvidence.isEmpty {
                confidence = 0.78
            } else {
                confidence = 0.64
            }
        } else if result.status == "retryable" {
            confidence = visualChanged || !ocrEvidence.isEmpty ? 0.42 : 0.32
        } else if result.status == "stale" {
            confidence = 0.24
        } else if result.status == "blocked" || result.status == "invalid" {
            confidence = 0.08
        } else {
            confidence = 0.18
        }

        return ActionResult(
            index: result.index,
            type: result.type,
            route: result.route,
            status: result.status,
            message: result.message,
            id: result.id,
            errorCode: result.errorCode,
            retryable: retryable,
            verification: ActionVerification(
                verified: verified,
                confidence: confidence,
                evidence: evidence,
                beforeDigest: beforeDigest,
                afterDigest: afterDigest,
                visualBeforeDigest: visualBefore?.digest,
                visualAfterDigest: visualAfter?.digest,
                ocrEvidence: ocrEvidence.isEmpty ? nil : ocrEvidence
            ),
            suggestedNextAction: suggestedNextAction(for: result)
        )
    }

    private func visualSnapshotIfUseful(action: ComputerAction, scene: SceneSnapshot) -> VisualVerificationSnapshot? {
        let queryTexts = visualQueryTexts(for: action)
        if queryTexts.isEmpty,
           !["scroll", "scroll_to_bottom", "scroll_until_text_visible", "vision_click", "vision_click_text", "vision_drag", "submit"].contains(action.type)
        {
            return nil
        }
        return visualVerifier.snapshot(scene: scene, queryTexts: queryTexts)
    }

    private func visualQueryTexts(for action: ComputerAction) -> [String] {
        switch action.type {
        case "replace_text", "paste_text", "append_text", "set_value", "compose_and_submit", "scroll_until_text_visible", "vision_click_text":
            return [action.text, action.value].compactMap { $0 }
        default:
            return []
        }
    }

    private func focusedElementId(_ scene: SceneSnapshot?) -> String? {
        scene?.elements.values.first(where: { $0.focused })?.id
    }

    private func suggestedNextAction(for result: ActionResult) -> String? {
        switch result.errorCode {
        case "stale_id":
            return "Run computer_observe again and retry with the latest element id."
        case "missing_screenshot":
            return "Run computer_observe with include_screenshot=true before using vision text actions."
        case "text_not_found":
            return "Use scroll_until_text_visible or re-observe with a screenshot before retrying."
        case "submission_unverified":
            return "Re-observe the composer and inspect whether the draft is still present."
        case "permission_denied":
            return "Grant the required macOS Accessibility or Screen Recording permission, then retry."
        case "coordinate_translation_failed":
            return "Use coordinates from the latest screenshot observation."
        case "verification_failed":
            return "Re-observe and retry with replace_text or paste_text after focusing the target."
        default:
            return result.status == "retryable" ? "Re-observe the target window and retry a smaller action." : nil
        }
    }

    private func textSimilarity(_ lhs: String?, _ rhs: String?) -> Double {
        let left = normalizedText(lhs)
        let right = normalizedText(rhs)

        if left.isEmpty || right.isEmpty {
            return 0
        }
        if left == right {
            return 1
        }
        if left.contains(right) || right.contains(left) {
            return 0.85
        }

        let leftTokens = Set(left.split(separator: " ").map(String.init))
        let rightTokens = Set(right.split(separator: " ").map(String.init))
        let union = leftTokens.union(rightTokens)
        guard !union.isEmpty else {
            return 0
        }
        let overlap = Double(leftTokens.intersection(rightTokens).count) / Double(union.count)
        return overlap
    }

    private func tokenSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = normalizedText(lhs)
        let right = normalizedText(rhs)
        guard !left.isEmpty, !right.isEmpty else {
            return 0
        }
        if left == right {
            return 1
        }
        if left.contains(right) || right.contains(left) {
            return 0.82
        }
        return tokenSetSimilarity(
            left.split(separator: " ").map(String.init),
            right.split(separator: " ").map(String.init)
        )
    }

    private func tokenSetSimilarity(_ lhs: [String], _ rhs: [String]) -> Double {
        let left = Set(lhs.map { normalizedText($0) }.filter { !$0.isEmpty })
        let right = Set(rhs.map { normalizedText($0) }.filter { !$0.isEmpty })
        let union = left.union(right)
        guard !union.isEmpty else {
            return 0
        }
        return Double(left.intersection(right).count) / Double(union.count)
    }

    private func normalizedText(_ value: String?) -> String {
        guard let value else {
            return ""
        }
        return value
            .lowercased()
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func pathSimilarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs {
            return 1
        }
        let leftParts = lhs.split(separator: ".").map(String.init)
        let rightParts = rhs.split(separator: ".").map(String.init)
        let commonSuffix = zip(leftParts.reversed(), rightParts.reversed()).prefix { $0 == $1 }.count
        let base = Double(commonSuffix) / Double(max(1, min(leftParts.count, rightParts.count)))
        return min(1, base * 1.4)
    }

    private func bboxSimilarity(_ lhs: [Double]?, _ rhs: [Double]?) -> Double {
        guard let lhsRect = rect(from: lhs), let rhsRect = rect(from: rhs) else {
            return 0
        }

        let centerDistance = hypot(lhsRect.midX - rhsRect.midX, lhsRect.midY - rhsRect.midY)
        let diagonal = max(1.0, hypot(lhsRect.width, lhsRect.height))
        let normalizedDistance = min(1.0, centerDistance / (diagonal * 3.0))

        let sizeDistance = abs(lhsRect.width - rhsRect.width) + abs(lhsRect.height - rhsRect.height)
        let sizeBase = max(1.0, lhsRect.width + lhsRect.height)
        let normalizedSize = min(1.0, sizeDistance / sizeBase)

        return max(0, 1.0 - (normalizedDistance * 0.65) - (normalizedSize * 0.35))
    }

    private func withResolutionContext(_ result: ActionResult, resolution: ResolvedElement?) -> ActionResult {
        guard let resolution, resolution.wasRemapped, let sourceId = resolution.remappedFromId else {
            return result
        }

        let prefix = "Remapped stale id \(sourceId) -> \(resolution.summary.id). "
        return ActionResult(
            index: result.index,
            type: result.type,
            route: result.route,
            status: result.status,
            message: prefix + result.message,
            id: resolution.summary.id,
            errorCode: result.errorCode
        )
    }

    private func resultFromAXError(
        _ error: AXError,
        index: Int,
        type: String,
        route: String,
        id: String?,
        successMessage: String
    ) -> ActionResult {
        switch error {
        case .success:
            return ActionResult(index: index, type: type, route: route, status: "ok", message: successMessage, id: id, errorCode: nil)
        case .cannotComplete:
            return ActionResult(index: index, type: type, route: route, status: "retryable", message: "The target app did not complete the AX request in time.", id: id, errorCode: "cannot_complete")
        case .invalidUIElement:
            return ActionResult(index: index, type: type, route: route, status: "stale", message: "The AX element is no longer valid.", id: id, errorCode: "stale_id")
        case .actionUnsupported:
            return ActionResult(index: index, type: type, route: route, status: "unsupported", message: "The target element does not support this AX action.", id: id, errorCode: "action_unsupported")
        case .attributeUnsupported:
            return ActionResult(index: index, type: type, route: route, status: "unsupported", message: "The target element does not support this AX attribute.", id: id, errorCode: "attribute_unsupported")
        case .apiDisabled:
            return ActionResult(index: index, type: type, route: route, status: "blocked", message: "Accessibility API is disabled for this helper process.", id: id, errorCode: "permission_denied")
        case .illegalArgument:
            return ActionResult(index: index, type: type, route: route, status: "invalid", message: "The AX request used an illegal argument.", id: id, errorCode: "illegal_argument")
        case .noValue:
            return ActionResult(index: index, type: type, route: route, status: "unsupported", message: "The target element does not currently expose a value for this request.", id: id, errorCode: "no_value")
        case .notImplemented:
            return ActionResult(index: index, type: type, route: route, status: "unsupported", message: "The target app does not fully implement this part of Accessibility.", id: id, errorCode: "not_implemented")
        default:
            return ActionResult(index: index, type: type, route: route, status: "error", message: "AX request failed with \(String(describing: error)).", id: id, errorCode: "ax_error")
        }
    }

    private func routeForAction(_ type: String) -> String {
        switch type {
        case "vision_click", "vision_click_text", "vision_drag":
            return "vision"
        case "key", "type", "keypress":
            return "keyboard"
        case "clear_focused_text", "paste_text", "replace_text", "submit", "compose_and_submit", "compose_and_send", "send_message":
            return "text_pipeline"
        case "scroll", "scroll_to_bottom", "scroll_until_text_visible":
            return "scroll"
        default:
            return "ax"
        }
    }

    private func resolveTextTarget(
        index: Int,
        action: ComputerAction,
        scene: SceneSnapshot,
        storedObservation: StoredObservation?,
        actionType: String
    ) -> TargetResolution {
        if let elementId = action.id {
            guard let resolved = resolveElement(
                requestedId: elementId,
                scene: scene,
                storedObservation: storedObservation
            ) else {
                return .failure(
                    ActionResult(
                        index: index,
                        type: actionType,
                        route: "text_pipeline",
                        status: "stale",
                        message: "Element id \(elementId) is not available in the current AX snapshot.",
                        id: elementId,
                        errorCode: "stale_id"
                    )
                )
            }

            if resolved.summary.enabled == false && actionType != "focus" {
                return .failure(
                    ActionResult(
                        index: index,
                        type: actionType,
                        route: "text_pipeline",
                        status: "blocked",
                        message: "Element \(resolved.summary.id) is disabled.",
                        id: resolved.summary.id,
                        errorCode: "not_enabled"
                    )
                )
            }

            return .success(TargetedElement(element: resolved.element, summary: resolved.summary, resolution: resolved))
        }

        if let element = accessibilityService.focusedElement(applicationElement: scene.target?.appElement) ?? accessibilityService.focusedElement() {
            let summary = accessibilityService.summaryForElement(element, fallbackPath: "runtime.focused")
            if summary.enabled == false {
                return .failure(
                    ActionResult(
                        index: index,
                        type: actionType,
                        route: "text_pipeline",
                        status: "blocked",
                        message: "The currently focused element is disabled.",
                        id: summary.id,
                        errorCode: "not_enabled"
                    )
                )
            }
            return .success(TargetedElement(element: element, summary: summary, resolution: nil))
        }

        return .failure(
            ActionResult(
                index: index,
                type: actionType,
                route: "text_pipeline",
                status: "invalid",
                message: "\(actionType) requires either an element id or a currently focused text-capable element.",
                id: nil,
                errorCode: "missing_target"
            )
        )
    }

    private func verifyTextCommitted(
        expected: String,
        replace: Bool,
        target: TargetedElement
    ) -> (status: String, message: String, errorCode: String?) {
        let currentElement = accessibilityService.focusedElement() ?? target.element
        let currentSummary = accessibilityService.summaryForElement(currentElement, fallbackPath: target.summary.path)
        let expectedNormalized = normalizedText(expected)
        let currentNormalized = normalizedText(currentSummary.value)
        let priorNormalized = normalizedText(target.summary.value)

        guard !currentNormalized.isEmpty else {
            return (
                "best_effort",
                replace
                    ? "Replaced text via clear + paste. The target app did not expose a verifiable post-input value, so this was accepted as best-effort."
                    : "Pasted text into the focused target. The target app did not expose a verifiable post-input value, so this was accepted as best-effort.",
                nil
            )
        }

        if replace {
            if currentNormalized == expectedNormalized || currentNormalized.contains(expectedNormalized) {
                return ("ok", "Replaced the focused text and verified the new value.", nil)
            }
        } else {
            if currentNormalized.contains(expectedNormalized) && currentNormalized != priorNormalized {
                return ("ok", "Pasted text and verified the updated focused value.", nil)
            }
        }

        if currentSummary.path != target.summary.path {
            return (
                "best_effort",
                "The focused element changed after text input, so the text interaction was accepted as best-effort.",
                nil
            )
        }

        return (
            "retryable",
            replace
                ? "replace_text ran, but the focused value did not update to the expected text."
                : "paste_text ran, but the focused value did not expose the pasted text yet.",
            "verification_failed"
        )
    }

    private func verificationSnapshot(targetHint: String?, windowHint: String?, currentScene: SceneSnapshot? = nil) -> VerificationSnapshot {
        let scene = currentScene ?? accessibilityService.captureScene(targetNamed: targetHint, windowNamed: windowHint, maxNodes: 200)
        let focusedElement = accessibilityService.focusedElement(applicationElement: scene.target?.appElement) ?? accessibilityService.focusedElement()
        let focusedSummary = focusedElement.map { accessibilityService.summaryForElement($0, fallbackPath: "runtime.focused") }
        return VerificationSnapshot(
            focused: focusedSummary,
            sceneDigest: sceneDigest(scene),
            elements: scene.elements
        )
    }

    private func submitAssessment(before: VerificationSnapshot, after: VerificationSnapshot, target: TargetedElement) -> SubmitAssessment {
        let draft = normalizedText(before.focused?.value ?? target.summary.value)
        let targetPath = target.summary.path
        let beforeFocusedPath = before.focused?.path
        let afterFocusedPath = after.focused?.path
        let afterFocusedValue = normalizedText(after.focused?.value)

        let beforeOutsideCount = countOccurrences(of: draft, in: before.elements, excludingPathPrefix: targetPath)
        let afterOutsideCount = countOccurrences(of: draft, in: after.elements, excludingPathPrefix: targetPath)
        let afterInsideCount = countOccurrences(of: draft, in: after.elements, includingPathPrefix: targetPath)
        let sentEchoDetected = !draft.isEmpty && afterOutsideCount > beforeOutsideCount
        let residualDraft = !draft.isEmpty && (afterInsideCount > 0 || (!afterFocusedValue.isEmpty && afterFocusedValue.contains(draft)))

        if sentEchoDetected {
            return SubmitAssessment(
                success: true,
                residualDraft: residualDraft,
                sentEchoDetected: true,
                message: "Observed the composed text appear outside the input region after submit."
            )
        }

        if !draft.isEmpty && afterFocusedValue.isEmpty && before.sceneDigest != after.sceneDigest {
            return SubmitAssessment(
                success: true,
                residualDraft: false,
                sentEchoDetected: false,
                message: "The focused draft cleared and the surrounding UI changed after submit."
            )
        }

        if beforeFocusedPath != afterFocusedPath && before.sceneDigest != after.sceneDigest && !residualDraft {
            return SubmitAssessment(
                success: true,
                residualDraft: false,
                sentEchoDetected: false,
                message: "Focus moved away from the composer and the scene changed after submit."
            )
        }

        if before.sceneDigest != after.sceneDigest && !residualDraft {
            return SubmitAssessment(
                success: true,
                residualDraft: false,
                sentEchoDetected: false,
                message: "The scene changed after submit and no residual draft was detected."
            )
        }

        if residualDraft {
            return SubmitAssessment(
                success: false,
                residualDraft: true,
                sentEchoDetected: false,
                message: "The composed text still appears to be present in the input region."
            )
        }

        return SubmitAssessment(
            success: false,
            residualDraft: false,
            sentEchoDetected: false,
            message: "No verifiable post-submit scene transition was detected."
        )
    }

    private func normalizedSubmitStrategy(_ strategy: String?) -> String {
        let normalized = (strategy ?? "auto")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? "auto" : normalized
    }

    private func submitKeys(for action: ComputerAction, strategy: String) -> [String] {
        if let explicit = action.keys, !explicit.isEmpty {
            return explicit
        }

        switch strategy {
        case "auto", "enter":
            return ["enter"]
        case "cmd_enter", "command_enter":
            return ["cmd", "enter"]
        case "shift_enter":
            return ["shift", "enter"]
        case "option_enter", "alt_enter":
            return ["option", "enter"]
        case "ctrl_enter", "control_enter":
            return ["ctrl", "enter"]
        default:
            return []
        }
    }

    private func submitAllowsButtonFallback(action: ComputerAction, strategy: String) -> Bool {
        if action.keys != nil {
            return false
        }
        switch strategy {
        case "auto", "button", "click_button", "default_button":
            return true
        default:
            return false
        }
    }

    private func submitButtonOnly(strategy: String) -> Bool {
        switch strategy {
        case "button", "click_button", "default_button":
            return true
        default:
            return false
        }
    }

    private func attemptSubmitButtonFallback(
        index: Int,
        target: TargetedElement,
        targetHint: String?,
        windowHint: String?,
        baseline: VerificationSnapshot,
        settleMilliseconds: Double
    ) -> ActionResult? {
        let scene = accessibilityService.captureScene(targetNamed: targetHint, windowNamed: windowHint, maxNodes: 240)
        guard let candidate = likelySubmitButton(in: scene, near: target.summary),
              let element = scene.nodesById[candidate.id]
        else {
            return nil
        }

        let press = performPress(index: index, element: element, summary: candidate)
        guard press.status == "ok" else {
            return press
        }

        wait(milliseconds: settleMilliseconds)
        let post = verificationSnapshot(targetHint: targetHint, windowHint: windowHint)
        let assessment = submitAssessment(before: baseline, after: post, target: target)
        if assessment.success {
            return ActionResult(
                index: index,
                type: "submit",
                route: "text_pipeline",
                status: "ok",
                message: "Submitted by pressing likely send button \(candidate.name ?? candidate.description ?? candidate.id). \(assessment.message)",
                id: candidate.id,
                errorCode: nil
            )
        }

        if assessment.residualDraft {
            return nil
        }

        return ActionResult(
            index: index,
            type: "submit",
            route: "text_pipeline",
            status: "retryable",
            message: "Pressed likely send button \(candidate.name ?? candidate.description ?? candidate.id), but no verifiable committed-send transition followed.",
            id: candidate.id,
            errorCode: "submission_unverified"
        )
    }

    private func likelySubmitButton(in scene: SceneSnapshot, near target: AxElementSummary) -> AxElementSummary? {
        let candidates = scene.elements.values
            .filter { candidate in
                candidate.enabled &&
                buttonLikeRole(candidate.role) &&
                candidate.actions.contains(kAXPressAction as String)
            }
            .map { candidate -> (summary: AxElementSummary, score: Double) in
                (candidate, submitButtonScore(candidate, near: target))
            }
            .filter { $0.score >= 48 }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.summary.id < rhs.summary.id
                }
                return lhs.score > rhs.score
            }

        return candidates.first?.summary
    }

    private func submitButtonScore(_ candidate: AxElementSummary, near target: AxElementSummary) -> Double {
        let label = normalizedText([candidate.name, candidate.description, candidate.value].compactMap { $0 }.joined(separator: " "))
        var score = 0.0

        let weightedKeywords: [(String, Double)] = [
            ("send", 100), ("submit", 92), ("reply", 86), ("post", 82), ("publish", 80),
            ("发送", 100), ("提交", 92), ("回复", 86), ("发布", 82), ("完成", 52),
            ("go", 40), ("run", 38), ("search", 34), ("继续", 32), ("确定", 28)
        ]

        for (keyword, weight) in weightedKeywords where !keyword.isEmpty && label.contains(normalizedText(keyword)) {
            score = max(score, weight)
        }

        if let targetRect = rect(from: target.bbox), let candidateRect = rect(from: candidate.bbox) {
            let dx = candidateRect.midX - targetRect.midX
            let dy = candidateRect.midY - targetRect.midY
            let distance = hypot(dx, dy)
            score += max(0, 28 - (distance / 28))

            if candidateRect.minY >= targetRect.minY - 24 {
                score += 8
            }
            if candidateRect.midX >= targetRect.midX {
                score += 6
            }
            if candidateRect.maxY <= targetRect.maxY + 180 {
                score += 4
            }
        }

        if label.isEmpty {
            score -= 12
        }

        return score
    }

    private func buttonLikeRole(_ role: String) -> Bool {
        switch role {
        case "AXButton", "AXMenuButton", "AXLink", "AXDisclosureTriangle":
            return true
        default:
            return false
        }
    }

    private func countOccurrences(
        of normalizedNeedle: String,
        in elements: [String: AxElementSummary],
        excludingPathPrefix: String? = nil,
        includingPathPrefix: String? = nil
    ) -> Int {
        guard !normalizedNeedle.isEmpty else {
            return 0
        }

        return elements.values.reduce(into: 0) { count, element in
            if let includingPathPrefix, !element.path.hasPrefix(includingPathPrefix) {
                return
            }
            if let excludingPathPrefix, element.path.hasPrefix(excludingPathPrefix) {
                return
            }

            let haystacks = [
                normalizedText(element.name),
                normalizedText(element.value),
                normalizedText(element.description)
            ]
            if haystacks.contains(where: { !$0.isEmpty && $0.contains(normalizedNeedle) }) {
                count += 1
            }
        }
    }

    private func wait(milliseconds: Double) {
        let safe = max(0, milliseconds)
        guard safe > 0 else {
            return
        }
        Thread.sleep(forTimeInterval: safe / 1000.0)
    }

    private func derivedAction(
        from action: ComputerAction,
        type: String,
        text: String? = nil,
        ms: Double? = nil,
        retryCount: Double? = nil
    ) -> ComputerAction {
        ComputerAction(
            type: type,
            id: action.id,
            text: text ?? action.text,
            value: action.value,
            keys: action.keys,
            strategy: action.strategy,
            direction: action.direction,
            amount: action.amount,
            ms: ms ?? action.ms,
            retryCount: retryCount ?? action.retryCount,
            mark: action.mark,
            x: action.x,
            y: action.y,
            x2: action.x2,
            y2: action.y2,
            reason: action.reason
        )
    }

    private func remapResultType(
        _ result: ActionResult,
        to type: String,
        route: String,
        prefix: String
    ) -> ActionResult {
        let message = result.message.isEmpty ? prefix : "\(prefix) \(result.message)"
        return ActionResult(
            index: result.index,
            type: type,
            route: route,
            status: result.status,
            message: message,
            id: result.id,
            errorCode: result.errorCode
        )
    }

    private func sceneDigest(_ scene: SceneSnapshot) -> String {
        SceneDigest.compute(scene)
    }

    private func stableDigest(_ input: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16, uppercase: false)
    }
}
