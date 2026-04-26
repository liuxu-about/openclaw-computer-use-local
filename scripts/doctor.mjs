#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(__dirname, "..");
const args = new Set(process.argv.slice(2));
const jsonMode = args.has("--json");
const skipBridge = args.has("--skip-bridge");
const requireBridge = args.has("--require-bridge");

function argValue(name, fallback = null) {
  const index = process.argv.indexOf(name);
  if (index >= 0 && process.argv[index + 1]) {
    return process.argv[index + 1];
  }
  return fallback;
}

const bridgeUrl = (argValue("--bridge-url", process.env.COMPUTER_USE_BRIDGE_URL) || "http://127.0.0.1:4458").replace(/\/$/, "");
const helperBinary = process.env.COMPUTER_USE_HELPER_BIN || path.join(projectRoot, "helper-swift", ".build", "debug", "openclaw-computer-helper");
const checks = [];

function addCheck(id, status, message, fix = null, detail = null) {
  checks.push({ id, status, message, fix: fix || null, detail: detail || null });
}

function run(command, args = [], options = {}) {
  return spawnSync(command, args, {
    cwd: projectRoot,
    encoding: "utf8",
    timeout: options.timeoutMs || 30_000,
    env: process.env,
  });
}

function parseJsonFromOutput(text) {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end <= start) {
    throw new Error("No JSON object found in command output.");
  }
  return JSON.parse(text.slice(start, end + 1));
}

function boolField(value, snakeName, camelName) {
  if (typeof value?.[snakeName] === "boolean") {
    return value[snakeName];
  }
  if (typeof value?.[camelName] === "boolean") {
    return value[camelName];
  }
  return false;
}

function checkNode() {
  const major = Number(process.versions.node.split(".")[0]);
  if (Number.isFinite(major) && major >= 18) {
    addCheck("node", "ok", `Node.js ${process.version}`);
  } else {
    addCheck("node", "fail", `Node.js ${process.version} is too old.`, "Use Node.js 18 or newer.");
  }
}

function checkSwift() {
  const result = run("swift", ["--version"], { timeoutMs: 10_000 });
  if (result.status === 0) {
    const firstLine = String(result.stdout || result.stderr).split("\n").find(Boolean) || "Swift available";
    addCheck("swift", "ok", firstLine);
  } else {
    addCheck("swift", "fail", "Swift toolchain is not available.", "Install Xcode Command Line Tools with `xcode-select --install`.");
  }
}

function helperLaunch() {
  if (process.env.COMPUTER_USE_HELPER_BIN) {
    return { command: process.env.COMPUTER_USE_HELPER_BIN, args: [] };
  }
  if (fs.existsSync(helperBinary)) {
    return { command: helperBinary, args: [] };
  }
  return {
    command: "swift",
    args: ["run", "--package-path", path.join(projectRoot, "helper-swift"), "openclaw-computer-helper"],
  };
}

function checkHelperHealth() {
  const launch = helperLaunch();
  if (launch.command === helperBinary) {
    addCheck("helper_binary", "ok", helperBinary);
  } else if (process.env.COMPUTER_USE_HELPER_BIN) {
    addCheck("helper_binary", fs.existsSync(process.env.COMPUTER_USE_HELPER_BIN) ? "ok" : "fail", process.env.COMPUTER_USE_HELPER_BIN, "Set COMPUTER_USE_HELPER_BIN to an existing helper binary.");
  } else {
    addCheck("helper_binary", "warn", "Built helper binary is missing; doctor will use `swift run`.", "Run `npm run helper:build` for faster bridge startup.");
  }

  const result = run(launch.command, [...launch.args, "health"], { timeoutMs: 45_000 });
  if (result.status !== 0) {
    addCheck(
      "helper_health",
      "fail",
      "Swift helper health command failed.",
      "Run `npm run helper:build`, then `npm run helper:health` to inspect the raw error.",
      String(result.stderr || result.stdout).trim().slice(0, 2000),
    );
    return null;
  }

  try {
    const health = parseJsonFromOutput(`${result.stdout}\n${result.stderr}`);
    addCheck("helper_health", "ok", `Helper responded; frontmost app: ${health.frontmost_app || health.frontmostApp || "unknown"}.`);

    const axTrusted = boolField(health, "ax_trusted", "axTrusted");
    addCheck(
      "accessibility",
      axTrusted ? "ok" : "fail",
      axTrusted ? "Accessibility permission is trusted." : "Accessibility permission is not trusted.",
      axTrusted ? null : "Open System Settings -> Privacy & Security -> Accessibility, then enable the terminal/app running the bridge.",
    );

    const screenTrusted = boolField(health, "screen_recording_trusted", "screenRecordingTrusted");
    addCheck(
      "screen_recording",
      screenTrusted ? "ok" : "warn",
      screenTrusted ? "Screen Recording permission is trusted." : "Screen Recording permission is not trusted.",
      screenTrusted ? null : "Open System Settings -> Privacy & Security -> Screen Recording if you want screenshots, overlays, or OCR fallback.",
    );
    return health;
  } catch (error) {
    addCheck("helper_health", "fail", "Helper health returned invalid JSON.", "Run `npm run helper:health` and inspect stdout/stderr.", error.message);
    return null;
  }
}

