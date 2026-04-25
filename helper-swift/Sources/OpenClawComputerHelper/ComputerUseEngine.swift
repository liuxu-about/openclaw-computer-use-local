import Foundation

private let axCaptureSemaphore = DispatchSemaphore(
    value: max(
        1,
        Int(ProcessInfo.processInfo.environment["COMPUTER_USE_AX_CAPTURE_CONCURRENCY"] ?? "") ?? 1
    )
)

private final class SceneCaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedScene: SceneSnapshot?
    private var captureError: String?

    func store(scene: SceneSnapshot) {
        lock.lock()
        capturedScene = scene
        lock.unlock()
    }

    func store(error: String) {
        lock.lock()
        captureError = error
        lock.unlock()
    }

    func snapshot() -> (scene: SceneSnapshot?, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (capturedScene, captureError)
    }
}

@MainActor
final class ComputerUseEngine {
    private struct GuardedSceneCaptureResult {
        let scene: SceneSnapshot
        let timedOut: Bool
        let error: String?
        let durationMs: Int
    }

    private let accessibilityService = AccessibilityService()
    private let screenshotService = ScreenshotService()
    private let observationStore = ObservationStore()
    private let visionPlanner = VisionFallbackPlanner()
    private let eventLogger = EventLogger.shared
    private lazy var actionExecutor = ActionExecutor(accessibilityService: accessibilityService)
    private let axCaptureTimeoutMs = ComputerUseEngine.readIntEnv("COMPUTER_USE_AX_CAPTURE_TIMEOUT_MS", default: 2800)

    func health() -> HealthResponse {
        let frontmost = accessibilityService.frontmostAppInfo()
        let response = HealthResponse(
            ok: true,
            helper: "openclaw-computer-helper",
            axTrusted: accessibilityService.accessibilityTrusted(),
            screenRecordingTrusted: accessibilityService.screenRecordingTrusted(),
            frontmostApp: frontmost.name,
            frontmostBundleId: frontmost.bundleId,
            eventLogPath: eventLogger.logPath
        )
        eventLogger.log("helper_health", payload: [
            "ax_trusted": response.axTrusted,
            "screen_recording_trusted": response.screenRecordingTrusted,
            "frontmost_app": response.frontmostApp,
            "frontmost_bundle_id": response.frontmostBundleId,
            "event_log": eventLogger.logPath,
        ])
        return response
    }

    func observe(_ request: ObserveRequest) async -> Observation {
        let screen = accessibilityService.currentScreenInfo()
        let axTrusted = accessibilityService.accessibilityTrusted()
        let screenTrusted = accessibilityService.screenRecordingTrusted()
        let sceneResult = guardedCaptureScene(
            targetNamed: request.targetApp,
            windowNamed: request.targetWindow,
            maxNodes: Int(request.maxNodes ?? 250)
        )
        let scene = sceneResult.scene

        let screenshot = await screenshotService.captureIfRequested(request: request, target: scene.target, screen: screen)

        let frontmost = accessibilityService.frontmostAppInfo()
        let appName = scene.target?.appName ?? request.targetApp ?? frontmost.name
        let bundleId = scene.target?.bundleId ?? request.targetApp ?? frontmost.bundleId
        let windowTitle = scene.target?.windowTitle ?? request.targetWindow ?? "Unknown Window"

        let plannerDecision = visionPlanner.decide(
            requestMode: request.mode,
            accessibilityTrusted: axTrusted,
            screenRecordingTrusted: screenTrusted,
            screenshotAvailable: screenshot.artifact != nil,
            tree: scene.tree,
            elements: scene.elements
        )

        let decision: VisionDecision
        if sceneResult.timedOut {
            let source: String
            if request.mode == .vision, screenshot.artifact != nil {
                source = "vision"
            } else if screenshot.artifact != nil, request.mode == .axWithScreenshot || request.includeScreenshot == true {
                source = "ax+vision"
            } else {
                source = "ax"
            }
            let fallbackReason = screenshot.artifact != nil
                ? "ax_capture_timed_out"
                : "ax_capture_timed_out_and_screenshot_capture_failed"
            decision = VisionDecision(source: source, fallbackRecommended: true, fallbackReason: fallbackReason)
        } else {
            decision = plannerDecision
        }

        let observation = Observation(
            observationId: makeObservationId(bundleId: bundleId),
            source: decision.source,
            activeApp: appName,
            activeWindow: windowTitle,
            screen: screen,
            tree: scene.tree,
            elements: scene.elements,
            screenshot: screenshot.artifact,
            screenshotError: screenshot.error,
            observeError: sceneResult.error,
            fallbackRecommended: decision.fallbackRecommended,
            fallbackReason: decision.fallbackReason
        )

        observationStore.save(observation: observation, bundleId: bundleId)
        eventLogger.log("helper_observe", payload: [
            "target_app": request.targetApp as Any,
            "target_window": request.targetWindow as Any,
            "mode": request.mode?.rawValue as Any,
            "include_screenshot": request.includeScreenshot as Any,
            "active_app": observation.activeApp,
            "active_window": observation.activeWindow,
            "source": observation.source,
            "element_count": observation.elements.count,
            "fallback_recommended": observation.fallbackRecommended,
            "fallback_reason": observation.fallbackReason as Any,
            "screenshot_capture_kind": observation.screenshot?.captureKind as Any,
            "screenshot_error": observation.screenshotError as Any,
            "observe_error": observation.observeError as Any,
            "ax_capture_duration_ms": sceneResult.durationMs,
        ])
        if sceneResult.timedOut {
            scheduleHelperRecycle(reason: "ax_capture_timed_out")
        }
        return observation
    }

