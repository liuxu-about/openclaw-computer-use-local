import { Type, type Static } from "@sinclair/typebox";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { callLocalBridge, errorResult, resolveRuntimeConfig, textResult } from "./runtime.js";

const ObserveParams = Type.Object({
  session_id: Type.Optional(Type.String()),
  target_app: Type.Optional(Type.String()),
  target_window: Type.Optional(Type.String()),
  mode: Type.Optional(Type.Union([
    Type.Literal("ax"),
    Type.Literal("ax_with_screenshot"),
    Type.Literal("vision"),
  ])),
  max_nodes: Type.Optional(Type.Number()),
  include_screenshot: Type.Optional(Type.Boolean()),
});
type ObserveParamsT = Static<typeof ObserveParams>;

function actionType(...values: string[]) {
  return values.length === 1
    ? Type.Literal(values[0])
    : Type.Union(values.map((value) => Type.Literal(value)));
}

const ElementAction = (...types: string[]) => Type.Object({
  type: actionType(...types),
  id: Type.Optional(Type.String()),
  mark: Type.Optional(Type.String()),
});

const TextAction = (...types: string[]) => Type.Object({
  type: actionType(...types),
  id: Type.Optional(Type.String()),
  mark: Type.Optional(Type.String()),
  text: Type.Optional(Type.String()),
  value: Type.Optional(Type.String()),
  ms: Type.Optional(Type.Number()),
  retry_count: Type.Optional(Type.Number()),
});

const SubmitAction = Type.Object({
  type: Type.Literal("submit"),
  id: Type.Optional(Type.String()),
  mark: Type.Optional(Type.String()),
  text: Type.Optional(Type.String()),
  value: Type.Optional(Type.String()),
  keys: Type.Optional(Type.Array(Type.String())),
  strategy: Type.Optional(Type.String()),
  ms: Type.Optional(Type.Number()),
  retry_count: Type.Optional(Type.Number()),
});

const KeyAction = Type.Object({
  type: Type.Union([Type.Literal("key"), Type.Literal("type"), Type.Literal("keypress")]),
  keys: Type.Optional(Type.Array(Type.String())),
  text: Type.Optional(Type.String()),
  value: Type.Optional(Type.String()),
});

const ScrollAction = Type.Object({
  type: Type.Literal("scroll"),
  id: Type.Optional(Type.String()),
  mark: Type.Optional(Type.String()),
  direction: Type.Optional(Type.String()),
  amount: Type.Optional(Type.Number()),
  ms: Type.Optional(Type.Number()),
  x: Type.Optional(Type.Number()),
  y: Type.Optional(Type.Number()),
});

const ScrollToBottomAction = Type.Object({
  type: actionType("scroll_to_bottom", "scroll_bottom", "scroll_to_end"),
  id: Type.Optional(Type.String()),
  mark: Type.Optional(Type.String()),
  direction: Type.Optional(Type.String()),
  amount: Type.Optional(Type.Number()),
  ms: Type.Optional(Type.Number()),
  retry_count: Type.Optional(Type.Number()),
  x: Type.Optional(Type.Number()),
  y: Type.Optional(Type.Number()),
});

const ScrollUntilTextAction = Type.Object({
  type: actionType("scroll_until_text_visible", "scroll_until_text"),
  id: Type.Optional(Type.String()),
  mark: Type.Optional(Type.String()),
  text: Type.Optional(Type.String()),
  value: Type.Optional(Type.String()),
  direction: Type.Optional(Type.String()),
  amount: Type.Optional(Type.Number()),
  ms: Type.Optional(Type.Number()),
  retry_count: Type.Optional(Type.Number()),
  x: Type.Optional(Type.Number()),
  y: Type.Optional(Type.Number()),
});

const VisionClickAction = Type.Object({
  type: actionType("vision_click", "click"),
  mark: Type.Optional(Type.String()),
  x: Type.Optional(Type.Number()),
  y: Type.Optional(Type.Number()),
  reason: Type.Optional(Type.String()),
  ms: Type.Optional(Type.Number()),
});

