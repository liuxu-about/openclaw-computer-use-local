# Hermes integration

This project can be exposed to a local Hermes agent through a small stdio MCP wrapper.

## Files

- `hermes-mcp/server.py` — FastMCP wrapper around the local bridge
- `scripts/register-hermes-mcp.sh` — convenience script to register/re-register the MCP server in `~/.hermes/config.yaml`

## Tool names inside Hermes

When registered under the default server name `computer_use_local`, Hermes exposes:

- `mcp_computer_use_local_computer_health`
- `mcp_computer_use_local_computer_observe`
- `mcp_computer_use_local_computer_act`
- `mcp_computer_use_local_computer_stop`
- `mcp_computer_use_local_computer_use`

## Register

```bash
cd /Users/liuxu/lifeProjects/openclaw-computer-use-local
./scripts/register-hermes-mcp.sh
```

This uses the local Hermes venv Python and points the wrapper at:

- `http://127.0.0.1:4458`

If your bridge is elsewhere:

```bash
COMPUTER_USE_BRIDGE_URL=http://127.0.0.1:4460 ./scripts/register-hermes-mcp.sh
```

## Smoke test

```bash
~/.hermes/hermes-agent-upgrade-v2026.4.16/venv/bin/hermes mcp test computer_use_local
~/.hermes/hermes-agent-upgrade-v2026.4.16/venv/bin/hermes mcp list
```

Then in Hermes:

- run `/reload-mcp` in an active session, or
- start a new `hermes chat` session

## Usage guidance

Recommended low-level flow:

1. `mcp_computer_use_local_computer_observe`
2. `mcp_computer_use_local_computer_act`

Prefer element ids or overlay marks from observe results. Use coordinate-based `vision_click` / `vision_drag` only when AX is sparse and screenshot metadata is present.

## Troubleshooting notes

### `screenshot.path` is missing even though screenshot capture was requested

This is usually **not** a bridge serialization bug.

Actual response path:

1. `ComputerUseEngine.observe()` captures AX state first.
2. It then calls `ScreenshotService.captureIfRequested()`.
3. The helper sets `Observation.screenshot` from `screenshot.artifact`.
4. The bridge returns that JSON payload essentially unchanged.

That means:

- if the helper logs `helper_screenshot_capture_succeeded`, the helper result and bridge response should both contain a real `screenshot.path`
- if the helper logs `helper_screenshot_capture_failed`, the helper returns `screenshot_error` and `fallback_recommended: true`, and the `screenshot` object is omitted entirely

In practice, the common failure mode we observed was `ScreenCaptureKit timed out while waiting for a screenshot image.`

So callers should treat **missing `screenshot` / missing `screenshot.path` exactly the same as capture failure**, even when `mode: "ax_with_screenshot"` or `include_screenshot: true` was requested.

### An `observe` call hangs before any screenshot logs appear

If the event log shows:

- `bridge_request_started`
- `helper_daemon_request_started`

but **does not** show any `helper_screenshot_attempt` entry for that request, the helper is stuck **before** the screenshot phase.

Given the current code path, that points to AX target resolution / `AccessibilityService.captureScene(...)`, not bridge response handling and not `ScreenshotService` serialization.

This is the pattern we saw with Finder: the request hung, no screenshot-attempt events were emitted, and clearing the helper with `computer.stop` recovered the bridge.

### Quick log signatures

- `helper_screenshot_capture_succeeded` → expect `screenshot.path`
- `helper_screenshot_capture_failed` + `screenshot_error` → screenshot missing by design; do not attempt vision-grounded actions
- no `helper_screenshot_attempt` for a hung request → suspect AX capture/scene traversal before screenshot capture
