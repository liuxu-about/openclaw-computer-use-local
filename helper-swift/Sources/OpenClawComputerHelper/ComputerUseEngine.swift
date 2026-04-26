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
    private let sessionStore = SessionStore()
    private let visionPlanner = VisionFallbackPlanner()
    private let eventLogger = EventLogger.shared
    private let observationSummarizer = ObservationSummarizer()
    private let overlayRenderer = OverlayRenderer()
    private let ocrTextService = OCRTextService()
    private let appProfiles = AppProfileRegistry()
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
        let summary = observationSummarizer.summarize(tree: scene.tree, elements: scene.elements)
        let ocrMatches = screenshot.artifact.map { artifact in
            ocrTextService.matches(screenshot: artifact, limit: 60)
        } ?? []
        let overlay = screenshot.artifact.flatMap { artifact in
            overlayRenderer.render(
                screenshot: artifact,
                recommendedTargets: summary.recommendedTargets,
                ocrMatches: ocrMatches
            )
        }

        let frontmost = accessibilityService.frontmostAppInfo()
        let appName = scene.target?.appName ?? request.targetApp ?? frontmost.name
        let bundleId = scene.target?.bundleId ?? request.targetApp ?? frontmost.bundleId
        let windowTitle = scene.target?.windowTitle ?? request.targetWindow ?? "Unknown Window"
        let sessionId = request.sessionId ?? sessionStore.makeSessionId(bundleId: bundleId)
        let sceneDigest = SceneDigest.compute(scene)

        let plannerDecision = visionPlanner.decide(
            requestMode: request.mode,
            accessibilityTrusted: axTrusted,
            screenRecordingTrusted: screenTrusted,
            screenshotAvailable: screenshot.artifact != nil,
            tree: scene.tree,
            elements: scene.elements
        )

        let rawDecision: VisionDecision
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
            rawDecision = VisionDecision(source: source, fallbackRecommended: true, fallbackReason: fallbackReason)
        } else {
            rawDecision = plannerDecision
        }
        let decision = VisionDecision(
            source: rawDecision.source,
            fallbackRecommended: rawDecision.fallbackRecommended,
            fallbackReason: refinedFallbackReason(rawDecision.fallbackReason, screenshotError: screenshot.error)
        )

        let observation = Observation(
            observationId: makeObservationId(bundleId: bundleId),
            sessionId: sessionId,
            sceneDigest: sceneDigest,
            source: decision.source,
            activeApp: appName,
            activeWindow: windowTitle,
            screen: screen,
            tree: scene.tree,
            elements: scene.elements,
            uiSummary: summary.uiSummary,
            recommendedTargets: summary.recommendedTargets,
            screenshot: screenshot.artifact,
            overlay: overlay,
            screenshotError: screenshot.error,
            observeError: sceneResult.error,
            fallbackRecommended: decision.fallbackRecommended,
            fallbackReason: decision.fallbackReason,
            session: nil
        )

        observationStore.save(observation: observation, bundleId: bundleId)
        let sessionContext = sessionStore.appendObservation(
            observation: observation,
            targetApp: request.targetApp ?? appName,
            targetWindow: request.targetWindow ?? meaningfulWindowHint(from: windowTitle)
        )
        let observationWithSession = withSession(observation, context: sessionContext)
        eventLogger.log("helper_observe", payload: [
            "session_id": sessionId,
            "target_app": request.targetApp as Any,
            "target_window": request.targetWindow as Any,
            "mode": request.mode?.rawValue as Any,
            "include_screenshot": request.includeScreenshot as Any,
            "active_app": observation.activeApp,
            "active_window": observation.activeWindow,
            "source": observation.source,
            "scene_digest": observation.sceneDigest,
            "element_count": observation.elements.count,
            "recommended_target_count": observation.recommendedTargets.count,
            "overlay_path": observation.overlay?.path as Any,
            "overlay_legend_count": observation.overlay?.legend.count as Any,
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
        return observationWithSession
    }

    func act(_ request: ActionRequest) async -> ActionResponse {
        let storedObservation = observationStore.load(observationId: request.observationId)
        let targetHint = storedObservation?.bundleId ?? targetHint(from: request.observationId)
        let windowHint = meaningfulWindowHint(from: storedObservation?.activeWindow)
        let sessionId = request.sessionId ?? storedObservation?.sessionId ?? sessionStore.makeSessionId(bundleId: targetHint)
        let results = actionExecutor.execute(
            request: request,
            targetHint: targetHint,
            windowHint: windowHint,
            storedObservation: storedObservation
        )
        let ok = results.allSatisfy { $0.status == "ok" }
        _ = sessionStore.appendAction(
            sessionId: sessionId,
            observationId: request.observationId,
            actions: request.actions,
            results: results,
            targetApp: targetHint,
            targetWindow: windowHint
        )
        let nextObservation = await observe(
            ObserveRequest(
                sessionId: sessionId,
                targetApp: targetHint,
                targetWindow: windowHint,
                mode: .ax,
                maxNodes: 250,
                includeScreenshot: false
            )
        )
        let response = ActionResponse(
            ok: ok,
            sessionId: sessionId,
            results: results,
            nextObservation: nextObservation,
            session: nextObservation.session ?? sessionStore.loadContext(sessionId: sessionId)
        )
        eventLogger.log("helper_act", payload: [
            "session_id": sessionId,
            "observation_id": request.observationId,
            "action_count": request.actions.count,
            "actions": request.actions.map { action in
                [
                    "type": action.type,
                    "id": action.id as Any,
                    "mark": action.mark as Any,
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
        let sessionId = request.sessionId ?? sessionStore.makeSessionId(bundleId: request.targetApp)
        let observation = await observe(
            ObserveRequest(
                sessionId: sessionId,
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
        let appProfile = appProfiles.profile(for: observation.activeApp)
        notes.append("App profile: \(appProfile.id).")
        notes.append(contentsOf: appProfile.notes)
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

        let suggestedNextActions = suggestedNextActions(for: request, observation: observation)
        var steps = [
            ComputerUseStep(
                index: 0,
                phase: "observe",
                status: "ok",
                observationId: observation.observationId,
                message: "Captured an initial AX-first observation for the task session."
            )
        ]

        var allPlannedActions: [PlannedComputerAction] = []
        var actionResponses: [ActionResponse] = []
        var finalObservation: Observation?
        var currentObservation = observation
        var completedActionTypes: [String] = []
        var risk = ComputerUseRisk(
            level: "low",
            reasons: ["no_plan_evaluated"],
            requiresApproval: false,
            approvalTokenRequired: false
        )
        var status = observation.fallbackRecommended ? "needs_grounding" : "ready_for_actions"
        let autoExecute = request.autoExecute != false
        let maxSteps = max(0, min(5, Int(request.maxSteps ?? 1)))
        let planningBudget = autoExecute ? maxSteps : 1

        if planningBudget == 0 {
            status = "planned"
        }

        for iteration in 0..<planningBudget {
            let planned = reindexPlannedActions(
                planDeterministicActions(
                    for: request,
                    observation: currentObservation,
                    completedActionTypes: completedActionTypes
                ),
                offset: allPlannedActions.count
            )
            allPlannedActions.append(contentsOf: planned)
            let planStepIndex = steps.count
            steps.append(
                ComputerUseStep(
                    index: planStepIndex,
                    phase: "plan_next_action",
                    status: planned.isEmpty ? "needs_model_plan" : "planned",
                    observationId: currentObservation.observationId,
                    message: planned.isEmpty
                        ? "No deterministic helper-side action was selected; use recommended_targets to choose the next small action."
                        : "Prepared deterministic action plan \(iteration + 1) of \(planningBudget)."
                )
            )

            risk = assessRisk(request: request, observation: currentObservation, plannedActions: planned)
            steps.append(
                ComputerUseStep(
                    index: steps.count,
                    phase: "risk_check",
                    status: risk.requiresApproval ? "approval_required" : "ok",
                    observationId: currentObservation.observationId,
                    message: risk.requiresApproval
                        ? "The planned action needs user approval before execution."
                        : "The planned action is low enough risk for helper-side execution."
                )
            )

            if risk.requiresApproval {
                status = "approval_required"
                break
            }

            if planned.isEmpty {
                if actionResponses.isEmpty {
                    status = observation.fallbackRecommended ? "needs_grounding" : "ready_for_actions"
                } else {
                    status = "completed"
                }
                break
            }

            if !autoExecute {
                status = "planned"
                break
            }

            let response = await act(
                ActionRequest(
                    sessionId: sessionId,
                    observationId: currentObservation.observationId,
                    actions: planned.map(\.action)
                )
            )
            actionResponses.append(response)
            finalObservation = response.nextObservation
            steps.append(
                ComputerUseStep(
                    index: steps.count,
                    phase: "act",
                    status: response.ok ? "ok" : "needs_recovery",
                    observationId: response.nextObservation?.observationId ?? currentObservation.observationId,
                    message: response.ok
                        ? "Executed planned action batch \(iteration + 1) and captured a follow-up observation."
                        : "Executed planned action batch \(iteration + 1), but one or more action results need recovery."
                )
            )
            steps.append(
                ComputerUseStep(
                    index: steps.count,
                    phase: "verify",
                    status: response.ok ? "verified" : "unverified",
                    observationId: response.nextObservation?.observationId ?? currentObservation.observationId,
                    message: response.results
                        .compactMap { $0.verification?.evidence.joined(separator: ", ") }
                        .first ?? "No action verification evidence was returned."
                )
            )

            completedActionTypes.append(contentsOf: planned.map { $0.action.type })
            guard response.ok else {
                status = "needs_recovery"
                break
            }
            guard let nextObservation = response.nextObservation else {
                status = "needs_recovery"
                break
            }
            currentObservation = nextObservation
            status = iteration + 1 >= planningBudget ? "completed_steps" : "completed_step"
        }

        let response = ComputerUseResponse(
            ok: true,
            status: status,
            mode: "ax_first_session",
            sessionId: sessionId,
            task: request.task,
            targetApp: request.targetApp,
            observation: observation,
            finalObservation: finalObservation,
            session: actionResponses.last?.session ?? finalObservation?.session ?? observation.session ?? sessionStore.loadContext(sessionId: sessionId),
            steps: steps,
            risk: risk,
            plannedActions: allPlannedActions,
            actionResponse: actionResponses.last,
            actionResponses: actionResponses,
            suggestedNextActions: suggestedNextActions,
            notes: notes
        )
        eventLogger.log("helper_use", payload: [
            "session_id": sessionId,
            "task": request.task,
            "target_app": request.targetApp,
            "target_window": request.targetWindow as Any,
            "status": response.status,
            "risk_level": risk.level,
            "risk_reasons": risk.reasons,
            "planned_action_count": allPlannedActions.count,
            "action_response_count": actionResponses.count,
            "action_executed": !actionResponses.isEmpty,
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

    private func withSession(_ observation: Observation, context: SessionContext?) -> Observation {
        Observation(
            observationId: observation.observationId,
            sessionId: observation.sessionId,
            sceneDigest: observation.sceneDigest,
            source: observation.source,
            activeApp: observation.activeApp,
            activeWindow: observation.activeWindow,
            screen: observation.screen,
            tree: observation.tree,
            elements: observation.elements,
            uiSummary: observation.uiSummary,
            recommendedTargets: observation.recommendedTargets,
            screenshot: observation.screenshot,
            overlay: observation.overlay,
            screenshotError: observation.screenshotError,
            observeError: observation.observeError,
            fallbackRecommended: observation.fallbackRecommended,
            fallbackReason: observation.fallbackReason,
            session: context
        )
    }

    private func refinedFallbackReason(_ reason: String?, screenshotError: String?) -> String? {
        guard let reason, let screenshotError else {
            return reason
        }
        guard reason.contains("screenshot_capture_failed") else {
            return reason
        }
        switch screenshotError {
        case "screenshot_persistence_disabled", "screenshot_redaction_enabled":
            return reason.replacingOccurrences(of: "screenshot_capture_failed", with: screenshotError)
        default:
            return reason
        }
    }

    private func reindexPlannedActions(_ actions: [PlannedComputerAction], offset: Int) -> [PlannedComputerAction] {
        actions.enumerated().map { localIndex, planned in
            PlannedComputerAction(
                index: offset + localIndex,
                action: planned.action,
                rationale: planned.rationale
            )
        }
    }

    private func planDeterministicActions(
        for request: ComputerUseRequest,
        observation: Observation,
        completedActionTypes: [String] = []
    ) -> [PlannedComputerAction] {
        let task = normalizedTask(request.task)

        if task.isEmpty || containsAny(task, ["inspect", "observe", "look", "查看", "观察", "看看"]) {
            return []
        }

        if let scrollText = extractedText(after: ["scroll until", "find text", "scroll to", "找到", "滚动到"], in: request.task) {
            guard !completedActionTypes.contains("scroll_until_text_visible") else {
                return []
            }
            return [
                PlannedComputerAction(
                    index: 0,
                    action: makeAction(
                        type: "scroll_until_text_visible",
                        text: scrollText,
                        direction: "down",
                        amount: 5,
                        ms: 140,
                        retryCount: 7
                    ),
                    rationale: "The task asks to find visible text, so use OCR-guided scrolling before any click."
                ),
            ]
        }

        if containsAny(task, ["search", "搜索"]) {
            if !completedActionTypes.contains("replace_text") {
                guard let query = searchQuery(from: request.task),
                      let target = bestTextInput(for: "search", observation: observation)
                else {
                    return []
                }
                return [
                    PlannedComputerAction(
                        index: 0,
                        action: makeAction(
                            type: "replace_text",
                            id: target.id,
                            text: query,
                            ms: 180,
                            retryCount: 1
                        ),
                        rationale: "Stage the search query in the most likely search input before submitting."
                    ),
                ]
            }
            if !completedActionTypes.contains("submit") {
                let profile = appProfiles.profile(for: observation.activeApp)
                return [
                    PlannedComputerAction(
                        index: 0,
                        action: makeAction(
                            type: "submit",
                            strategy: profile.searchSubmitStrategy,
                            ms: 180,
                            retryCount: 1
                        ),
                        rationale: "Submit the staged search query after the input step was verified using the \(profile.id) app profile."
                    ),
                ]
            }
            return []
        }

        if containsAny(task, ["type", "enter text", "input", "输入"]) {
            guard !completedActionTypes.contains("replace_text") else {
                return []
            }
            guard let text = extractedText(after: ["type", "enter text", "input", "输入"], in: request.task),
                  let target = bestTextInput(for: nil, observation: observation)
            else {
                return []
            }
            return [
                PlannedComputerAction(
                    index: 0,
                    action: makeAction(
                        type: "replace_text",
                        id: target.id,
                        text: text,
                        ms: 180,
                        retryCount: 1
                    ),
                    rationale: "Stage requested text into the most likely focused or visible input without submitting it."
                ),
            ]
        }

        if containsAny(task, ["click", "press", "select", "choose", "点击", "按下", "选择"]) {
            guard !completedActionTypes.contains("press") && !completedActionTypes.contains("select") else {
                return []
            }
            guard let label = extractedText(after: ["click", "press", "select", "choose", "点击", "按下", "选择"], in: request.task),
                  let target = bestPressableTarget(matching: label, observation: observation)
            else {
                return []
            }
            let actionType = containsAny(task, ["select", "choose", "选择"]) ? "select" : "press"
            return [
                PlannedComputerAction(
                    index: 0,
                    action: makeAction(
                        type: actionType,
                        id: target.id
                    ),
                    rationale: "The task names a visible pressable target that matched a recommended AX target."
                ),
            ]
        }

        if containsAny(task, ["scroll down", "向下滚动"]) {
            return [
                PlannedComputerAction(
                    index: 0,
                    action: makeAction(type: "scroll", direction: "down", amount: 4, ms: 140),
                    rationale: "The task asks for a low-risk scroll gesture."
                ),
            ]
        }

        if containsAny(task, ["scroll up", "向上滚动"]) {
            return [
                PlannedComputerAction(
                    index: 0,
                    action: makeAction(type: "scroll", direction: "up", amount: 4, ms: 140),
                    rationale: "The task asks for a low-risk scroll gesture."
                ),
            ]
        }

        return []
    }

    private func assessRisk(
        request: ComputerUseRequest,
        observation: Observation,
        plannedActions: [PlannedComputerAction]
    ) -> ComputerUseRisk {
        let task = normalizedTask(request.task)
        var reasons: [String] = []
        var level = "low"

        if targetAppLooksSensitive(request.targetApp) {
            reasons.append("sensitive_target_app")
            level = "high"
        }
        let profile = appProfiles.profile(for: observation.activeApp)
        if profile.sensitive {
            reasons.append("sensitive_app_profile")
            level = maxRisk(level, "high")
        }

        if containsAny(task, [
            "send", "message", "reply", "post", "publish", "submit", "delete", "remove", "erase",
            "pay", "purchase", "buy", "password", "credential", "terminal", "shell", "install",
            "settings", "system", "发送", "消息", "回复", "发布", "提交", "删除", "支付", "购买", "密码", "终端", "安装", "设置",
        ]) {
            reasons.append("sensitive_task_intent")
            level = maxRisk(level, "high")
        }

        let dangerousIds = Set(observation.uiSummary.dangerousActions)
        for planned in plannedActions {
            let action = planned.action
            if ["submit", "compose_and_submit"].contains(action.type) {
                if action.type == "submit", containsAny(task, ["search", "搜索"]) {
                    reasons.append("search_submit")
                } else {
                    reasons.append("submits_or_sends_text")
                    level = maxRisk(level, "medium")
                }
            }
            if ["press", "select", "vision_click", "vision_click_text"].contains(action.type),
               let id = action.id,
               dangerousIds.contains(id)
            {
                reasons.append("dangerous_visible_target")
                level = maxRisk(level, "high")
            }
            if action.text != nil && containsAny(task, ["password", "credential", "密码", "凭证"]) {
                reasons.append("credential_text_entry")
                level = maxRisk(level, "high")
            }
        }

        if reasons.isEmpty {
            reasons.append("low_risk_single_step")
        }

        let strict = (request.approvalMode ?? "strict") != "normal"
        let requiresApproval = request.approvalToken?.isEmpty != false &&
            (level == "high" || (strict && level == "medium"))

        return ComputerUseRisk(
            level: level,
            reasons: Array(Set(reasons)).sorted(),
            requiresApproval: requiresApproval,
            approvalTokenRequired: requiresApproval
        )
    }

    private func makeAction(
        type: String,
        id: String? = nil,
        text: String? = nil,
        keys: [String]? = nil,
        strategy: String? = nil,
        direction: String? = nil,
        amount: Double? = nil,
        ms: Double? = nil,
        retryCount: Double? = nil
    ) -> ComputerAction {
        ComputerAction(
            type: type,
            id: id,
            text: text,
            value: nil,
            keys: keys,
            strategy: strategy,
            direction: direction,
            amount: amount,
            ms: ms,
            retryCount: retryCount,
            mark: nil,
            x: nil,
            y: nil,
            x2: nil,
            y2: nil,
            reason: nil
        )
    }

    private func bestTextInput(for intent: String?, observation: Observation) -> RecommendedTarget? {
        let targets = observation.recommendedTargets.filter { $0.kind == "text_input" }
        if let focused = observation.uiSummary.focusedElement,
           let target = targets.first(where: { $0.id == focused })
        {
            return target
        }
        if let intent {
            let normalizedIntent = normalizedTask(intent)
            if let target = targets.first(where: { target in
                normalizedTask([target.name, target.description].compactMap { $0 }.joined(separator: " ")).contains(normalizedIntent)
            }) {
                return target
            }
        }
        return targets.first
    }

    private func bestPressableTarget(matching label: String, observation: Observation) -> RecommendedTarget? {
        let needle = normalizedTask(label)
        guard !needle.isEmpty else {
            return nil
        }
        let candidates = observation.recommendedTargets
            .filter { ["primary_action", "clickable", "dangerous_action"].contains($0.kind) }
            .map { target -> (target: RecommendedTarget, score: Double) in
                let haystack = normalizedTask([target.name, target.description].compactMap { $0 }.joined(separator: " "))
                var score = target.score
                if haystack == needle {
                    score += 100
                } else if haystack.contains(needle) || needle.contains(haystack), !haystack.isEmpty {
                    score += 64
                } else {
                    let tokens = Set(needle.split(separator: " ").map(String.init))
                    let hayTokens = Set(haystack.split(separator: " ").map(String.init))
                    let overlap = tokens.intersection(hayTokens).count
                    score += Double(overlap) * 18
                }
                return (target, score)
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.target.id < rhs.target.id
                }
                return lhs.score > rhs.score
            }
        guard let best = candidates.first, best.score >= 70 else {
            return nil
        }
        return best.target
    }

    private func searchQuery(from raw: String) -> String? {
        if let quoted = firstQuotedText(raw) {
            return quoted
        }
        return extractedText(after: ["search for", "search", "搜索"], in: raw)
    }

    private func extractedText(after markers: [String], in raw: String) -> String? {
        if let quoted = firstQuotedText(raw) {
            return quoted
        }
        let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        let lower = folded.lowercased()
        for marker in markers {
            let normalizedMarker = marker.lowercased()
            if let range = lower.range(of: normalizedMarker) {
                let suffix = folded[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ":：,，.。"))
                if !suffix.isEmpty {
                    return String(suffix.prefix(160))
                }
            }
        }
        return nil
    }

    private func firstQuotedText(_ raw: String) -> String? {
        let pairs: [(Character, Character)] = [
            ("\"", "\""),
            ("'", "'"),
            ("“", "”"),
            ("‘", "’"),
            ("「", "」"),
            ("『", "』"),
        ]
        for (open, close) in pairs {
            guard let start = raw.firstIndex(of: open) else {
                continue
            }
            let afterStart = raw.index(after: start)
            guard let end = raw[afterStart...].firstIndex(of: close) else {
                continue
            }
            let value = raw[afterStart..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func normalizedTask(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { needle in
            haystack.contains(normalizedTask(needle))
        }
    }

    private func targetAppLooksSensitive(_ app: String) -> Bool {
        if appProfiles.profile(for: app).sensitive {
            return true
        }
        return containsAny(normalizedTask(app), [
            "terminal", "iterm", "password", "keychain", "wallet", "settings", "system settings",
            "终端", "钥匙串", "钱包", "设置",
        ])
    }

    private func maxRisk(_ lhs: String, _ rhs: String) -> String {
        let rank = ["low": 0, "medium": 1, "high": 2]
        return (rank[rhs, default: 0] > rank[lhs, default: 0]) ? rhs : lhs
    }

    private func suggestedNextActions(for request: ComputerUseRequest, observation: Observation) -> [String] {
        let task = request.task.lowercased()
        var suggestions: [String] = []

        if let focused = observation.uiSummary.focusedElement {
            suggestions.append("Use focused element \(focused) if it matches the task context.")
        }

        if task.contains("search"),
           let searchTarget = observation.recommendedTargets.first(where: { target in
               target.kind == "text_input" &&
               ([target.name, target.description].compactMap { $0 }.joined(separator: " ").lowercased().contains("search") ||
                observation.uiSummary.textInputs.contains(target.id))
           })
        {
            suggestions.append("Try replace_text on \(searchTarget.id), then submit(strategy:\"auto\").")
        } else if task.contains("send") || task.contains("message") || task.contains("reply") || task.contains("post") {
            if let input = observation.uiSummary.textInputs.first {
                suggestions.append("For message composition, use compose_and_submit on \(input) after approval if the text will be sent externally.")
            }
        } else if let primary = observation.uiSummary.primaryActions.first {
            suggestions.append("Consider press on primary action \(primary) if it advances the task.")
        }

        if observation.fallbackRecommended {
            if observation.overlay != nil {
                suggestions.append("Use overlay.legend marks to choose an AX target before falling back to raw coordinates.")
            } else if observation.screenshot != nil {
                suggestions.append("Use vision_click_text before manual coordinates when AX targets are sparse.")
            }
        }

        if !observation.uiSummary.dangerousActions.isEmpty {
            let dangerous = observation.uiSummary.dangerousActions.joined(separator: ", ")
            suggestions.append("Dangerous actions are visible; require approval before pressing \(dangerous).")
        }

        return Array(suggestions.prefix(6))
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
