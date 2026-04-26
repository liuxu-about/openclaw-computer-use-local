import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

private let interactiveRoles: Set<String> = [
    "AXButton",
    "AXCheckBox",
    "AXComboBox",
    "AXDisclosureTriangle",
    "AXLink",
    "AXMenuButton",
    "AXMenuItem",
    "AXPopUpButton",
    "AXRadioButton",
    "AXRow",
    "AXSlider",
    "AXStaticText",
    "AXTab",
    "AXTextArea",
    "AXTextField",
]

private let structuralRoles: Set<String> = [
    "AXApplication",
    "AXGroup",
    "AXLayoutArea",
    "AXLayoutItem",
    "AXScrollArea",
    "AXSplitGroup",
    "AXUnknown",
    "AXWindow",
]

private let textRoles: Set<String> = [
    "AXStaticText",
    "AXTextArea",
    "AXTextField",
]

struct TargetContext: @unchecked Sendable {
    let appName: String
    let bundleId: String
    let pid: pid_t
    let appElement: AXUIElement
    let windowElement: AXUIElement?
    let windowTitle: String?
    let windowFrame: CGRect?
}

struct SceneSnapshot: @unchecked Sendable {
    let target: TargetContext?
    let tree: [AxNode]
    let elements: [String: AxElementSummary]
    let nodesById: [String: AXUIElement]
    let totalNodes: Int
    let interactiveCount: Int
}

private struct NodeBuildResult: @unchecked Sendable {
    let node: AxNode
    let elements: [String: AxElementSummary]
    let nodesById: [String: AXUIElement]
    let totalNodes: Int
    let interactiveCount: Int
}

enum EventSynthesisError: LocalizedError {
    case emptyKeyAction
    case emptyText
    case unsupportedKey(String)
    case eventSourceUnavailable
    case eventCreationFailed(String)
    case pasteboardWriteFailed

    var errorDescription: String? {
        switch self {
        case .emptyKeyAction:
            return "A keyboard action requires either keys or text."
        case .emptyText:
            return "Text typing requires a non-empty string."
        case .unsupportedKey(let token):
            return "Unsupported key token: \(token)."
        case .eventSourceUnavailable:
            return "Failed to create a CGEvent source."
        case .eventCreationFailed(let detail):
            return "Failed to synthesize a CGEvent: \(detail)."
        case .pasteboardWriteFailed:
            return "Failed to write text to the system pasteboard."
        }
    }
}

final class AccessibilityService: @unchecked Sendable {
    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private let eventLogger = EventLogger.shared
    private let attributeMessagingTimeout = AccessibilityService.readFloatEnv("COMPUTER_USE_AX_ATTRIBUTE_TIMEOUT_S", default: 0.35)
    private let resolveMessagingTimeout = AccessibilityService.readFloatEnv("COMPUTER_USE_AX_RESOLVE_TIMEOUT_S", default: 0.75)
    private let actionMessagingTimeout = AccessibilityService.readFloatEnv("COMPUTER_USE_AX_ACTION_TIMEOUT_S", default: 1.2)

