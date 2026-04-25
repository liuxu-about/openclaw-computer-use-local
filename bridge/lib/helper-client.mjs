import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { appendEvent } from "./event-log.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(__dirname, "..", "..");
const activeInvocations = new Map();
let daemonSession = null;
const DEFAULT_REQUEST_TIMEOUT_MS = Number(process.env.COMPUTER_USE_HELPER_REQUEST_TIMEOUT_MS || 60000);

function defaultBuiltBinary() {
  return path.join(projectRoot, "helper-swift", ".build", "debug", "openclaw-computer-helper");
}

export function resolveHelperLaunch() {
  const explicit = process.env.COMPUTER_USE_HELPER_BIN;
  if (explicit) {
    return { command: explicit, args: [] };
  }

  const built = defaultBuiltBinary();
  if (existsSync(built)) {
    return { command: built, args: [] };
  }

  return {
    command: "swift",
    args: ["run", "--package-path", path.join(projectRoot, "helper-swift"), "openclaw-computer-helper"],
  };
}

function resolveServeLaunch() {
  const launch = resolveHelperLaunch();
  return {
    command: launch.command,
    args: [...launch.args, "serve"],
  };
}

function invocationSnapshot(entry) {
  return {
    request_id: entry.requestId,
    command: entry.commandName,
    pid: entry.child.pid ?? null,
    started_at: new Date(entry.startedAt).toISOString(),
    duration_ms: Date.now() - entry.startedAt,
  };
}

export function getActiveHelperInvocations() {
  return [...activeInvocations.values()].map(invocationSnapshot);
}

export function getHelperDaemonStatus() {
  if (!daemonSession || daemonSession.exited) {
    return {
      running: false,
      mode: "stdio_rpc",
    };
  }

  return {
    running: true,
    mode: "stdio_rpc",
    pid: daemonSession.child.pid ?? null,
    started_at: new Date(daemonSession.startedAt).toISOString(),
    uptime_ms: Date.now() - daemonSession.startedAt,
    pending_count: daemonSession.pending.size,
  };
}

function teardownDaemonSession(session, error) {
  if (daemonSession === session) {
    daemonSession = null;
  }
  if (session.exited) {
    return;
  }
  session.exited = true;

  for (const [requestId, pending] of session.pending.entries()) {
    activeInvocations.delete(requestId);
    if (pending.cancelled) {
      pending.reject(new Error(`Helper invocation interrupted by computer.stop (${session.child.signalCode || "terminated"}).`));
    } else {
      pending.reject(error);
    }
  }
  session.pending.clear();
  appendEvent("helper_daemon_stopped", {
    pid: session.child.pid ?? null,
    started_at: new Date(session.startedAt).toISOString(),
    uptime_ms: Date.now() - session.startedAt,
    stderr: session.stderr,
    error,
  });
}

function handleDaemonStdout(session, chunk) {
  session.stdoutBuffer += String(chunk);

  while (true) {
    const newlineIndex = session.stdoutBuffer.indexOf("\n");
    if (newlineIndex < 0) {
      break;
    }

    const rawLine = session.stdoutBuffer.slice(0, newlineIndex);
    session.stdoutBuffer = session.stdoutBuffer.slice(newlineIndex + 1);
    const line = rawLine.trim();
    if (!line) {
      continue;
    }

    let message;
    try {
      message = JSON.parse(line);
    } catch (error) {
      teardownDaemonSession(session, new Error(`Failed to parse helper daemon JSON: ${error instanceof Error ? error.message : String(error)}\nSTDOUT:\n${line}\nSTDERR:\n${session.stderr}`));
      return;
    }

    const pending = session.pending.get(message.id);
    if (!pending) {
      continue;
    }

    session.pending.delete(message.id);
    activeInvocations.delete(message.id);

    if (message.ok) {
      appendEvent("helper_daemon_request_succeeded", {
        request_id: message.id,
        command: pending.commandName,
        pid: session.child.pid ?? null,
        duration_ms: Date.now() - pending.startedAt,
        result: message.result ?? {},
      });
      pending.resolve(message.result ?? {});
    } else {
      appendEvent("helper_daemon_request_failed", {
        request_id: message.id,
        command: pending.commandName,
        pid: session.child.pid ?? null,
        duration_ms: Date.now() - pending.startedAt,
        error: message.error || "Helper daemon returned an unknown error.",
      });
      pending.reject(new Error(message.error || "Helper daemon returned an unknown error."));
    }
  }
}

