import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const defaultArtifactRoot = path.join(os.tmpdir(), "openclaw-computer-use-local");

function envNumber(name, fallback = null) {
  const raw = process.env[name];
  if (raw == null || String(raw).trim() === "") {
    return fallback;
  }
  const parsed = Number(raw);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

function envBool(name) {
  const raw = process.env[name];
  if (raw == null) {
    return false;
  }
  return ["1", "true", "yes", "on"].includes(String(raw).trim().toLowerCase());
}

function boundedOptionalNumber(value, fallback = null) {
  if (value == null || value === "") {
    return fallback;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

export function resolveArtifactRootDir() {
  const configured = process.env.COMPUTER_USE_ARTIFACT_ROOT?.trim();
  return configured ? configured : defaultArtifactRoot;
}

export function resolveScreenshotDir() {
  return path.join(resolveArtifactRootDir(), "screenshots");
}

export function resolveOverlayDir() {
  return path.join(resolveArtifactRootDir(), "overlays");
}

export function retentionConfig() {
  return {
    artifact_root: resolveArtifactRootDir(),
    screenshot_dir: resolveScreenshotDir(),
    overlay_dir: resolveOverlayDir(),
    screenshot_ttl_seconds: envNumber("COMPUTER_USE_SCREENSHOT_TTL_SECONDS", null),
    max_screenshots: envNumber("COMPUTER_USE_MAX_SCREENSHOTS", null),
    audit_log_retention_days: envNumber("COMPUTER_USE_AUDIT_LOG_RETENTION_DAYS", null),
    disable_screenshot_persistence: envBool("COMPUTER_USE_DISABLE_SCREENSHOT_PERSISTENCE"),
    redact_screenshots: envBool("COMPUTER_USE_REDACT_SCREENSHOTS"),
  };
}

function listArtifactFiles(directory) {
  if (!fs.existsSync(directory)) {
    return [];
  }

  return fs.readdirSync(directory, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.toLowerCase().endsWith(".png"))
    .map((entry) => {
      const file = path.join(directory, entry.name);
      const stat = fs.statSync(file);
      return {
        file,
        name: entry.name,
        mtime_ms: stat.mtimeMs,
        size_bytes: stat.size,
      };
    });
}

function cleanupDirectory({ directory, label, olderThanSeconds, maxFiles, dryRun, includeFileNames }) {
  const files = listArtifactFiles(directory);
  const deleteSet = new Set();
  const now = Date.now();

  if (Number.isFinite(olderThanSeconds)) {
    const cutoffMs = now - (Math.max(0, olderThanSeconds) * 1000);
    for (const file of files) {
      if (file.mtime_ms < cutoffMs) {
        deleteSet.add(file.file);
      }
    }
  }

  if (Number.isFinite(maxFiles)) {
    const sortedNewestFirst = [...files].sort((lhs, rhs) => rhs.mtime_ms - lhs.mtime_ms);
    for (const file of sortedNewestFirst.slice(Math.max(0, Math.trunc(maxFiles)))) {
      deleteSet.add(file.file);
    }
  }

  let deleted = 0;
  let bytesDeleted = 0;
  const deletedFiles = [];
  for (const file of files) {
    if (!deleteSet.has(file.file)) {
      continue;
    }
    deleted += 1;
    bytesDeleted += file.size_bytes;
    deletedFiles.push(file.name);
    if (!dryRun) {
      try {
        fs.unlinkSync(file.file);
      } catch {
        // Best effort cleanup; stale files may already be gone.
      }
    }
  }

  return {
    label,
    directory,
    scanned: files.length,
    deleted,
    kept: Math.max(0, files.length - deleted),
    bytes_deleted: bytesDeleted,
    dry_run: Boolean(dryRun),
    deleted_files: includeFileNames ? deletedFiles.slice(0, 50) : undefined,
  };
}

export function cleanupArtifacts(options = {}) {
  const config = retentionConfig();
  const dryRun = options.dry_run === true;
  const olderThanSeconds = boundedOptionalNumber(options.older_than_seconds, config.screenshot_ttl_seconds);
  const maxScreenshots = boundedOptionalNumber(options.max_screenshots, config.max_screenshots);
  const includeOverlays = options.include_overlays !== false;
  const includeFileNames = options.include_file_names === true || envBool("COMPUTER_USE_CLEANUP_LIST_FILES");

  const screenshots = cleanupDirectory({
    directory: resolveScreenshotDir(),
    label: "screenshots",
    olderThanSeconds,
    maxFiles: maxScreenshots,
    dryRun,
    includeFileNames,
  });
  const overlays = includeOverlays
    ? cleanupDirectory({
        directory: resolveOverlayDir(),
        label: "overlays",
        olderThanSeconds,
        maxFiles: maxScreenshots,
        dryRun,
        includeFileNames,
      })
    : null;

  return {
    artifact_root: resolveArtifactRootDir(),
    retention: {
      older_than_seconds: olderThanSeconds,
      max_screenshots: maxScreenshots,
      include_overlays: includeOverlays,
      include_file_names: includeFileNames,
    },
    dry_run: dryRun,
    screenshots,
    overlays,
  };
}
