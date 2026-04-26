import http from "node:http";
import { randomUUID } from "node:crypto";
import {
  approveApprovalRequest,
  createApprovalRequest,
  denyApprovalRequest,
  exportAudit,
  listAudit,
  pruneAudit,
  publicApprovalRequest,
  resolveAuditLogPath,
  resolveApprovalStoreDir,
  validateAndConsumeApprovalToken,
} from "./lib/approval-store.mjs";
import { appendEvent, resolveEventLogPath } from "./lib/event-log.mjs";
import {
  cleanupArtifacts,
  resolveArtifactRootDir,
  retentionConfig,
} from "./lib/retention.mjs";
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

function booleanField(payload, snakeName, camelName) {
  if (typeof payload?.[snakeName] === "boolean") {
    return payload[snakeName];
  }
  if (typeof payload?.[camelName] === "boolean") {
    return payload[camelName];
  }
  return false;
}

function healthReadiness(helperHealth, helperError = null) {
  const checks = [];
  if (helperError) {
    checks.push({
      id: "helper",
      ok: false,
      message: "Swift helper did not respond to deep health.",
      fix: "Run npm run helper:build, then retry /health?deep=1. Check bridge helper command/path if it still fails.",
    });
  } else {
    checks.push({
      id: "helper",
      ok: true,
      message: "Swift helper responded.",
      fix: null,
    });
    checks.push({
      id: "accessibility",
      ok: booleanField(helperHealth, "ax_trusted", "axTrusted"),
      message: "macOS Accessibility permission is required for AX observation and element actions.",
      fix: "Open System Settings -> Privacy & Security -> Accessibility, then enable the terminal/app running the bridge.",
    });
    checks.push({
      id: "screen_recording",
      ok: booleanField(helperHealth, "screen_recording_trusted", "screenRecordingTrusted"),
      message: "macOS Screen Recording permission is required for screenshot, overlay, and OCR fallback.",
      fix: "Open System Settings -> Privacy & Security -> Screen Recording, then enable the terminal/app running the bridge.",
    });
  }

  const suggestions = checks
    .filter((check) => !check.ok && check.fix)
    .map((check) => check.fix);
  return {
    ready: checks.every((check) => check.ok),
    checks,
    suggestions,
  };
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

async function handleComputerUse(req, res) {
  const requestId = randomUUID();
  const startedAt = Date.now();
  try {
    const payload = await readJson(req);
    appendEvent("bridge_request_started", {
      request_id: requestId,
      command: "use",
      method: req.method,
      path: req.url,
      payload,
    });

    const approvalToken = typeof payload.approval_token === "string" ? payload.approval_token.trim() : "";
    if (approvalToken) {
      const validation = validateAndConsumeApprovalToken({
        token: approvalToken,
        payload,
        bridgeRequestId: requestId,
      });
      if (!validation.ok) {
        const responsePayload = {
          ok: false,
          status: "approval_invalid",
          error: validation.error,
          _meta: {
            request_id: requestId,
            command: "use",
            duration_ms: Date.now() - startedAt,
          },
        };
        appendEvent("bridge_request_failed", {
          request_id: requestId,
          command: "use",
          duration_ms: Date.now() - startedAt,
          error: validation.error,
        });
        sendJson(res, 403, responsePayload);
        return;
      }
      appendEvent("bridge_approval_token_accepted", {
        request_id: requestId,
        approval_request_id: validation.approval_request_id,
      });
    }

    const timeoutMs = estimateHelperTimeoutMs("use", payload);
    const result = await invokeHelper("use", payload, { requestId, timeoutMs });
    const responsePayload = {
      ...(result && typeof result === "object" && !Array.isArray(result) ? result : { result }),
      _meta: {
        request_id: requestId,
        command: "use",
        duration_ms: Date.now() - startedAt,
      },
    };

    if (
      responsePayload?.status === "approval_required" &&
      responsePayload?.risk?.requires_approval &&
      !approvalToken
    ) {
      const approvalRequest = createApprovalRequest({
        bridgeRequestId: requestId,
        payload,
        helperResult: responsePayload,
      });
      responsePayload.approval_request = publicApprovalRequest(approvalRequest);
    }

    appendEvent("bridge_request_succeeded", {
      request_id: requestId,
      command: "use",
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
        command: "use",
        duration_ms: Date.now() - startedAt,
      },
    };
    appendEvent("bridge_request_failed", {
      request_id: requestId,
      command: "use",
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
          audit_log: resolveAuditLogPath(),
          approval_store: resolveApprovalStoreDir(),
          artifact_root: resolveArtifactRootDir(),
          retention: retentionConfig(),
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
          readiness: healthReadiness(health),
          bridge: {
            host,
            port,
            event_log: resolveEventLogPath(),
            audit_log: resolveAuditLogPath(),
            approval_store: resolveApprovalStoreDir(),
            artifact_root: resolveArtifactRootDir(),
            retention: retentionConfig(),
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
          readiness: healthReadiness(null, error),
          bridge: {
            host,
            port,
            event_log: resolveEventLogPath(),
            audit_log: resolveAuditLogPath(),
            approval_store: resolveApprovalStoreDir(),
            artifact_root: resolveArtifactRootDir(),
            retention: retentionConfig(),
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
      await handleComputerUse(req, res);
      return;
    }
    if (req.method === "POST" && url.pathname === "/computer.approval/approve") {
      const payload = await readJson(req);
      const result = approveApprovalRequest({
        approvalRequestId: payload.approval_request_id,
        approvedBy: payload.approved_by,
        ttlMs: payload.ttl_ms,
      });
      sendJson(res, 200, result);
      return;
    }
    if (req.method === "POST" && url.pathname === "/computer.approval/deny") {
      const payload = await readJson(req);
      const result = denyApprovalRequest({
        approvalRequestId: payload.approval_request_id,
        deniedBy: payload.denied_by,
        reason: payload.reason,
      });
      sendJson(res, 200, result);
      return;
    }
    if (req.method === "GET" && url.pathname === "/computer.audit") {
      sendJson(res, 200, {
        ok: true,
        audit_log: resolveAuditLogPath(),
        records: listAudit({ limit: url.searchParams.get("limit") || 50 }),
      });
      return;
    }
    if (req.method === "POST" && url.pathname === "/computer.audit") {
      const payload = await readJson(req);
      sendJson(res, 200, {
        ok: true,
        audit_log: resolveAuditLogPath(),
        records: listAudit({ limit: payload.limit || 50 }),
      });
      return;
    }
    if (req.method === "POST" && url.pathname === "/computer.audit/export") {
      const payload = await readJson(req);
      const result = exportAudit({ limit: payload.limit || 500 });
      appendEvent("bridge_audit_exported", result);
      sendJson(res, 200, result);
      return;
    }
    if (req.method === "POST" && url.pathname === "/computer.cleanup") {
      const payload = await readJson(req);
      const artifacts = cleanupArtifacts(payload);
      const audit = pruneAudit({
        retentionDays: payload.audit_retention_days,
        dryRun: payload.dry_run,
      });
      const result = {
        ok: true,
        artifacts,
        audit,
      };
      appendEvent("bridge_cleanup", result);
      sendJson(res, 200, result);
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