const VisionClickTextAction = Type.Object({
  type: actionType("vision_click_text", "click_text", "tap_text"),
  text: Type.Optional(Type.String()),
  value: Type.Optional(Type.String()),
  reason: Type.Optional(Type.String()),
  ms: Type.Optional(Type.Number()),
  retry_count: Type.Optional(Type.Number()),
});

const VisionDragAction = Type.Object({
  type: actionType("vision_drag", "drag"),
  x: Type.Number(),
  y: Type.Number(),
  x2: Type.Number(),
  y2: Type.Number(),
  reason: Type.Optional(Type.String()),
  ms: Type.Optional(Type.Number()),
});

const WaitAction = Type.Object({
  type: Type.Literal("wait"),
  ms: Type.Optional(Type.Number()),
  amount: Type.Optional(Type.Number()),
});

const ActionItem = Type.Union([
  ElementAction("press"),
  ElementAction("focus"),
  ElementAction("select", "choose", "pick"),
  TextAction("set_value"),
  TextAction("append_text"),
  TextAction("clear_focused_text"),
  TextAction("paste_text"),
  TextAction("replace_text"),
  TextAction("compose_and_submit", "compose_and_send", "send_message"),
  SubmitAction,
  KeyAction,
  ScrollAction,
  ScrollToBottomAction,
  ScrollUntilTextAction,
  WaitAction,
  VisionClickAction,
  VisionClickTextAction,
  VisionDragAction,
]);

const ActParams = Type.Object({
  session_id: Type.Optional(Type.String()),
  observation_id: Type.String(),
  actions: Type.Array(ActionItem),
});
type ActParamsT = Static<typeof ActParams>;

type NormalizableAction = Record<string, unknown> & {
  type: string;
  strategy?: string;
  direction?: string;
  keys?: string[];
  mark?: string;
  text?: string;
  value?: string;
  x?: number;
  y?: number;
  x2?: number;
  y2?: number;
};

const HighLevelParams = Type.Object({
  session_id: Type.Optional(Type.String()),
  task: Type.String(),
  target_app: Type.String(),
  target_window: Type.Optional(Type.String()),
  approval_mode: Type.Optional(Type.Union([Type.Literal("strict"), Type.Literal("normal")])),
  allow_vision_fallback: Type.Optional(Type.Boolean()),
  auto_execute: Type.Optional(Type.Boolean()),
  max_steps: Type.Optional(Type.Number()),
  approval_token: Type.Optional(Type.String()),
});
type HighLevelParamsT = Static<typeof HighLevelParams>;

const ApprovalApproveParams = Type.Object({
  approval_request_id: Type.String(),
  approved_by: Type.Optional(Type.String()),
  ttl_ms: Type.Optional(Type.Number()),
});
type ApprovalApproveParamsT = Static<typeof ApprovalApproveParams>;

const ApprovalDenyParams = Type.Object({
  approval_request_id: Type.String(),
  denied_by: Type.Optional(Type.String()),
  reason: Type.Optional(Type.String()),
});
type ApprovalDenyParamsT = Static<typeof ApprovalDenyParams>;

const AuditParams = Type.Object({
  limit: Type.Optional(Type.Number()),
});
type AuditParamsT = Static<typeof AuditParams>;

const AuditExportParams = Type.Object({
  limit: Type.Optional(Type.Number()),
});
type AuditExportParamsT = Static<typeof AuditExportParams>;

const CleanupParams = Type.Object({
  dry_run: Type.Optional(Type.Boolean()),
  older_than_seconds: Type.Optional(Type.Number()),
  max_screenshots: Type.Optional(Type.Number()),
  audit_retention_days: Type.Optional(Type.Number()),
  include_overlays: Type.Optional(Type.Boolean()),
  include_file_names: Type.Optional(Type.Boolean()),
});
type CleanupParamsT = Static<typeof CleanupParams>;

const SupportedActionTypes = new Set([
  "press",
  "focus",
  "select",
  "set_value",
  "append_text",
  "clear_focused_text",
  "paste_text",
  "replace_text",
  "compose_and_submit",
  "submit",
  "key",
  "type",
  "keypress",
  "scroll",
  "scroll_to_bottom",
  "scroll_until_text_visible",
  "wait",
  "vision_click",
  "vision_click_text",
  "vision_drag",
]);

