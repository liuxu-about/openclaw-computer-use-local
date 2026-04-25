export type RuntimeConfig = {
  baseUrl?: string;
  timeoutMs: number;
  approvalMode: "strict" | "normal";
  allowVisionFallback: boolean;
  includeScreenshotByDefault: boolean;
};

export type ToolReturn = {
  content: Array<{ type: "text"; text: string }>;
  details?: Record<string, unknown>;
};

export function resolveRuntimeConfig(raw: unknown): RuntimeConfig {
  const cfg = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  return {
    baseUrl: typeof cfg.baseUrl === "string" && cfg.baseUrl.trim() ? cfg.baseUrl.trim().replace(/\/$/, "") : undefined,
    timeoutMs: typeof cfg.timeoutMs === "number" && Number.isFinite(cfg.timeoutMs) ? Math.max(100, Math.trunc(cfg.timeoutMs)) : 120_000,
    approvalMode: cfg.approvalMode === "normal" ? "normal" : "strict",
    allowVisionFallback: cfg.allowVisionFallback !== false,
    includeScreenshotByDefault: cfg.includeScreenshotByDefault === true,
  };
}

export async function callLocalBridge<T>(config: RuntimeConfig, path: string, payload: unknown): Promise<T> {
  if (!config.baseUrl) {
    throw new Error(
      "computer-use-local is scaffolded but not wired yet. Set plugins.entries.computer-use-local.baseUrl to your local bridge URL first.",
    );
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), config.timeoutMs);

  try {
    const response = await fetch(`${config.baseUrl}${path}`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
      },
      body: JSON.stringify(payload ?? {}),
      signal: controller.signal,
    });

    const text = await response.text();
    const json = text ? (JSON.parse(text) as T) : ({} as T);

    if (!response.ok) {
      throw new Error(`Bridge returned ${response.status}: ${text || response.statusText}`);
    }

    return json;
  } finally {
    clearTimeout(timer);
  }
}

export function textResult(payload: unknown): ToolReturn {
  return {
    content: [
      {
        type: "text",
        text: JSON.stringify(payload, null, 2),
      },
    ],
  };
}

export function errorResult(message: string, details?: Record<string, unknown>): ToolReturn {
  return {
    content: [
      {
        type: "text",
        text: message,
      },
    ],
    details: {
      error: true,
      ...(details ?? {}),
    },
  };
}