    func act(_ request: ActionRequest) async -> ActionResponse {
        let storedObservation = observationStore.load(observationId: request.observationId)
        let targetHint = storedObservation?.bundleId ?? targetHint(from: request.observationId)
        let windowHint = meaningfulWindowHint(from: storedObservation?.activeWindow)
        let results = actionExecutor.execute(
            request: request,
            targetHint: targetHint,
            windowHint: windowHint,
            storedObservation: storedObservation
        )
        let ok = results.allSatisfy { $0.status == "ok" }
        let nextObservation = await observe(
            ObserveRequest(
                targetApp: targetHint,
                targetWindow: windowHint,
                mode: .ax,
                maxNodes: 250,
                includeScreenshot: false
            )
        )
        let response = ActionResponse(ok: ok, results: results, nextObservation: nextObservation)
        eventLogger.log("helper_act", payload: [
            "observation_id": request.observationId,
            "action_count": request.actions.count,
            "actions": request.actions.map { action in
                [
                    "type": action.type,
                    "id": action.id as Any,
                    "strategy": action.strategy as Any,
                ]
            },
            "ok": response.ok,
            "results": response.results.map { result in
                [
                    "index": result.index,
                    "type": result.type,
                    "route": result.route,
                    "status": result.status,
                    "error_code": result.errorCode as Any,
                ]
            },
            "next_active_app": response.nextObservation?.activeApp as Any,
            "next_active_window": response.nextObservation?.activeWindow as Any,
        ])
        return response
    }

    func stop() -> StopResponse {
        let response = StopResponse(ok: true, stopped: false, message: "No persistent helper session is active yet; stop is a no-op in the skeleton.")
        eventLogger.log("helper_stop", payload: [
            "stopped": response.stopped,
            "message": response.message,
        ])
        return response
    }

    func useTask(_ request: ComputerUseRequest) async -> ComputerUseResponse {
        let observation = await observe(
            ObserveRequest(
                targetApp: request.targetApp,
                targetWindow: request.targetWindow,
                mode: request.allowVisionFallback == false ? .ax : .axWithScreenshot,
                maxNodes: 250,
                includeScreenshot: request.allowVisionFallback != false
            )
        )

        var notes = [
            "AX-first observation executed.",
            "Prefer element-level actions such as press, focus, set_value, and append_text.",
            "Fall back to vision only when the AX surface is too sparse or non-semantic."
        ]
        if observation.screenshot != nil {
            notes.append("Screenshot artifact captured for optional vision grounding.")
        }
        if let screenshotError = observation.screenshotError {
            notes.append("Screenshot capture warning: \(screenshotError)")
        }
        if let observeError = observation.observeError {
            notes.append("AX capture warning: \(observeError)")
        }
        if observation.fallbackRecommended, let reason = observation.fallbackReason {
            notes.append("Fallback suggested: \(reason)")
        }
        if request.allowVisionFallback == false {
            notes.append("Vision fallback disabled by caller.")
        }
        if let approvalMode = request.approvalMode {
            notes.append("Approval mode: \(approvalMode)")
        }

        let response = ComputerUseResponse(
            ok: true,
            status: observation.fallbackRecommended ? "needs_followup" : "ready",
            mode: "ax_first",
            task: request.task,
            targetApp: request.targetApp,
            observation: observation,
            notes: notes
        )
        eventLogger.log("helper_use", payload: [
            "task": request.task,
            "target_app": request.targetApp,
            "target_window": request.targetWindow as Any,
            "status": response.status,
            "fallback_recommended": observation.fallbackRecommended,
            "fallback_reason": observation.fallbackReason as Any,
            "screenshot_error": observation.screenshotError as Any,
            "observe_error": observation.observeError as Any,
        ])
        return response
    }