async function fetchJson(url) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 4000);
  try {
    const response = await fetch(url, { signal: controller.signal });
    const text = await response.text();
    const payload = text ? JSON.parse(text) : {};
    if (!response.ok) {
      throw new Error(payload.error || `HTTP ${response.status}`);
    }
    return payload;
  } finally {
    clearTimeout(timer);
  }
}

async function checkBridge() {
  if (skipBridge) {
    addCheck("bridge", "warn", "Bridge checks skipped by --skip-bridge.");
    return;
  }

  try {
    const health = await fetchJson(`${bridgeUrl}/health`);
    addCheck("bridge", "ok", `Bridge reachable at ${bridgeUrl}; helper daemon running: ${Boolean(health.helper_daemon?.running)}.`);
  } catch (error) {
    addCheck(
      "bridge",
      requireBridge ? "fail" : "warn",
      `Bridge is not reachable at ${bridgeUrl}.`,
      "Start it with `npm run bridge:start` or pass --bridge-url to doctor.",
      error.message,
    );
    return;
  }

  try {
    const deep = await fetchJson(`${bridgeUrl}/health?deep=1`);
    const readiness = deep.readiness;
    if (readiness?.checks) {
      const failed = readiness.checks.filter((check) => !check.ok);
      addCheck(
        "bridge_deep_health",
        failed.length ? "warn" : "ok",
        failed.length ? `Deep health returned ${failed.length} readiness issue(s).` : "Deep health readiness checks passed.",
        failed.map((check) => check.fix).filter(Boolean).join(" "),
      );
    } else {
      addCheck("bridge_deep_health", "warn", "Deep health did not include readiness checks.", "Restart the bridge after pulling/building the latest code.");
    }
  } catch (error) {
    addCheck("bridge_deep_health", "warn", "Bridge deep health failed.", "Restart the bridge and retry `npm run doctor`.", error.message);
  }
}

function printHuman() {
  const icons = { ok: "OK", warn: "WARN", fail: "FAIL" };
  console.log(`computer-use-local doctor (${projectRoot})`);
  console.log("");
  for (const check of checks) {
    console.log(`[${icons[check.status] || check.status}] ${check.id}: ${check.message}`);
    if (check.fix) {
      console.log(`      fix: ${check.fix}`);
    }
    if (check.detail && args.has("--verbose")) {
      console.log(`      detail: ${check.detail}`);
    }
  }

  const failures = checks.filter((check) => check.status === "fail").length;
  const warnings = checks.filter((check) => check.status === "warn").length;
  console.log("");
  console.log(`summary: ${checks.length - failures - warnings} ok, ${warnings} warning(s), ${failures} failure(s)`);
}

async function main() {
  checkNode();
  checkSwift();
  checkHelperHealth();
  await checkBridge();

  const failures = checks.filter((check) => check.status === "fail");
  if (jsonMode) {
    console.log(JSON.stringify({
      ok: failures.length === 0,
      project_root: projectRoot,
      bridge_url: bridgeUrl,
      checks,
    }, null, 2));
  } else {
    printHuman();
  }
  process.exitCode = failures.length ? 1 : 0;
}

main().catch((error) => {
  if (jsonMode) {
    console.log(JSON.stringify({ ok: false, error: error.message, checks }, null, 2));
  } else {
    console.error(error.stack || error.message);
  }
  process.exitCode = 1;
});
