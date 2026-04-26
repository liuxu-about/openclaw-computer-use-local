import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(__dirname, "..");
const defaultTasksDir = path.join(__dirname, "tasks");
const baseUrl = (process.env.COMPUTER_USE_BRIDGE_URL || "http://127.0.0.1:4458").replace(/\/$/, "");
const tasksDir = process.env.COMPUTER_USE_EVAL_TASKS_DIR || defaultTasksDir;

async function readTasks() {
  const entries = await fs.readdir(tasksDir, { withFileTypes: true });
  const files = entries
    .filter((entry) => entry.isFile() && entry.name.endsWith(".json"))
    .map((entry) => path.join(tasksDir, entry.name))
    .sort();

  const tasks = [];
  for (const file of files) {
    const payload = JSON.parse(await fs.readFile(file, "utf8"));
    tasks.push({ ...payload, _file: path.relative(projectRoot, file) });
  }
  return tasks;
}

async function bridgeGet(route, params = {}) {
  const url = new URL(`${baseUrl}${route}`);
  for (const [key, value] of Object.entries(params)) {
    if (value != null) {
      url.searchParams.set(key, String(value));
    }
  }
  const response = await fetch(url);
  const text = await response.text();
  const payload = text ? JSON.parse(text) : {};
  if (!response.ok) {
    throw new Error(payload.error || `HTTP ${response.status}`);
  }
  return payload;
}