    private func makeObservationId(bundleId: String) -> String {
        "\(bundleId)|\(UUID().uuidString)"
    }

    private func targetHint(from observationId: String) -> String? {
        observationId.split(separator: "|", maxSplits: 1).first.map(String.init)
    }

    private func meaningfulWindowHint(from value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "Unknown Window" else {
            return nil
        }
        return trimmed
    }

    private func guardedCaptureScene(targetNamed query: String?, windowNamed windowQuery: String?, maxNodes: Int) -> GuardedSceneCaptureResult {
        let startedAt = Date()
        let group = DispatchGroup()
        let captureBox = SceneCaptureBox()
        let service = AccessibilityService()
        let timeoutMs = max(500, axCaptureTimeoutMs)

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            guard axCaptureSemaphore.wait(timeout: .now() + .milliseconds(timeoutMs)) == .success else {
                captureBox.store(error: "AX scene capture skipped because another capture is still running after \(timeoutMs)ms.")
                group.leave()
                return
            }
            defer {
                axCaptureSemaphore.signal()
            }

            let scene = service.captureScene(
                targetNamed: query,
                windowNamed: windowQuery,
                maxNodes: maxNodes
            )
            captureBox.store(scene: scene)
            group.leave()
        }

        let waitResult = group.wait(timeout: .now() + .milliseconds(timeoutMs))
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        if waitResult == .timedOut {
            let message = "AX scene capture timed out after \(timeoutMs)ms."
            eventLogger.log("helper_ax_stage_timed_out", payload: [
                "stage": "capture_scene_guard",
                "target_app": query as Any,
                "target_window": windowQuery as Any,
                "max_nodes": maxNodes,
                "timeout_ms": timeoutMs,
                "duration_ms": durationMs,
            ])
            return GuardedSceneCaptureResult(
                scene: emptySceneSnapshot(),
                timedOut: true,
                error: message,
                durationMs: durationMs
            )
        }

        let snapshot = captureBox.snapshot()
        let scene = snapshot.scene ?? emptySceneSnapshot()
        let error = snapshot.error
        if let error {
            eventLogger.log("helper_ax_stage_timed_out", payload: [
                "stage": "capture_scene_guard",
                "target_app": query as Any,
                "target_window": windowQuery as Any,
                "max_nodes": maxNodes,
                "timeout_ms": timeoutMs,
                "duration_ms": durationMs,
                "reason": error,
            ])
            return GuardedSceneCaptureResult(
                scene: scene,
                timedOut: true,
                error: error,
                durationMs: durationMs
            )
        }
        return GuardedSceneCaptureResult(
            scene: scene,
            timedOut: false,
            error: nil,
            durationMs: durationMs
        )
    }

    private func emptySceneSnapshot() -> SceneSnapshot {
        SceneSnapshot(target: nil, tree: [], elements: [:], nodesById: [:], totalNodes: 0, interactiveCount: 0)
    }

    private func scheduleHelperRecycle(reason: String) {
        eventLogger.log("helper_recycle_scheduled", payload: [
            "reason": reason,
            "delay_ms": 750,
        ])
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(750)) {
            EventLogger.shared.log("helper_recycle_exiting", payload: [
                "reason": reason,
            ])
            Foundation.exit(124)
        }
    }

    private static func readIntEnv(_ key: String, default defaultValue: Int) -> Int {
        guard
            let raw = ProcessInfo.processInfo.environment[key],
            let parsed = Int(raw),
            parsed > 0
        else {
            return defaultValue
        }
        return parsed
    }
}
