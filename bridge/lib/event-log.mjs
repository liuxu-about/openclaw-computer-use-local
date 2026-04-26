import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const defaultLogPath = path.join(os.tmpdir(), "openclaw-computer-use-local-events.jsonl");
const logFullPayloads = process.env.COMPUTER_USE_LOG_FULL_PAYLOADS === "1";
const redactedScalarKeys = new Set([
  "matched_text",
  "approval_token",
  "query",
  "task",
  "text",
  "value",
]);
const redactedContainerKeys = new Set([
  "elements",
  "legend",
  "overlay",
  "recommended_targets",
  "tree",
  "ui_summary",
]);

export function resolveEventLogPath() {
  const configured = process.env.COMPUTER_USE_EVENT_LOG_PATH?.trim();
  return configured ? configured : defaultLogPath;
}

function truncateString(value, limit = 1200) {
  if (typeof value !== "string") {
    return value;
  }
  if (value.length <= limit) {
    return value;
  }
  return `${value.slice(0, limit - 1)}…`;
}

function redactPlaceholder(value, key) {
  if (logFullPayloads) {
    return undefined;
  }

  const normalized = key.toLowerCase();
  if (redactedScalarKeys.has(normalized)) {
    return "[redacted]";
  }
  if (redactedContainerKeys.has(normalized)) {
    if (Array.isArray(value)) {
      return `[redacted:${normalized}:${value.length}]`;
    }
    if (value && typeof value === "object") {
      return `[redacted:${normalized}:${Object.keys(value).length}]`;
    }
    return `[redacted:${normalized}]`;
  }
  if (normalized.endsWith("path") && typeof value === "string" && value.includes("openclaw-computer-use-local")) {
    return "[redacted:path]";
  }
  return undefined;
}

function sanitize(value, depth = 0, key = "") {
  const redacted = redactPlaceholder(value, key);
  if (redacted !== undefined) {
    return redacted;
  }
  if (depth > 4) {
    return "[max-depth]";
  }
  if (value == null) {
    return value;
  }
  if (typeof value === "string") {
    return truncateString(value);
  }
  if (typeof value === "number" || typeof value === "boolean") {
    return value;
  }
  if (value instanceof Error) {
    return {
      name: value.name,
      message: truncateString(value.message),
      stack: truncateString(value.stack ?? "", 2400),
    };
  }
  if (Array.isArray(value)) {
    return value.slice(0, 32).map((item) => sanitize(item, depth + 1, key));
  }
  if (typeof value === "object") {
    const out = {};
    for (const [key, item] of Object.entries(value).slice(0, 64)) {
      if (typeof item === "function" || typeof item === "undefined") {
        continue;
      }
      out[key] = sanitize(item, depth + 1, key);
    }
    return out;
  }
  return truncateString(String(value));
}

export function appendEvent(type, payload = {}) {
  const logPath = resolveEventLogPath();
  const record = sanitize({
    ts: new Date().toISOString(),
    pid: process.pid,
    type,
    ...payload,
  });

  try {
    fs.mkdirSync(path.dirname(logPath), { recursive: true });
    fs.appendFileSync(logPath, `${JSON.stringify(record)}\n`, "utf8");
  } catch {
    // Best effort only.
  }
}
