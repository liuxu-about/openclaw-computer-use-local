import { Type, type Static } from "@sinclair/typebox";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { callLocalBridge, errorResult, resolveRuntimeConfig, textResult } from "./runtime.js";

const ObserveParams = Type.Object({
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

const ActionItem = Type.Object({
  type: Type.String(),
  id: Type.Optional(Type.String()),
  text: Type.Optional(Type.String()),
  value: Type.Optional(Type.String()),
  keys: Type.Optional(Type.Array(Type.String())),
  strategy: Type.Optional(Type.String()),
  direction: Type.Optional(Type.String()),
  amount: Type.Optional(Type.Number()),
  ms: Type.Optional(Type.Number()),
  retry_count: Type.Optional(Type.Number()),
  x: Type.Optional(Type.Number()),
  y: Type.Optional(Type.Number()),
  x2: Type.Optional(Type.Number()),
  y2: Type.Optional(Type.Number()),
  reason: Type.Optional(Type.String()),
});

const ActParams = Type.Object({
  observation_id: Type.String(),
  actions: Type.Array(ActionItem),
});
type ActParamsT = Static<typeof ActParams>;

const HighLevelParams = Type.Object({
  task: Type.String(),
  target_app: Type.String(),
  target_window: Type.Optional(Type.String()),
  approval_mode: Type.Optional(Type.Union([Type.Literal("strict"), Type.Literal("normal")])),
  allow_vision_fallback: Type.Optional(Type.Boolean()),
});
type HighLevelParamsT = Static<typeof HighLevelParams>;

const SupportedActionTypes = new Set([
  "press",
  "focus",
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
  return actions.map((action, index) => {
    const type = normalizeActionType(action.type);
    if (!SupportedActionTypes.has(type)) {
      throw new Error(`Unsupported action type at index ${index}: ${action.type}`);
    }

    if (type === "vision_click" && (typeof action.x !== "number" || typeof action.y !== "number")) {
      throw new Error(`vision_click at index ${index} requires numeric x and y coordinates`);
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
    };
  });
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
  },
});