function startHelperDaemon() {
  if (process.env.COMPUTER_USE_DISABLE_DAEMON === "1") {
    return null;
  }

  if (daemonSession && !daemonSession.exited) {
    return daemonSession;
  }

  const launch = resolveServeLaunch();
  const child = spawn(launch.command, launch.args, {
    cwd: projectRoot,
    env: process.env,
    stdio: ["pipe", "pipe", "pipe"],
  });

  const session = {
    child,
    startedAt: Date.now(),
    stdoutBuffer: "",
    stderr: "",
    pending: new Map(),
    exited: false,
  };
  daemonSession = session;
  appendEvent("helper_daemon_started", {
    pid: child.pid ?? null,
    command: launch.command,
    args: launch.args,
  });

  child.stdout.on("data", (chunk) => {
    handleDaemonStdout(session, chunk);
  });

  child.stderr.on("data", (chunk) => {
    session.stderr = `${session.stderr}${String(chunk)}`.slice(-16_000);
  });

  child.on("error", (error) => {
    teardownDaemonSession(session, error);
  });

  child.on("close", (code, signal) => {
    const detail = signal
      ? `signal ${signal}`
      : `code ${code ?? "unknown"}`;
    teardownDaemonSession(
      session,
      new Error(session.stderr.trim() || `Helper daemon exited with ${detail}.`),
    );
  });

  return session;
}

async function invokeHelperOnce(commandName, payload = {}, options = {}) {
  const timeoutMs = Math.max(1000, Number(options.timeoutMs || DEFAULT_REQUEST_TIMEOUT_MS || 60000));
  const launch = resolveHelperLaunch();
  return await new Promise((resolve, reject) => {
    const child = spawn(launch.command, [...launch.args, commandName], {
      cwd: projectRoot,
      env: process.env,
      stdio: ["pipe", "pipe", "pipe"],
    });

    let settled = false;
    let stdout = "";
    let stderr = "";
    let forceKillHandle = null;

    const settle = (fn, value) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeoutHandle);
      if (forceKillHandle) {
        clearTimeout(forceKillHandle);
      }
      fn(value);
    };

    const timeoutHandle = setTimeout(() => {
      appendEvent("helper_once_timed_out", {
        command: commandName,
        payload,
        timeout_ms: timeoutMs,
        pid: child.pid ?? null,
      });
      try {
        child.kill("SIGTERM");
      } catch {
        // Best effort only.
      }
      forceKillHandle = setTimeout(() => {
        if (child.exitCode == null && child.signalCode == null) {
          try {
            child.kill("SIGKILL");
          } catch {
            // Best effort only.
          }
        }
      }, 750);
      if (typeof forceKillHandle.unref === "function") {
        forceKillHandle.unref();
      }
    }, timeoutMs);
    if (typeof timeoutHandle.unref === "function") {
      timeoutHandle.unref();
    }

    child.stdout.on("data", (chunk) => {
      stdout += String(chunk);
    });

    child.stderr.on("data", (chunk) => {
      stderr += String(chunk);
    });

    child.on("error", (error) => {
      appendEvent("helper_once_failed", {
        command: commandName,
        payload,
        error,
      });
      settle(reject, error);
    });

    child.on("close", (code) => {
      if (code !== 0) {
        appendEvent("helper_once_failed", {
          command: commandName,
          payload,
          code,
          stderr,
        });
        settle(reject, new Error(stderr.trim() || `Helper exited with code ${code}`));
        return;
      }
      try {
        const result = stdout.trim() ? JSON.parse(stdout) : {};
        appendEvent("helper_once_succeeded", {
          command: commandName,
          payload,
          result,
        });
        settle(resolve, result);
      } catch (error) {
        settle(reject, new Error(`Failed to parse helper JSON: ${error instanceof Error ? error.message : String(error)}\nSTDOUT:\n${stdout}\nSTDERR:\n${stderr}`));
      }
    });

    if (commandName !== "health") {
      child.stdin.write(JSON.stringify(payload));
    }
    child.stdin.end();
  });
}