async function bridgePost(route, payload) {
  const response = await fetch(`${baseUrl}${route}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload ?? {}),
  });
  const text = await response.text();
  const parsed = text ? JSON.parse(text) : {};
  if (!response.ok) {
    throw new Error(parsed.error || `HTTP ${response.status}`);
  }
  return parsed;
}

async function runTask(task) {
  if (task.enabled === false) {
    return { task, status: "skipped", reason: "disabled" };
  }
  if (task.enabled_env && process.env[task.enabled_env] !== "1") {
    return { task, status: "skipped", reason: `set ${task.enabled_env}=1 to run` };
  }

  const startedAt = Date.now();
  let result;
  if (task.endpoint === "health") {
    result = await bridgeGet("/health", task.deep ? { deep: 1 } : {});
  } else if (task.endpoint === "observe") {
    result = await bridgePost("/computer.observe", task.request || {});
  } else if (task.endpoint === "use") {
    result = await bridgePost("/computer.use", task.request || {});
  } else if (task.endpoint === "audit") {
    result = await bridgePost("/computer.audit", task.request || {});
  } else if (task.endpoint === "audit_export") {
    result = await bridgePost("/computer.audit/export", task.request || {});
  } else if (task.endpoint === "cleanup") {
    result = await bridgePost("/computer.cleanup", task.request || {});
  } else {
    throw new Error(`Unsupported eval endpoint: ${task.endpoint}`);
  }

  const checks = evaluateChecks(task.success_checks || [], result);
  const failed = checks.filter((check) => !check.ok);
  return {
    task,
    status: failed.length ? "failed" : "passed",
    duration_ms: Date.now() - startedAt,
    checks,
    result_meta: summarizeResult(result),
  };
}

function evaluateChecks(checks, result) {
  return checks.map((check) => {
    switch (check.type) {
      case "ok":
        return outcome(check, result.ok === true, `ok was ${String(result.ok)}`);
      case "has_audit_records": {
        const count = Array.isArray(result.records) ? result.records.length : 0;
        return outcome(check, count >= Number(check.value || 0), `audit record count ${count}`);
      }
      case "has_readiness":
        return outcome(check, Boolean(result.readiness?.checks), "readiness checks present");
      case "has_audit_export_path":
        return outcome(check, typeof result.export_path === "string" && result.export_path.length > 0, result.export_path || "export_path missing");
      case "has_cleanup_summary":
        return outcome(check, Boolean(result.artifacts?.screenshots) && Boolean(result.audit), "cleanup summary present");
      case "is_dry_run":
        return outcome(check, result.artifacts?.dry_run === true, `dry_run was ${String(result.artifacts?.dry_run)}`);
      case "has_elements_min": {
        const count = result.elements && typeof result.elements === "object" ? Object.keys(result.elements).length : 0;
        return outcome(check, count >= Number(check.value || 1), `element count ${count}`);
      }
      case "has_recommended_targets_min": {
        const count = Array.isArray(result.recommended_targets) ? result.recommended_targets.length : 0;
        return outcome(check, count >= Number(check.value || 1), `recommended target count ${count}`);
      }
      case "has_ui_summary":
        return outcome(check, Boolean(result.ui_summary), "ui_summary present");
      case "has_session_id":
        return outcome(check, typeof result.session_id === "string" && result.session_id.length > 0, result.session_id || "session_id missing");
      case "has_session_context":
        return outcome(check, Boolean(result.session?.session_id), result.session?.session_id || "session context missing");
      case "has_scene_digest":
        return outcome(check, typeof result.scene_digest === "string" && result.scene_digest.length > 0, result.scene_digest || "scene_digest missing");
      case "has_steps_min": {
        const count = Array.isArray(result.steps) ? result.steps.length : 0;
        return outcome(check, count >= Number(check.value || 1), `step count ${count}`);
      }
      case "has_planned_actions_min": {
        const count = Array.isArray(result.planned_actions) ? result.planned_actions.length : 0;
        return outcome(check, count >= Number(check.value || 1), `planned action count ${count}`);
      }
      case "risk_level_in": {
        const allowed = Array.isArray(check.value) ? check.value : [];
        return outcome(check, allowed.includes(result.risk?.level), `risk level ${result.risk?.level || ""}`);
      }
      case "status_in": {
        const allowed = Array.isArray(check.value) ? check.value : [];
        return outcome(check, allowed.includes(result.status), `status ${result.status || ""}`);
      }
      case "has_overlay":
        return outcome(check, Boolean(result.overlay?.path), result.overlay?.path ? "overlay present" : "overlay missing");
      case "active_app_contains": {
        const haystack = String(result.active_app || "").toLowerCase();
        const needle = String(check.value || "").toLowerCase();
        return outcome(check, haystack.includes(needle), `active_app ${result.active_app || ""}`);
      }
      case "source_in": {
        const allowed = Array.isArray(check.value) ? check.value : [];
        return outcome(check, allowed.includes(result.source), `source ${result.source || ""}`);
      }
      default:
        return outcome(check, false, `unknown check type ${check.type}`);
    }
  });
}

function outcome(check, ok, detail) {
  return {
    type: check.type,
    ok,
    detail,
  };
}

function summarizeResult(result) {
  return {
    ok: result.ok,
    active_app: result.active_app,
    active_window: result.active_window,
    session_id: result.session_id,
    scene_digest: result.scene_digest,
    source: result.source,
    fallback_recommended: result.fallback_recommended,
    fallback_reason: result.fallback_reason,
    element_count: result.elements && typeof result.elements === "object" ? Object.keys(result.elements).length : undefined,
    recommended_target_count: Array.isArray(result.recommended_targets) ? result.recommended_targets.length : undefined,
    step_count: Array.isArray(result.steps) ? result.steps.length : undefined,
    planned_action_count: Array.isArray(result.planned_actions) ? result.planned_actions.length : undefined,
    risk_level: result.risk?.level,
    status: result.status,
    overlay: result.overlay?.path ? true : undefined,
  };
}

function printReport(results) {
  const passed = results.filter((result) => result.status === "passed").length;
  const failed = results.filter((result) => result.status === "failed").length;
  const skipped = results.filter((result) => result.status === "skipped").length;
  const total = results.length;

  console.log(`computer-use evals against ${baseUrl}`);
  console.log(`passed ${passed}/${total}, failed ${failed}, skipped ${skipped}`);
  console.log("");

  for (const result of results) {
    const name = result.task.name || result.task._file;
    if (result.status === "skipped") {
      console.log(`- SKIP ${name}: ${result.reason}`);
      continue;
    }
    const duration = `${result.duration_ms}ms`;
    console.log(`- ${result.status.toUpperCase()} ${name} (${duration})`);
    for (const check of result.checks || []) {
      console.log(`  ${check.ok ? "ok" : "no"} ${check.type}: ${check.detail}`);
    }
  }
}

async function main() {
  const tasks = await readTasks();
  const results = [];
  for (const task of tasks) {
    try {
      results.push(await runTask(task));
    } catch (error) {
      results.push({
        task,
        status: "failed",
        reason: error instanceof Error ? error.message : String(error),
        checks: [],
      });
    }
  }

  printReport(results);
  const reportPath = path.join(__dirname, "report.json");
  await fs.writeFile(reportPath, `${JSON.stringify({
    base_url: baseUrl,
    generated_at: new Date().toISOString(),
    results,
  }, null, 2)}\n`, "utf8");

  if (results.some((result) => result.status === "failed")) {
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.stack || error.message : String(error));
  process.exitCode = 1;
});
