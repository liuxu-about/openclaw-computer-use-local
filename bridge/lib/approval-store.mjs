import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash, randomUUID } from "node:crypto";

const defaultStoreDir = path.join(os.tmpdir(), "openclaw-computer-use-local", "approvals");
const defaultTokenTtlMs = Math.max(30_000, Number(process.env.COMPUTER_USE_APPROVAL_TOKEN_TTL_MS || 5 * 60_000));

export function resolveApprovalStoreDir() {
  const configured = process.env.COMPUTER_USE_APPROVAL_STORE_DIR?.trim();
  return configured ? configured : defaultStoreDir;
}

export function resolveAuditLogPath() {
  return path.join(resolveApprovalStoreDir(), "audit.jsonl");
}

function requestsDir() {
  return path.join(resolveApprovalStoreDir(), "requests");
}

function tokensDir() {
  return path.join(resolveApprovalStoreDir(), "tokens");
}

function exportsDir() {
  return path.join(resolveApprovalStoreDir(), "exports");
}

function ensureStore() {
  fs.mkdirSync(requestsDir(), { recursive: true });
  fs.mkdirSync(tokensDir(), { recursive: true });
}

function nowIso() {
  return new Date().toISOString();
}

function safeName(value) {
  return String(value || "")
    .replace(/[^A-Za-z0-9._-]+/g, "_")
    .slice(0, 180);
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function stableJson(value) {
  if (Array.isArray(value)) {
    return `[${value.map(stableJson).join(",")}]`;
  }
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function payloadFingerprint(payload = {}) {
  return sha256(stableJson({
    session_id: payload.session_id || null,
    task: payload.task || null,
    target_app: payload.target_app || null,
    target_window: payload.target_window || null,
  }));
}

function tokenHash(token) {
  return sha256(`approval-token:${token}`);
}

function requestPath(id) {
  return path.join(requestsDir(), `${safeName(id)}.json`);
}

function tokenPath(hash) {
  return path.join(tokensDir(), `${safeName(hash)}.json`);
}

function writeJson(file, payload) {
  ensureStore();
  fs.writeFileSync(file, `${JSON.stringify(payload, null, 2)}\n`, "utf8");
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function redactAction(action) {
  if (!action || typeof action !== "object") {
    return action;
  }
  const copy = { ...action };
  if ("text" in copy) copy.text = "[redacted]";
  if ("value" in copy) copy.value = "[redacted]";
  return copy;
}

function redactedPayload(payload = {}) {
  return {
    session_id: payload.session_id || null,
    task: payload.task ? String(payload.task).slice(0, 500) : null,
    target_app: payload.target_app || null,
    target_window: payload.target_window || null,
    approval_mode: payload.approval_mode || null,
    allow_vision_fallback: payload.allow_vision_fallback,
    auto_execute: payload.auto_execute,
    max_steps: payload.max_steps,
  };
}

function approvalSummary(payload, helperResult) {
  const risk = helperResult?.risk || {};
  const planned = Array.isArray(helperResult?.planned_actions) ? helperResult.planned_actions : [];
  return {
    summary: `Approval required for ${payload.target_app || "target app"} task.`,
    app: payload.target_app || null,
    window: payload.target_window || helperResult?.observation?.active_window || null,
    task: payload.task || null,
    risk,
    planned_actions: planned.map((item) => ({
      index: item.index,
      rationale: item.rationale,
      action: redactAction(item.action),
    })),
  };
}

export function appendAudit(type, payload = {}) {
  ensureStore();
  const record = {
    ts: nowIso(),
    type,
    ...payload,
  };
  fs.appendFileSync(resolveAuditLogPath(), `${JSON.stringify(record)}\n`, "utf8");
  return record;
}

export function createApprovalRequest({ bridgeRequestId, payload, helperResult }) {
  ensureStore();
  const id = `aprq_${randomUUID()}`;
  const createdAt = nowIso();
  const request = {
    id,
    status: "pending",
    created_at: createdAt,
    updated_at: createdAt,
    bridge_request_id: bridgeRequestId,
    payload_fingerprint: payloadFingerprint(payload),
    payload: redactedPayload(payload),
    summary: approvalSummary(payload, helperResult),
    risk: helperResult?.risk || null,
  };
  writeJson(requestPath(id), request);
  appendAudit("approval_requested", {
    approval_request_id: id,
    bridge_request_id: bridgeRequestId,
    payload: request.payload,
    risk: request.risk,
  });
  return request;
}

export function approveApprovalRequest({ approvalRequestId, approvedBy = "local-user", ttlMs = defaultTokenTtlMs }) {
  ensureStore();
  const request = readJson(requestPath(approvalRequestId));
  if (request.status !== "pending") {
    throw new Error(`Approval request ${approvalRequestId} is ${request.status}, not pending.`);
  }

  const token = `aprt_${randomUUID()}`;
  const hash = tokenHash(token);
  const approvedAt = nowIso();
  const expiresAt = new Date(Date.now() + Math.max(30_000, Number(ttlMs || defaultTokenTtlMs))).toISOString();
  const tokenRecord = {
    token_hash: hash,
    approval_request_id: request.id,
    payload_fingerprint: request.payload_fingerprint,
    approved_by: approvedBy,
    approved_at: approvedAt,
    expires_at: expiresAt,
    consumed_at: null,
  };

  request.status = "approved";
  request.updated_at = approvedAt;
  request.approved_by = approvedBy;
  request.approved_at = approvedAt;
  request.expires_at = expiresAt;
  request.token_hash = hash;

  writeJson(requestPath(request.id), request);
  writeJson(tokenPath(hash), tokenRecord);
  appendAudit("approval_approved", {
    approval_request_id: request.id,
    approved_by: approvedBy,
    expires_at: expiresAt,
  });
  return {
    ok: true,
    approval_token: token,
    expires_at: expiresAt,
    approval_request: publicApprovalRequest(request),
  };
}

export function denyApprovalRequest({ approvalRequestId, deniedBy = "local-user", reason = "" }) {
  ensureStore();
  const request = readJson(requestPath(approvalRequestId));
  if (request.status !== "pending") {
    throw new Error(`Approval request ${approvalRequestId} is ${request.status}, not pending.`);
  }
  const deniedAt = nowIso();
  request.status = "denied";
  request.updated_at = deniedAt;
  request.denied_by = deniedBy;
  request.denied_at = deniedAt;
  request.denial_reason = reason;
  writeJson(requestPath(request.id), request);
  appendAudit("approval_denied", {
    approval_request_id: request.id,
    denied_by: deniedBy,
    reason,
  });
  return {
    ok: true,
    approval_request: publicApprovalRequest(request),
  };
}

export function validateAndConsumeApprovalToken({ token, payload, bridgeRequestId }) {
  ensureStore();
  if (!token || typeof token !== "string") {
    return { ok: false, error: "approval_token is missing." };
  }
  const hash = tokenHash(token);
  const file = tokenPath(hash);
  if (!fs.existsSync(file)) {
    return { ok: false, error: "approval_token is unknown." };
  }

  const record = readJson(file);
  if (record.consumed_at) {
    return { ok: false, error: "approval_token has already been consumed." };
  }
  if (Date.parse(record.expires_at) <= Date.now()) {
    return { ok: false, error: "approval_token has expired." };
  }
  const expected = payloadFingerprint(payload);
  if (record.payload_fingerprint !== expected) {
    return { ok: false, error: "approval_token does not match this task payload." };
  }

  record.consumed_at = nowIso();
  record.consumed_bridge_request_id = bridgeRequestId;
  writeJson(file, record);
  appendAudit("approval_token_consumed", {
    approval_request_id: record.approval_request_id,
    bridge_request_id: bridgeRequestId,
    approved_by: record.approved_by,
  });
  return { ok: true, approval_request_id: record.approval_request_id };
}

export function listAudit({ limit = 50 } = {}) {
  ensureStore();
  const auditPath = resolveAuditLogPath();
  if (!fs.existsSync(auditPath)) {
    return [];
  }
  const lines = fs.readFileSync(auditPath, "utf8")
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
  return lines.slice(-Math.max(1, Math.min(500, Number(limit) || 50))).map((line) => {
    try {
      return JSON.parse(line);
    } catch {
      return { type: "invalid_audit_record", raw: line };
    }
  });
}

export function pruneAudit({ retentionDays = null, dryRun = false } = {}) {
  ensureStore();
  const parsedDays = Number(retentionDays ?? process.env.COMPUTER_USE_AUDIT_LOG_RETENTION_DAYS);
  if (!Number.isFinite(parsedDays) || parsedDays <= 0) {
    return {
      skipped: true,
      reason: "audit_retention_days_not_configured",
      audit_log: resolveAuditLogPath(),
      dry_run: Boolean(dryRun),
    };
  }

  const auditPath = resolveAuditLogPath();
  if (!fs.existsSync(auditPath)) {
    return {
      skipped: false,
      audit_log: auditPath,
      scanned: 0,
      pruned: 0,
      kept: 0,
      dry_run: Boolean(dryRun),
    };
  }

  const cutoff = Date.now() - (parsedDays * 24 * 60 * 60 * 1000);
  const lines = fs.readFileSync(auditPath, "utf8").split("\n").filter(Boolean);
  const kept = [];
  let pruned = 0;
  for (const line of lines) {
    try {
      const record = JSON.parse(line);
      const ts = Date.parse(record.ts);
      if (Number.isFinite(ts) && ts < cutoff) {
        pruned += 1;
        continue;
      }
      kept.push(line);
    } catch {
      kept.push(line);
    }
  }

  if (!dryRun) {
    fs.writeFileSync(auditPath, kept.length ? `${kept.join("\n")}\n` : "", "utf8");
  }

  return {
    skipped: false,
    audit_log: auditPath,
    retention_days: parsedDays,
    scanned: lines.length,
    pruned,
    kept: kept.length,
    dry_run: Boolean(dryRun),
  };
}

export function exportAudit({ limit = 500 } = {}) {
  ensureStore();
  fs.mkdirSync(exportsDir(), { recursive: true });
  const records = listAudit({ limit: Math.max(1, Math.min(5000, Number(limit) || 500)) });
  const exportedAt = nowIso();
  const file = path.join(exportsDir(), `audit-export-${safeName(exportedAt)}.json`);
  fs.writeFileSync(file, `${JSON.stringify({
    exported_at: exportedAt,
    audit_log: resolveAuditLogPath(),
    record_count: records.length,
    records,
  }, null, 2)}\n`, "utf8");
  appendAudit("audit_exported", {
    export_path: file,
    record_count: records.length,
  });
  return {
    ok: true,
    export_path: file,
    exported_at: exportedAt,
    record_count: records.length,
  };
}

export function publicApprovalRequest(request) {
  return {
    id: request.id,
    status: request.status,
    created_at: request.created_at,
    updated_at: request.updated_at,
    expires_at: request.expires_at || null,
    approved_by: request.approved_by || null,
    denied_by: request.denied_by || null,
    summary: request.summary,
    risk: request.risk,
  };
}