function normalizeActionType(raw: string): string {
  const normalized = raw.trim().toLowerCase().replace(/[\s-]+/g, "_");
  switch (normalized) {
    case "click":
      return "vision_click";
    case "click_text":
    case "tap_text":
      return "vision_click_text";
    case "choose":
    case "pick":
      return "select";
    case "scroll_bottom":
    case "scroll_to_end":
      return "scroll_to_bottom";
    case "scroll_until_text":
      return "scroll_until_text_visible";
    case "drag":
      return "vision_drag";
    case "keypress":
      return "key";
    case "compose_and_send":
    case "send_message":
      return "compose_and_submit";
    default:
      return normalized;
  }
}

function normalizeActions(actions: ActParamsT["actions"]): ActParamsT["actions"] {
  return (actions as NormalizableAction[]).map((action, index) => {
    const type = normalizeActionType(action.type);
    if (!SupportedActionTypes.has(type)) {
      throw new Error(`Unsupported action type at index ${index}: ${action.type}`);
    }

    if (["press", "focus", "select"].includes(type) && typeof action.id !== "string" && typeof action.mark !== "string") {
      throw new Error(`${type} at index ${index} requires id or overlay mark`);
    }

    if (type === "vision_click" && typeof action.mark !== "string" && (typeof action.x !== "number" || typeof action.y !== "number")) {
      throw new Error(`vision_click at index ${index} requires numeric x/y coordinates or an overlay mark`);
    }

    if (type === "vision_click_text" && typeof action.text !== "string" && typeof action.value !== "string") {
      throw new Error(`vision_click_text at index ${index} requires text or value`);
    }

    if (type === "scroll_until_text_visible" && typeof action.text !== "string" && typeof action.value !== "string") {
      throw new Error(`scroll_until_text_visible at index ${index} requires text or value`);
    }

    if (
      type === "vision_drag" &&
      (typeof action.x !== "number" ||
        typeof action.y !== "number" ||
        typeof action.x2 !== "number" ||
        typeof action.y2 !== "number")
    ) {
      throw new Error(`vision_drag at index ${index} requires numeric x, y, x2, and y2 coordinates`);
    }

    return {
      ...action,
      type,
      strategy: typeof action.strategy === "string" ? action.strategy.trim().toLowerCase() : action.strategy,
      direction: typeof action.direction === "string" ? action.direction.trim().toLowerCase() : action.direction,
      keys: Array.isArray(action.keys)
        ? action.keys
            .map((key) => key.trim())
            .filter(Boolean)
        : action.keys,
      mark: typeof action.mark === "string" ? action.mark.trim().toUpperCase() : action.mark,
    };
  }) as ActParamsT["actions"];
}

function withDefaults<T extends Record<string, unknown>>(raw: T, pluginConfig: unknown): T {
  const resolved = resolveRuntimeConfig(pluginConfig);
  const copy = { ...raw };
  if (!("include_screenshot" in copy) && resolved.includeScreenshotByDefault) {
    (copy as Record<string, unknown>).include_screenshot = true;
  }
  if (!("approval_mode" in copy)) {
    (copy as Record<string, unknown>).approval_mode = resolved.approvalMode;
  }
  if (!("allow_vision_fallback" in copy)) {
    (copy as Record<string, unknown>).allow_vision_fallback = resolved.allowVisionFallback;
  }
  return copy;
}