    func accessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func screenRecordingTrusted() -> Bool {
        if #available(macOS 11.0, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    func frontmostAppInfo() -> (name: String, bundleId: String) {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ("Unknown", "unknown")
        }
        return (app.localizedName ?? "Unknown", app.bundleIdentifier ?? "unknown")
    }

    func frontmostWindowInfo() -> (name: String, bundleId: String, windowTitle: String?) {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ("Unknown", "unknown", nil)
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        applyMessagingTimeout(appElement, timeout: resolveMessagingTimeout)
        let window = elementValue(appElement, attribute: kAXFocusedWindowAttribute as CFString)
        let title = window.flatMap { stringValue($0, attribute: kAXTitleAttribute as CFString) }
        return (app.localizedName ?? "Unknown", app.bundleIdentifier ?? "unknown", title)
    }

    func resolveTarget(named query: String?, windowNamed windowQuery: String? = nil) -> TargetContext? {
        let startedAt = Date()
        eventLogger.log("helper_ax_stage_started", payload: [
            "stage": "resolve_target",
            "target_app": query as Any,
            "target_window": windowQuery as Any,
        ])

        let app: NSRunningApplication?
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lowered = query.lowercased()
            let candidates = NSWorkspace.shared.runningApplications
                .compactMap { running -> (app: NSRunningApplication, score: Int, length: Int)? in
                    let bundle = running.bundleIdentifier?.lowercased() ?? ""
                    let name = running.localizedName?.lowercased() ?? ""
                    guard !bundle.isEmpty || !name.isEmpty else {
                        return nil
                    }

                    var score = 0
                    if bundle == lowered { score = max(score, 120) }
                    if name == lowered { score = max(score, 110) }
                    if bundle.hasPrefix(lowered) { score = max(score, 90) }
                    if name.hasPrefix(lowered) { score = max(score, 80) }
                    if bundle.contains(lowered) { score = max(score, 70) }
                    if name.contains(lowered) { score = max(score, 60) }
                    if score == 0 {
                        return nil
                    }

                    if bundle.contains("helper"), !lowered.contains("helper") {
                        score -= 25
                    }
                    if name.contains("helper"), !lowered.contains("helper") {
                        score -= 25
                    }

                    let length = bundle.isEmpty ? name.count : bundle.count
                    return (running, score, length)
                }
                .sorted { lhs, rhs in
                    if lhs.score == rhs.score {
                        return lhs.length < rhs.length
                    }
                    return lhs.score > rhs.score
                }
            app = candidates.first?.app
        } else {
            app = NSWorkspace.shared.frontmostApplication
        }

        guard let app else {
            eventLogger.log("helper_ax_stage_failed", payload: [
                "stage": "resolve_target",
                "target_app": query as Any,
                "target_window": windowQuery as Any,
                "duration_ms": elapsedMs(since: startedAt),
                "reason": "no_matching_running_application",
            ])
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        applyMessagingTimeout(appElement, timeout: resolveMessagingTimeout)
        let focusedWindow = elementValue(appElement, attribute: kAXFocusedWindowAttribute as CFString)
        let windowElement = bestWindowElement(appElement: appElement, query: windowQuery, focusedWindow: focusedWindow) ?? focusedWindow
        let windowTitle = windowElement.flatMap { stringValue($0, attribute: kAXTitleAttribute as CFString) }
        let windowFrame = windowElement.flatMap(frameValue)
        let windowSource: String = {
            guard let windowElement else {
                return "none"
            }
            if let focusedWindow, CFEqual(windowElement, focusedWindow) {
                return "focused_window"
            }
            return "ranked_window"
        }()

        eventLogger.log("helper_ax_stage_succeeded", payload: [
            "stage": "resolve_target",
            "target_app": query as Any,
            "target_window": windowQuery as Any,
            "duration_ms": elapsedMs(since: startedAt),
            "resolved_app": app.localizedName ?? "Unknown",
            "resolved_bundle_id": app.bundleIdentifier ?? "unknown",
            "resolved_window": windowTitle as Any,
            "window_source": windowSource,
        ])

        return TargetContext(
            appName: app.localizedName ?? "Unknown",
            bundleId: app.bundleIdentifier ?? "unknown",
            pid: app.processIdentifier,
            appElement: appElement,
            windowElement: windowElement,
            windowTitle: windowTitle,
            windowFrame: windowFrame
        )
    }

    func currentScreenInfo() -> ScreenInfo {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? .zero
        let scale = screen?.backingScaleFactor ?? 1.0
        let displayId = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "0"
        return ScreenInfo(width: frame.width, height: frame.height, scale: scale, displayId: displayId)
    }

    func captureScene(targetNamed query: String?, windowNamed windowQuery: String? = nil, maxNodes: Int = 250) -> SceneSnapshot {
        let startedAt = Date()
        eventLogger.log("helper_ax_stage_started", payload: [
            "stage": "capture_scene",
            "target_app": query as Any,
            "target_window": windowQuery as Any,
            "max_nodes": maxNodes,
        ])

        let target = resolveTarget(named: query, windowNamed: windowQuery)
        guard let target else {
            eventLogger.log("helper_ax_stage_failed", payload: [
                "stage": "capture_scene",
                "target_app": query as Any,
                "target_window": windowQuery as Any,
                "max_nodes": maxNodes,
                "duration_ms": elapsedMs(since: startedAt),
                "reason": "resolve_target_returned_nil",
            ])
            return SceneSnapshot(target: nil, tree: [], elements: [:], nodesById: [:], totalNodes: 0, interactiveCount: 0)
        }

        var elements: [String: AxElementSummary] = [:]
        var nodesById: [String: AXUIElement] = [:]
        var totalNodes = 0
        var interactiveCount = 0
        var remaining = max(16, maxNodes)

        var children: [AxNode] = []
        if let windowElement = target.windowElement {
            eventLogger.log("helper_ax_stage_started", payload: [
                "stage": "build_window_tree",
                "target_app": target.appName,
                "target_bundle_id": target.bundleId,
                "target_window": target.windowTitle as Any,
                "max_nodes": maxNodes,
            ])
            if let windowNode = buildNode(
               element: windowElement,
               target: target,
               path: "app_1.window_1",
               viewport: target.windowFrame,
               remaining: &remaining,
               depth: 0
            ) {
                children.append(windowNode.node)
                elements.merge(windowNode.elements) { current, _ in current }
                nodesById.merge(windowNode.nodesById) { current, _ in current }
                totalNodes += windowNode.totalNodes
                interactiveCount += windowNode.interactiveCount
                eventLogger.log("helper_ax_stage_succeeded", payload: [
                    "stage": "build_window_tree",
                    "target_app": target.appName,
                    "target_bundle_id": target.bundleId,
                    "target_window": target.windowTitle as Any,
                    "window_title": stringValue(windowElement, attribute: kAXTitleAttribute as CFString) as Any,
                    "duration_ms": elapsedMs(since: startedAt),
                    "element_count": elements.count,
                    "total_nodes": totalNodes,
                    "interactive_count": interactiveCount,
                ])
            } else {
                let fallbackWindow = simpleNode(
                    element: windowElement,
                    role: stringValue(windowElement, attribute: kAXRoleAttribute as CFString) ?? "AXWindow",
                    path: "app_1.window_1"
                )
                children.append(fallbackWindow)
                totalNodes += 1
                eventLogger.log("helper_ax_stage_failed", payload: [
                    "stage": "build_window_tree",
                    "target_app": target.appName,
                    "target_bundle_id": target.bundleId,
                    "target_window": target.windowTitle as Any,
                    "duration_ms": elapsedMs(since: startedAt),
                    "reason": "build_node_returned_nil_using_simple_fallback",
                ])
            }
        }

        let appNode = AxNode(
            id: nil,
            role: "AXApplication",
            name: compactText(target.appName),
            value: nil,
            description: compactText(target.bundleId),
            enabled: true,
            focused: true,
            bbox: nil,
            actions: [],
            path: "app_1",
            children: children
        )

        totalNodes += 1

        eventLogger.log("helper_ax_stage_succeeded", payload: [
            "stage": "capture_scene",
            "target_app": target.appName,
            "target_bundle_id": target.bundleId,
            "target_window": target.windowTitle as Any,
            "duration_ms": elapsedMs(since: startedAt),
            "element_count": elements.count,
            "total_nodes": totalNodes,
            "interactive_count": interactiveCount,
        ])

        return SceneSnapshot(
            target: target,
            tree: [appNode],
            elements: elements,
            nodesById: nodesById,
            totalNodes: totalNodes,
            interactiveCount: interactiveCount
        )
    }

    func performAction(_ element: AXUIElement, action: CFString) -> AXError {
        applyMessagingTimeout(element, timeout: actionMessagingTimeout)
        return AXUIElementPerformAction(element, action)
    }

    func setAttribute(_ element: AXUIElement, attribute: CFString, value: CFTypeRef) -> AXError {
        applyMessagingTimeout(element, timeout: actionMessagingTimeout)
        return AXUIElementSetAttributeValue(element, attribute, value)
    }

    func isAttributeSettable(_ element: AXUIElement, attribute: CFString) -> Bool {
        applyMessagingTimeout(element)
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, attribute, &settable)
        return error == .success && settable.boolValue
    }

    func stringValue(_ element: AXUIElement, attribute: CFString) -> String? {
        if let string = attributeValue(element, attribute: attribute) as? String {
            return string
        }
        if let number = attributeValue(element, attribute: attribute) as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    func boolValue(_ element: AXUIElement, attribute: CFString) -> Bool? {
        if let bool = attributeValue(element, attribute: attribute) as? Bool {
            return bool
        }
        if let number = attributeValue(element, attribute: attribute) as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    func frameValue(_ element: AXUIElement) -> CGRect? {
        guard
            let positionValue = axValue(element, attribute: kAXPositionAttribute as CFString),
            let sizeValue = axValue(element, attribute: kAXSizeAttribute as CFString)
        else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(positionValue) == .cgPoint, AXValueGetValue(positionValue, .cgPoint, &point) else {
            return nil
        }
        guard AXValueGetType(sizeValue) == .cgSize, AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    func actionNames(_ element: AXUIElement) -> [String] {
        applyMessagingTimeout(element)
        var namesRef: CFArray?
        let error = AXUIElementCopyActionNames(element, &namesRef)
        guard error == .success, let names = namesRef as? [String] else {
            return []
        }
        return names
    }

    func elementAtPosition(_ point: CGPoint, applicationElement: AXUIElement? = nil) -> AXUIElement? {
        let root = applicationElement ?? AXUIElementCreateSystemWide()
        applyMessagingTimeout(root, timeout: resolveMessagingTimeout)
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &element)
        guard error == .success else {
            return nil
        }
        return element
    }

    func focusedElement(applicationElement: AXUIElement? = nil) -> AXUIElement? {
        let root = applicationElement ?? AXUIElementCreateSystemWide()
        applyMessagingTimeout(root, timeout: resolveMessagingTimeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &value)
        guard error == .success, let value else {
            return nil
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    func summaryForElement(_ element: AXUIElement, fallbackPath: String = "runtime.focused") -> AxElementSummary {
        let role = stringValue(element, attribute: kAXRoleAttribute as CFString) ?? "AXUnknown"
        let name = compactText(stringValue(element, attribute: kAXTitleAttribute as CFString))
        let value = compactText(stringValue(element, attribute: kAXValueAttribute as CFString))
        let description = compactText(stringValue(element, attribute: kAXDescriptionAttribute as CFString))
        let enabled = boolValue(element, attribute: kAXEnabledAttribute as CFString) ?? true
        let focused = boolValue(element, attribute: kAXFocusedAttribute as CFString) ?? false
        let bbox = bboxArray(frameValue(element))
        let actions = actionNames(element)
        let id = makeElementId(
            role: role,
            appBundleId: "runtime",
            windowTitle: nil,
            name: name,
            value: value,
            description: description,
            bbox: frameValue(element),
            path: fallbackPath
        )
        return AxElementSummary(
            id: id,
            role: role,
            name: name,
            value: value,
            description: description,
            enabled: enabled,
            focused: focused,
            bbox: bbox,
            actions: actions,
            path: fallbackPath
        )
    }

    func postLeftClick(at point: CGPoint) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return false
        }
        source.localEventsSuppressionInterval = 0

        guard
            let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
            let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
            let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else {
            return false
        }

        move.post(tap: .cghidEventTap)
        down.post(tap: .cghidEventTap)
        usleep(12_000)
        up.post(tap: .cghidEventTap)
        return true
    }

    func postScroll(at point: CGPoint?, deltaX: Int32, deltaY: Int32) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return false
        }
        source.localEventsSuppressionInterval = 0

        if let point {
            guard moveMouse(to: point, source: source) else {
                return false
            }
        }

        guard let scroll = CGEvent(
            scrollWheelEvent2Source: source,
            units: .line,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else {
            return false
        }

        scroll.post(tap: .cghidEventTap)
        return true
    }

    func postLeftDrag(from start: CGPoint, to end: CGPoint, steps: Int = 12) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return false
        }
        source.localEventsSuppressionInterval = 0

        guard moveMouse(to: start, source: source),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)
        else {
            return false
        }

        down.post(tap: .cghidEventTap)
        usleep(12_000)

        let hopCount = max(2, steps)
        for step in 1...hopCount {
            let progress = CGFloat(step) / CGFloat(hopCount)
            let point = CGPoint(
                x: start.x + ((end.x - start.x) * progress),
                y: start.y + ((end.y - start.y) * progress)
            )
            guard let drag = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) else {
                return false
            }
            drag.post(tap: .cghidEventTap)
            usleep(8_000)
        }

        guard let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) else {
            return false
        }
        up.post(tap: .cghidEventTap)
        return true
    }

    func postKeySequence(keys: [String], text: String?) throws {
        let normalizedKeys = keys
            .map { sanitizeKeyToken($0) }
            .filter { !$0.isEmpty }
        let trimmedText = text?.trimmingCharacters(in: .newlines)

        guard !normalizedKeys.isEmpty || !(trimmedText ?? "").isEmpty else {
            throw EventSynthesisError.emptyKeyAction
        }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw EventSynthesisError.eventSourceUnavailable
        }
        source.localEventsSuppressionInterval = 0

        if !normalizedKeys.isEmpty {
            try postKeyCombo(normalizedKeys, source: source)
        }

        if let trimmedText, !trimmedText.isEmpty {
            try postUnicodeText(trimmedText, source: source)
        }
    }

    func postPasteText(_ text: String, restoreClipboard: Bool = true) throws {
        guard !text.isEmpty else {
            throw EventSynthesisError.emptyText
        }

        let pasteboard = NSPasteboard.general
        let snapshot = restoreClipboard ? snapshotPasteboard(pasteboard) : nil

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restorePasteboard(snapshot, pasteboard: pasteboard)
            throw EventSynthesisError.pasteboardWriteFailed
        }

        usleep(20_000)
        do {
            try postKeySequence(keys: ["cmd", "v"], text: nil)
            usleep(20_000)
        } catch {
            restorePasteboard(snapshot, pasteboard: pasteboard)
            throw error
        }

        restorePasteboard(snapshot, pasteboard: pasteboard)
    }

    private func attributeValue(_ element: AXUIElement, attribute: CFString) -> CFTypeRef? {
        applyMessagingTimeout(element)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success else {
            return nil
        }
        return value
    }

    private func elementValue(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        guard let raw = attributeValue(element, attribute: attribute) else {
            return nil
        }
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }

    private func elementsValue(_ element: AXUIElement, attribute: CFString) -> [AXUIElement] {
        guard let raw = attributeValue(element, attribute: attribute) else {
            return []
        }
        guard let array = raw as? [AnyObject] else {
            return []
        }
        return array.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else {
                return nil
            }
            return unsafeDowncast(item, to: AXUIElement.self)
        }
    }

    private func axValue(_ element: AXUIElement, attribute: CFString) -> AXValue? {
        guard let raw = attributeValue(element, attribute: attribute) else {
            return nil
        }
        guard CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        return unsafeDowncast(raw, to: AXValue.self)
    }

    private func bestWindowElement(appElement: AXUIElement, query: String?, focusedWindow: AXUIElement?) -> AXUIElement? {
        let windows = elementsValue(appElement, attribute: kAXWindowsAttribute as CFString)
        guard !windows.isEmpty else {
            return focusedWindow
        }

        let normalizedQuery = normalizedWindowQuery(query)
        guard let normalizedQuery, !normalizedQuery.isEmpty else {
            return focusedWindow ?? windows.first
        }

        let ranked = windows
            .map { window in
                (
                    window: window,
                    score: scoreWindow(window, query: normalizedQuery, focusedWindow: focusedWindow)
                )
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    let lhsArea = frameValue(lhs.window).map { $0.width * $0.height } ?? 0
                    let rhsArea = frameValue(rhs.window).map { $0.width * $0.height } ?? 0
                    return lhsArea > rhsArea
                }
                return lhs.score > rhs.score
            }

        if let best = ranked.first, best.score > 0 {
            eventLogger.log("helper_ax_window_selected", payload: [
                "query": normalizedQuery,
                "window_count": windows.count,
                "best_score": best.score,
                "selected_title": stringValue(best.window, attribute: kAXTitleAttribute as CFString) as Any,
            ])
            return best.window
        }
        eventLogger.log("helper_ax_window_selected", payload: [
            "query": normalizedQuery,
            "window_count": windows.count,
            "best_score": ranked.first?.score as Any,
            "selected_title": stringValue((focusedWindow ?? windows.first!), attribute: kAXTitleAttribute as CFString) as Any,
            "selection_mode": focusedWindow != nil ? "focused_fallback" : "first_window_fallback",
        ])
        return focusedWindow ?? windows.first
    }

    private func scoreWindow(_ window: AXUIElement, query: String, focusedWindow: AXUIElement?) -> Int {
        let title = normalizedWindowQuery(stringValue(window, attribute: kAXTitleAttribute as CFString)) ?? ""
        let document = normalizedWindowQuery(stringValue(window, attribute: kAXDocumentAttribute as CFString)) ?? ""
        let roleDescription = normalizedWindowQuery(stringValue(window, attribute: kAXRoleDescriptionAttribute as CFString)) ?? ""

        var score = 0
        if !title.isEmpty {
            if title == query { score = max(score, 140) }
            if title.hasPrefix(query) { score = max(score, 120) }
            if title.contains(query) || query.contains(title) { score = max(score, 100) }
        }
        if !document.isEmpty {
            if document == query { score = max(score, 110) }
            if document.contains(query) || query.contains(document) { score = max(score, 80) }
        }
        if !roleDescription.isEmpty && roleDescription.contains(query) {
            score = max(score, 40)
        }
        if let focusedWindow, CFEqual(window, focusedWindow) {
            score += 10
        }
        if let frame = frameValue(window), frame.width > 0, frame.height > 0 {
            score += 5
        }
        return score
    }

    private func normalizedWindowQuery(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func buildNode(
        element: AXUIElement,
        target: TargetContext,
        path: String,
        viewport: CGRect?,
        remaining: inout Int,
        depth: Int
    ) -> NodeBuildResult? {
        if remaining <= 0 || depth > 8 {
            return nil
        }

        let role = stringValue(element, attribute: kAXRoleAttribute as CFString) ?? "AXUnknown"
        let name = compactText(stringValue(element, attribute: kAXTitleAttribute as CFString))
        let value = compactText(stringValue(element, attribute: kAXValueAttribute as CFString))
        let description = compactText(stringValue(element, attribute: kAXDescriptionAttribute as CFString))
        let enabled = boolValue(element, attribute: kAXEnabledAttribute as CFString) ?? true
        let focused = boolValue(element, attribute: kAXFocusedAttribute as CFString) ?? false
        let bbox = frameValue(element)
        let actions = actionNames(element)

        if !visible(bbox: bbox, viewport: viewport) {
            return nil
        }

        remaining -= 1

        let rawChildren = elementsValue(element, attribute: kAXChildrenAttribute as CFString)
        var childNodes: [AxNode] = []
        var elements: [String: AxElementSummary] = [:]
        var nodesById: [String: AXUIElement] = [:]
        var totalNodes = 0
        var interactiveCount = 0

        for (index, child) in rawChildren.prefix(40).enumerated() {
            if remaining <= 0 {
                break
            }
            let childRole = stringValue(child, attribute: kAXRoleAttribute as CFString) ?? "AXUnknown"
            let childPath = "\(path).\(normalizedRole(childRole))_\(index + 1)"
            if let builtChild = buildNode(
                element: child,
                target: target,
                path: childPath,
                viewport: viewport,
                remaining: &remaining,
                depth: depth + 1
            ) {
                childNodes.append(builtChild.node)
                elements.merge(builtChild.elements) { current, _ in current }
                nodesById.merge(builtChild.nodesById) { current, _ in current }
                totalNodes += builtChild.totalNodes
                interactiveCount += builtChild.interactiveCount
            }
        }

        let nodeIsUseful = useful(role: role, name: name, value: value, description: description, actions: actions, focused: focused)
        if !nodeIsUseful, childNodes.isEmpty {
            return nil
        }
        if !nodeIsUseful, structuralRoles.contains(role), childNodes.count == 1 {
            return NodeBuildResult(
                node: childNodes[0],
                elements: elements,
                nodesById: nodesById,
                totalNodes: totalNodes,
                interactiveCount: interactiveCount
            )
        }

        let nodeId: String?
        if nodeIsUseful {
            nodeId = makeElementId(
                role: role,
                appBundleId: target.bundleId,
                windowTitle: target.windowTitle,
                name: name,
                value: value,
                description: description,
                bbox: bbox,
                path: path
            )
        } else {
            nodeId = nil
        }

        let node = AxNode(
            id: nodeId,
            role: role,
            name: name,
            value: value,
            description: description,
            enabled: enabled,
            focused: focused,
            bbox: bboxArray(bbox),
            actions: actions,
            path: path,
            children: childNodes
        )

        if let nodeId {
            let summary = AxElementSummary(
                id: nodeId,
                role: role,
                name: name,
                value: value,
                description: description,
                enabled: enabled,
                focused: focused,
                bbox: bboxArray(bbox),
                actions: actions,
                path: path
            )
            elements[nodeId] = summary
            nodesById[nodeId] = element
            interactiveCount += 1
        }

        return NodeBuildResult(
            node: node,
            elements: elements,
            nodesById: nodesById,
            totalNodes: totalNodes + 1,
            interactiveCount: interactiveCount
        )
    }

    private func simpleNode(element: AXUIElement, role: String, path: String) -> AxNode {
        AxNode(
            id: nil,
            role: role,
            name: compactText(stringValue(element, attribute: kAXTitleAttribute as CFString)),
            value: compactText(stringValue(element, attribute: kAXValueAttribute as CFString)),
            description: compactText(stringValue(element, attribute: kAXDescriptionAttribute as CFString)),
            enabled: boolValue(element, attribute: kAXEnabledAttribute as CFString) ?? true,
            focused: boolValue(element, attribute: kAXFocusedAttribute as CFString) ?? false,
            bbox: bboxArray(frameValue(element)),
            actions: actionNames(element),
            path: path,
            children: []
        )
    }

    private func useful(
        role: String,
        name: String?,
        value: String?,
        description: String?,
        actions: [String],
        focused: Bool
    ) -> Bool {
        if interactiveRoles.contains(role) || !actions.isEmpty || focused {
            return true
        }
        if textRoles.contains(role) {
            return !labelOf(name: name, value: value, description: description).isEmpty
        }
        return false
    }

    private func labelOf(name: String?, value: String?, description: String?) -> String {
        [name, value, description]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func visible(bbox: CGRect?, viewport: CGRect?) -> Bool {
        guard let bbox else {
            return true
        }
        if bbox.width <= 0 || bbox.height <= 0 {
            return false
        }
        guard let viewport else {
            return true
        }
        return bbox.intersects(viewport)
    }

    private func makeElementId(
        role: String,
        appBundleId: String,
        windowTitle: String?,
        name: String?,
        value: String?,
        description: String?,
        bbox: CGRect?,
        path: String
    ) -> String {
        let bucket = bbox.map { "\(Int($0.origin.x / 8)):\(Int($0.origin.y / 8)):\(Int($0.size.width / 8)):\(Int($0.size.height / 8))" } ?? "no-bbox"
        let raw = [appBundleId, windowTitle ?? "", role, name ?? "", value ?? "", description ?? "", bucket, path].joined(separator: "|")
        return "\(rolePrefix(role))_\(stableDigest(raw).prefix(8))"
    }

    private func rolePrefix(_ role: String) -> String {
        switch role {
        case "AXButton": return "btn"
        case "AXCheckBox": return "chk"
        case "AXComboBox": return "cmb"
        case "AXDisclosureTriangle": return "dsc"
        case "AXLink": return "lnk"
        case "AXMenuButton": return "mnu"
        case "AXMenuItem": return "itm"
        case "AXPopUpButton": return "pop"
        case "AXRadioButton": return "rad"
        case "AXRow": return "row"
        case "AXSlider": return "sld"
        case "AXTab": return "tab"
        case "AXTextArea", "AXTextField": return "txt"
        default: return "el"
        }
    }

    private func normalizedRole(_ role: String) -> String {
        role
            .replacingOccurrences(of: "AX", with: "")
            .replacingOccurrences(of: "[^A-Za-z0-9]+", with: "_", options: .regularExpression)
            .lowercased()
    }

    private func stableDigest(_ input: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16, uppercase: false)
    }

    private func compactText(_ value: String?, limit: Int = 120) -> String? {
        guard let value else {
            return nil
        }
        let squashed = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !squashed.isEmpty else {
            return nil
        }
        if squashed.count <= limit {
            return squashed
        }
        return String(squashed.prefix(limit - 1)) + "…"
    }

    private func bboxArray(_ rect: CGRect?) -> [Double]? {
        guard let rect else {
            return nil
        }
        return [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
    }

    private func moveMouse(to point: CGPoint, source: CGEventSource) -> Bool {
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            return false
        }
        move.post(tap: .cghidEventTap)
        usleep(8_000)
        return true
    }

    private func postKeyCombo(_ tokens: [String], source: CGEventSource) throws {
        guard !tokens.isEmpty else {
            throw EventSynthesisError.emptyKeyAction
        }

        let modifiers = modifierDefinitions(from: tokens)
        let nonModifierTokens = tokens.filter { modifierDefinition(for: $0) == nil }

        if nonModifierTokens.count > 1 {
            for token in nonModifierTokens {
                try postKeyCombo(modifiers.map(\.token) + [token], source: source)
            }
            return
        }

        let flags = modifiers.reduce(CGEventFlags()) { current, item in
            current.union(item.flags)
        }

        for modifier in modifiers {
            try postKeyEvent(source: source, keyCode: modifier.keyCode, keyDown: true, flags: flags)
        }

        if let token = nonModifierTokens.first {
            guard let keyCode = keyCode(for: token) else {
                throw EventSynthesisError.unsupportedKey(token)
            }
            try postKeyEvent(source: source, keyCode: keyCode, keyDown: true, flags: flags)
            try postKeyEvent(source: source, keyCode: keyCode, keyDown: false, flags: flags)
        }

        for modifier in modifiers.reversed() {
            try postKeyEvent(source: source, keyCode: modifier.keyCode, keyDown: false, flags: flags.subtracting(modifier.flags))
        }
    }

    private func postUnicodeText(_ text: String, source: CGEventSource) throws {
        guard !text.isEmpty else {
            throw EventSynthesisError.emptyText
        }

        for scalar in text.unicodeScalars {
            let utf16 = Array(String(scalar).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw EventSynthesisError.eventCreationFailed("unicode text event")
            }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.post(tap: .cghidEventTap)
            usleep(6_000)
            up.post(tap: .cghidEventTap)
            usleep(6_000)
        }
    }

    private func postKeyEvent(source: CGEventSource, keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags) throws {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
            throw EventSynthesisError.eventCreationFailed("keyCode \(keyCode)")
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        usleep(6_000)
    }

    private func modifierDefinitions(from tokens: [String]) -> [(token: String, keyCode: CGKeyCode, flags: CGEventFlags)] {
        tokens.compactMap { token in
            guard let definition = modifierDefinition(for: token) else {
                return nil
            }
            return (token: token, keyCode: definition.keyCode, flags: definition.flags)
        }
    }

    private func modifierDefinition(for token: String) -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        switch token {
        case "cmd", "command":
            return (CGKeyCode(kVK_Command), .maskCommand)
        case "shift":
            return (CGKeyCode(kVK_Shift), .maskShift)
        case "option", "opt", "alt":
            return (CGKeyCode(kVK_Option), .maskAlternate)
        case "ctrl", "control":
            return (CGKeyCode(kVK_Control), .maskControl)
        default:
            return nil
        }
    }

    private func sanitizeKeyToken(_ token: String) -> String {
        let lowered = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9_+-]+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        switch lowered {
        case "arrowleft", "leftarrow":
            return "left"
        case "arrowright", "rightarrow":
            return "right"
        case "arrowup", "uparrow":
            return "up"
        case "arrowdown", "downarrow":
            return "down"
        case "command":
            return "cmd"
        case "control":
            return "ctrl"
        case "return":
            return "enter"
        case "del":
            return "delete"
        default:
            return lowered
        }
    }

    private func keyCode(for token: String) -> CGKeyCode? {
        switch token {
        case "a": return CGKeyCode(kVK_ANSI_A)
        case "b": return CGKeyCode(kVK_ANSI_B)
        case "c": return CGKeyCode(kVK_ANSI_C)
        case "d": return CGKeyCode(kVK_ANSI_D)
        case "e": return CGKeyCode(kVK_ANSI_E)
        case "f": return CGKeyCode(kVK_ANSI_F)
        case "g": return CGKeyCode(kVK_ANSI_G)
        case "h": return CGKeyCode(kVK_ANSI_H)
        case "i": return CGKeyCode(kVK_ANSI_I)
        case "j": return CGKeyCode(kVK_ANSI_J)
        case "k": return CGKeyCode(kVK_ANSI_K)
        case "l": return CGKeyCode(kVK_ANSI_L)
        case "m": return CGKeyCode(kVK_ANSI_M)
        case "n": return CGKeyCode(kVK_ANSI_N)
        case "o": return CGKeyCode(kVK_ANSI_O)
        case "p": return CGKeyCode(kVK_ANSI_P)
        case "q": return CGKeyCode(kVK_ANSI_Q)
        case "r": return CGKeyCode(kVK_ANSI_R)
        case "s": return CGKeyCode(kVK_ANSI_S)
        case "t": return CGKeyCode(kVK_ANSI_T)
        case "u": return CGKeyCode(kVK_ANSI_U)
        case "v": return CGKeyCode(kVK_ANSI_V)
        case "w": return CGKeyCode(kVK_ANSI_W)
        case "x": return CGKeyCode(kVK_ANSI_X)
        case "y": return CGKeyCode(kVK_ANSI_Y)
        case "z": return CGKeyCode(kVK_ANSI_Z)
        case "0": return CGKeyCode(kVK_ANSI_0)
        case "1": return CGKeyCode(kVK_ANSI_1)
        case "2": return CGKeyCode(kVK_ANSI_2)
        case "3": return CGKeyCode(kVK_ANSI_3)
        case "4": return CGKeyCode(kVK_ANSI_4)
        case "5": return CGKeyCode(kVK_ANSI_5)
        case "6": return CGKeyCode(kVK_ANSI_6)
        case "7": return CGKeyCode(kVK_ANSI_7)
        case "8": return CGKeyCode(kVK_ANSI_8)
        case "9": return CGKeyCode(kVK_ANSI_9)
        case "space":
            return CGKeyCode(kVK_Space)
        case "return", "enter":
            return CGKeyCode(kVK_Return)
        case "tab":
            return CGKeyCode(kVK_Tab)
        case "escape", "esc":
            return CGKeyCode(kVK_Escape)
        case "delete", "backspace":
            return CGKeyCode(kVK_Delete)
        case "forward_delete":
            return CGKeyCode(kVK_ForwardDelete)
        case "left":
            return CGKeyCode(kVK_LeftArrow)
        case "right":
            return CGKeyCode(kVK_RightArrow)
        case "up":
            return CGKeyCode(kVK_UpArrow)
        case "down":
            return CGKeyCode(kVK_DownArrow)
        case "home":
            return CGKeyCode(kVK_Home)
        case "end":
            return CGKeyCode(kVK_End)
        case "pageup":
            return CGKeyCode(kVK_PageUp)
        case "pagedown":
            return CGKeyCode(kVK_PageDown)
        case "comma", ",":
            return CGKeyCode(kVK_ANSI_Comma)
        case "period", ".":
            return CGKeyCode(kVK_ANSI_Period)
        case "slash", "/":
            return CGKeyCode(kVK_ANSI_Slash)
        case "backslash", "\\":
            return CGKeyCode(kVK_ANSI_Backslash)
        case "minus", "-":
            return CGKeyCode(kVK_ANSI_Minus)
        case "equals", "=":
            return CGKeyCode(kVK_ANSI_Equal)
        case "left_bracket", "[":
            return CGKeyCode(kVK_ANSI_LeftBracket)
        case "right_bracket", "]":
            return CGKeyCode(kVK_ANSI_RightBracket)
        case "quote", "'":
            return CGKeyCode(kVK_ANSI_Quote)
        case "semicolon", ";":
            return CGKeyCode(kVK_ANSI_Semicolon)
        case "grave", "`":
            return CGKeyCode(kVK_ANSI_Grave)
        default:
            return nil
        }
    }

    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
            var snapshot: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    snapshot[type] = data
                }
            }
            return snapshot
        }
        return PasteboardSnapshot(items: items)
    }

    private func restorePasteboard(_ snapshot: PasteboardSnapshot?, pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard let snapshot, !snapshot.items.isEmpty else {
            return
        }

        let items = snapshot.items.map { itemSnapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in itemSnapshot {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private func applyMessagingTimeout(_ element: AXUIElement, timeout: Float? = nil) {
        _ = AXUIElementSetMessagingTimeout(element, timeout ?? attributeMessagingTimeout)
    }

    private func elapsedMs(since startedAt: Date) -> Int {
        Int(Date().timeIntervalSince(startedAt) * 1000)
    }

    private static func readFloatEnv(_ key: String, default defaultValue: Float) -> Float {
        guard
            let raw = ProcessInfo.processInfo.environment[key],
            let parsed = Float(raw),
            parsed > 0
        else {
            return defaultValue
        }
        return parsed
    }
}
