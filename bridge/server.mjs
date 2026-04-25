import http from "node:http";
import { randomUUID } from "node:crypto";
import { appendEvent, resolveEventLogPath } from "./lib/event-log.mjs";
import {
  getActiveHelperInvocations,
  getHelperDaemonStatus,
  invokeHelper,
  resolveHelperLaunch,
  stopActiveHelpers,
} from "./lib/helper-client.mjs";

const host = process.env.COMPUTER_USE_BRIDGE_HOST || "127.0.0.1";
const port = Number(process.env.COMPUTER_USE_BRIDGE_PORT || 4458);
const bodyLimitBytes = Number(process.env.COMPUTER_USE_BRIDGE_MAX_BODY || 1024 * 1024);
const defaultHelperTimeoutMs = positiveNumber(process.env.COMPUTER_USE_HELPER_REQUEST_TIMEOUT_MS, 60_000);
const maxHelperTimeoutMs = positiveNumber(process.env.COMPUTER_USE_HELPER_MAX_TIMEOUT_MS, 180_000);

function positiveNumber(raw, fallback) {
  const parsed = Number(raw);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function boundedTimeoutMs(value) {
  return Math.max(1_000, Math.min(maxHelperTimeoutMs, Math.trunc(value)));
}

function actionBudgetMs(action) {
  if (!action || typeof action !== "object") {
    return 5_000;
  }

  const type = typeof action.type === "string" ? action.type.trim().toLowerCase().replace(/[\s-]+/g, "_") : "";
  const settleMs = positiveNumber(action.ms, 180);
  const retryCount = Math.max(0, Math.min(16, Math.trunc(positiveNumber(action.retry_count, 0))));
  const attempts = retryCount + 1;

  if (type === "wait") {
    return settleMs + 1_000;
  }
  if (type === "scroll_to_bottom" || type === "scroll_until_text_visible") {
    return 8_000 + attempts * (settleMs + 1_200);
  }
  if (type === "compose_and_submit") {
    return 18_000 + attempts * (settleMs + 2_500);
  }
  if (type === "replace_text" || type === "paste_text" || type === "submit") {
    return 10_000 + attempts * (settleMs + 1_800);
  }
  if (type === "vision_click_text") {
    return 12_000 + settleMs;
  }
  if (type.startsWith("vision_")) {
    return 7_000 + settleMs;
  }
  return 6_000 + settleMs;
}

function estimateHelperTimeoutMs(command, payload) {
  if (command === "health") {
    return boundedTimeoutMs(Math.max(defaultHelperTimeoutMs, 15_000));
  }
  if (command === "observe") {
    return boundedTimeoutMs(Math.max(defaultHelperTimeoutMs, 45_000));
  }
  if (command === "use") {
    return boundedTimeoutMs(Math.max(defaultHelperTimeoutMs, 90_000));
  }
  if (command === "act" && Array.isArray(payload?.actions)) {
    const actionBudget = payload.actions.reduce((total, action) => total + actionBudgetMs(action), 12_000);
    return boundedTimeoutMs(Math.max(defaultHelperTimeoutMs, actionBudget));
  }
  return boundedTimeoutMs(defaultHelperTimeoutMs);
}

function sendJson(res, statusCode, payload) {
  const body = JSON.stringify(payload, null, 2);
  res.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
  });
  res.end(body);
}

async function readJson(req) {
  const chunks = [];
  let total = 0;
  for await (const chunk of req) {
    total += chunk.length;
    if (total > bodyLimitBytes) {
      throw new Error(`Request body too large (>${bodyLimitBytes} bytes)`);
    }
    chunks.push(chunk);
  }
  if (!chunks.length) {
    return {};
  }
  const text = Buffer.concat(chunks).toString("utf8").trim();
  if (!text) {
    return {};
  }
  return JSON.parse(text);
}