export default definePluginEntry({
  id: "computer-use-local",
  name: "Computer Use (Local)",
  description: "Local OpenClaw computer-use bridge for AX-first macOS automation.",
  register(api) {
    api.registerTool(
      {
        name: "computer_observe",
        description: "Observe a local macOS app through the configured computer-use bridge.",
        parameters: ObserveParams,
        async execute(_id: string, params: ObserveParamsT) {
          try {
            const payload = withDefaults({ ...params }, api.pluginConfig);
            const result = await callLocalBridge(resolveRuntimeConfig(api.pluginConfig), "/computer.observe", payload);
            return textResult(result);
          } catch (error) {
            return errorResult(`computer_observe failed: ${(error as Error).message}`);
          }
        },
      },
      { optional: true },
    );

    api.registerTool(
      {
        name: "computer_act",
        description: "Perform element-level local computer-use actions against the configured bridge.",
        parameters: ActParams,
        async execute(_id: string, params: ActParamsT) {
          try {
            const normalizedParams = {
              ...params,
              actions: normalizeActions(params.actions),
            };
            const result = await callLocalBridge(resolveRuntimeConfig(api.pluginConfig), "/computer.act", normalizedParams);
            return textResult(result);
          } catch (error) {
            return errorResult(`computer_act failed: ${(error as Error).message}`);
          }
        },
      },
      { optional: true },
    );

    api.registerTool(
      {
        name: "computer_stop",
        description: "Stop the active local computer-use session.",
        parameters: Type.Object({}),
        async execute() {
          try {
            const result = await callLocalBridge(resolveRuntimeConfig(api.pluginConfig), "/computer.stop", {});
            return textResult(result);
          } catch (error) {
            return errorResult(`computer_stop failed: ${(error as Error).message}`);
          }
        },
      },
      { optional: true },
    );

    api.registerTool(
      {
        name: "computer_use",
        description: "High-level local computer-use task wrapper for the configured bridge.",
        parameters: HighLevelParams,
        async execute(_id: string, params: HighLevelParamsT) {
          try {
            const payload = withDefaults({ ...params }, api.pluginConfig);
            const result = await callLocalBridge(resolveRuntimeConfig(api.pluginConfig), "/computer.use", payload);
            return textResult(result);
          } catch (error) {
            return errorResult(`computer_use failed: ${(error as Error).message}`);
          }
        },
      },
      { optional: true },
    );

    api.registerTool(
      {
        name: "computer_approval_approve",
        description: "Approve a pending local computer-use approval request and return a one-time approval token.",
        parameters: ApprovalApproveParams,
        async execute(_id: string, params: ApprovalApproveParamsT) {
          try {
            const result = await callLocalBridge(
              resolveRuntimeConfig(api.pluginConfig),
              "/computer.approval/approve",
              params,
            );
            return textResult(result);
          } catch (error) {
            return errorResult(`computer_approval_approve failed: ${(error as Error).message}`);
          }
        },
      },
      { optional: true },
    );

    api.registerTool(
      {
        name: "computer_approval_deny",
        description: "Deny a pending local computer-use approval request.",
        parameters: ApprovalDenyParams,
        async execute(_id: string, params: ApprovalDenyParamsT) {
          try {
            const result = await callLocalBridge(
              resolveRuntimeConfig(api.pluginConfig),
              "/computer.approval/deny",
              params,
            );
            return textResult(result);
          } catch (error) {
            return errorResult(`computer_approval_deny failed: ${(error as Error).message}`);
          }
        },
      },
      { optional: true },
    );

    api.registerTool(
      {
        name: "computer_audit",
        description: "Read recent local computer-use audit records.",
        parameters: AuditParams,
        async execute(_id: string, params: AuditParamsT) {
          try {
            const result = await callLocalBridge(resolveRuntimeConfig(api.pluginConfig), "/computer.audit", params);
            return textResult(result);
          } catch (error) {
            return errorResult(`computer_audit failed: ${(error as Error).message}`);
          }
        },
      },
      { optional: true },
    );

    api.registerTool(
      {
        name: "computer_audit_export",
        description: "Export recent local computer-use audit records to a JSON artifact.",
        parameters: AuditExportParams,
        async execute(_id: string, params: AuditExportParamsT) {
          try {
            const result = await callLocalBridge(resolveRuntimeConfig(api.pluginConfig), "/computer.audit/export", params);
            return textResult(result);
          } catch (error) {
            return errorResult(`computer_audit_export failed: ${(error as Error).message}`);
          }
        },
      },
      { optional: true },
    );

    api.registerTool(
      {
        name: "computer_cleanup",
        description: "Clean up local computer-use screenshot, overlay, and audit artifacts according to retention settings.",
        parameters: CleanupParams,
        async execute(_id: string, params: CleanupParamsT) {
          try {
            const result = await callLocalBridge(resolveRuntimeConfig(api.pluginConfig), "/computer.cleanup", params);
            return textResult(result);
          } catch (error) {
            return errorResult(`computer_cleanup failed: ${(error as Error).message}`);
          }
        },
      },
      { optional: true },
    );
  },
});