export async function stopActiveHelpers({ signal = "SIGTERM", graceMs = 750 } = {}) {
  const entries = [...activeInvocations.values()];
  if (!entries.length || !daemonSession || daemonSession.exited) {
    appendEvent("helper_stop_noop", {
      signal,
      grace_ms: graceMs,
      active_count: entries.length,
      daemon_running: Boolean(daemonSession && !daemonSession.exited),
    });
    return {
      stopped: false,
      count: 0,
      request_ids: [],
      message: "No active helper invocation is currently running.",
    };
  }

  for (const entry of entries) {
    entry.cancelled = true;
  }
  appendEvent("helper_stop_requested", {
    signal,
    grace_ms: graceMs,
    request_ids: entries.map((entry) => entry.requestId),
    pid: daemonSession.child.pid ?? null,
  });

  const session = daemonSession;
  await Promise.race([
    new Promise((resolve) => {
      session.child.once("close", () => resolve(undefined));
      try {
        session.child.kill(signal);
      } catch {
        resolve(undefined);
      }
    }),
    new Promise((resolve) => {
      setTimeout(() => {
        if (session.child.exitCode == null && session.child.signalCode == null) {
          try {
            session.child.kill("SIGKILL");
          } catch {
            // Best effort only.
          }
        }
        resolve(undefined);
      }, graceMs);
    }),
  ]);

  return {
    stopped: true,
    count: entries.length,
    request_ids: entries.map((entry) => entry.requestId),
    message: `Stopped ${entries.length} active helper invocation(s) and recycled the helper daemon.`,
  };
}

export async function invokeHelper(commandName, payload = {}, options = {}) {
  const requestId = options.requestId || `${commandName}-${Date.now()}`;
  const session = startHelperDaemon();
  const timeoutMs = Math.max(1000, Number(options.timeoutMs || DEFAULT_REQUEST_TIMEOUT_MS || 15000));

  if (!session) {
    appendEvent("helper_invoke_oneshot", {
      request_id: requestId,
      command: commandName,
      payload,
    });
    return invokeHelperOnce(commandName, payload, { timeoutMs });
  }

  return await new Promise((resolve, reject) => {
    let settled = false;
    const entry = {
      requestId,
      commandName,
      child: session.child,
      startedAt: Date.now(),
      cancelled: false,
      resolve: (value) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeoutHandle);
        resolve(value);
      },
      reject: (error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeoutHandle);
        reject(error);
      },
    };

    session.pending.set(requestId, entry);
    activeInvocations.set(requestId, entry);
    appendEvent("helper_daemon_request_started", {
      request_id: requestId,
      command: commandName,
      pid: session.child.pid ?? null,
      payload,
    });

    const timeoutHandle = setTimeout(() => {
      if (!session.pending.has(requestId)) {
        return;
      }
      entry.cancelled = true;
      appendEvent("helper_daemon_request_timed_out", {
        request_id: requestId,
        command: commandName,
        pid: session.child.pid ?? null,
        timeout_ms: timeoutMs,
      });
      try {
        session.child.kill("SIGTERM");
      } catch {
        // Best effort only.
      }
      const forceKill = setTimeout(() => {
        if (session.child.exitCode == null && session.child.signalCode == null) {
          try {
            session.child.kill("SIGKILL");
          } catch {
            // Best effort only.
          }
        }
      }, 750);
      if (typeof forceKill.unref === "function") {
        forceKill.unref();
      }
    }, timeoutMs);
    if (typeof timeoutHandle.unref === "function") {
      timeoutHandle.unref();
    }

    const envelope = JSON.stringify({
      id: requestId,
      command: commandName,
      payload: payload ?? {},
    });

    session.child.stdin.write(`${envelope}\n`, (error) => {
      if (!error) {
        return;
      }
      session.pending.delete(requestId);
      activeInvocations.delete(requestId);
      appendEvent("helper_daemon_request_failed", {
        request_id: requestId,
        command: commandName,
        pid: session.child.pid ?? null,
        error,
      });
      reject(error);
    });
  });
}