async function handleHelper(command, req, res) {
  const requestId = randomUUID();
  const startedAt = Date.now();
  try {
    const payload = req.method === "POST" ? await readJson(req) : {};
    appendEvent("bridge_request_started", {
      request_id: requestId,
      command,
      method: req.method,
      path: req.url,
      payload,
    });
    const timeoutMs = estimateHelperTimeoutMs(command, payload);
    const result = await invokeHelper(command, payload, { requestId, timeoutMs });
    const responsePayload = {
      ...(result && typeof result === "object" && !Array.isArray(result) ? result : { result }),
      _meta: {
        request_id: requestId,
        command,
        duration_ms: Date.now() - startedAt,
      },
    };
    appendEvent("bridge_request_succeeded", {
      request_id: requestId,
      command,
      duration_ms: Date.now() - startedAt,
      response: responsePayload,
    });
    sendJson(res, 200, responsePayload);
  } catch (error) {
    const responsePayload = {
      ok: false,
      error: String(error instanceof Error ? error.message : error),
      _meta: {
        request_id: requestId,
        command,
        duration_ms: Date.now() - startedAt,
      },
    };
    appendEvent("bridge_request_failed", {
      request_id: requestId,
      command,
      duration_ms: Date.now() - startedAt,
      error,
    });
    sendJson(res, 500, responsePayload);
  }
}

const server = http.createServer(async (req, res) => {
  try {
    if (!req.url) {
      sendJson(res, 404, { ok: false, error: "Missing URL" });
      return;
    }

    const url = new URL(req.url, `http://${host}:${port}`);

    if (req.method === "GET" && url.pathname === "/health") {
      const deep = url.searchParams.get("deep") === "1";
      if (!deep) {
        sendJson(res, 200, {
          ok: true,
          bridge: "openclaw-computer-use-local",
          host,
          port,
          event_log: resolveEventLogPath(),
          helper: resolveHelperLaunch(),
          helper_daemon: getHelperDaemonStatus(),
          active_invocations: getActiveHelperInvocations(),
        });
        return;
      }
      const requestId = randomUUID();
      const startedAt = Date.now();
      try {
        const health = await invokeHelper("health", {}, { requestId, timeoutMs: estimateHelperTimeoutMs("health", {}) });
        sendJson(res, 200, {
          ...(health && typeof health === "object" && !Array.isArray(health) ? health : { result: health }),
          bridge: {
            host,
            port,
            event_log: resolveEventLogPath(),
            helper: resolveHelperLaunch(),
            helper_daemon: getHelperDaemonStatus(),
            active_invocations: getActiveHelperInvocations(),
          },
          _meta: {
            request_id: requestId,
            command: "health",
            duration_ms: Date.now() - startedAt,
          },
        });
      } catch (error) {
        sendJson(res, 500, {
          ok: false,
          error: String(error instanceof Error ? error.message : error),
          bridge: {
            host,
            port,
            event_log: resolveEventLogPath(),
            helper: resolveHelperLaunch(),
            helper_daemon: getHelperDaemonStatus(),
            active_invocations: getActiveHelperInvocations(),
          },
          _meta: {
            request_id: requestId,
            command: "health",
            duration_ms: Date.now() - startedAt,
          },
        });
      }
      return;
    }

    if (req.method === "POST" && url.pathname === "/computer.observe") {
      await handleHelper("observe", req, res);
      return;
    }
    if (req.method === "POST" && url.pathname === "/computer.act") {
      await handleHelper("act", req, res);
      return;
    }
    if (req.method === "POST" && url.pathname === "/computer.stop") {
      const requestId = randomUUID();
      const startedAt = Date.now();
      const result = await stopActiveHelpers();
      appendEvent("bridge_stop", {
        request_id: requestId,
        command: "stop",
        duration_ms: Date.now() - startedAt,
        result,
      });
      sendJson(res, 200, {
        ok: true,
        ...result,
        _meta: {
          request_id: requestId,
          command: "stop",
          duration_ms: Date.now() - startedAt,
        },
      });
      return;
    }
    if (req.method === "POST" && url.pathname === "/computer.use") {
      await handleHelper("use", req, res);
      return;
    }

    sendJson(res, 404, {
      ok: false,
      error: `No route for ${req.method} ${url.pathname}`,
    });
  } catch (error) {
    sendJson(res, 500, {
      ok: false,
      error: String(error instanceof Error ? error.message : error),
    });
  }
});

server.listen(port, host, () => {
  const helper = resolveHelperLaunch();
  appendEvent("bridge_started", {
    host,
    port,
    helper,
    event_log: resolveEventLogPath(),
  });
  console.log(`[computer-bridge] listening on http://${host}:${port}`);
  console.log(`[computer-bridge] helper command: ${helper.command} ${helper.args.join(" ")}`);
});
