# openclaw-computer-use-local

A local project scaffold for **OpenClaw Computer Use** on macOS.

This project now contains a working **local skeleton** for:
- a native OpenClaw plugin surface
- a local HTTP bridge
- a Swift helper
- an **AX-first, Vision-fallback** execution path

## Included

### Plugin surface
- `computer_use`
- `computer_observe`
- `computer_act`
- `computer_stop`

### Local runtime skeleton
- `bridge/server.mjs` — local HTTP bridge
- `helper-swift/` — Swift native helper
- `skills/computer-use-local/SKILL.md` — OpenClaw skill guidance

## Current behavior

The helper already does these things:
- detects whether Accessibility is trusted
- detects whether screen recording is available
- resolves the target app or frontmost app
- walks the focused window AX subtree with pruning and node caps
- emits element-level ids for useful AX nodes
- supports AX-native `focus`, `press`, `select`, `set_value`, `append_text`, and `scroll-to-visible` when the target app exposes those capabilities
- falls back to synthesized keyboard input for `key`, `set_value`, and `append_text` when AX value-setting is unavailable
- supports low-level keyboard compatibility aliases:
  - `type` -> keyboard text synthesis
  - `keypress` -> keyboard shortcut synthesis
- supports higher-reliability text interaction primitives:
  - `clear_focused_text`
  - `paste_text`
  - `replace_text`
  - `compose_and_submit`
  - `submit`
- waits for text-settle windows before submit and reports when submit did not trigger a verifiable UI transition
- supports `target_window` pinning so observations/actions can stay attached to a specific window title inside multi-window apps
- returns `session_id`, `scene_digest`, and lightweight session history for observe/act/use flows
- bridge-level `/computer.stop` can now terminate an in-flight helper request
- the bridge keeps a warm helper daemon over stdio JSON-RPC instead of cold-spawning the helper for every request
- `/health?deep=1` returns readiness checks and repair suggestions for helper, Accessibility, and Screen Recording issues
- falls back to CGEvent wheel gestures for `scroll`
- captures a screenshot artifact with **ScreenCaptureKit** when `include_screenshot` is true or when mode is `ax_with_screenshot` / `vision`
- persists lightweight observation metadata so later actions can translate screenshot-relative coordinates
- attempts fuzzy remapping from stale element ids using role/label/path/bbox plus semantic fingerprints with ancestor, sibling, descendant-text, and action-signature context
- supports `vision_click(x, y, reason)` using:
  - AX hit-testing first
  - CGEvent left-click fallback second
- supports overlay `mark` targets from annotated screenshots, so actions can reference marks such as `A1`, `T1`, `S1`, or OCR boxes such as `O1`
- supports `vision_click_text(text)` using local OCR over the stored screenshot, then AX/CGEvent click at the matched text location
- supports `vision_drag(x, y, x2, y2, ms?)` through CGEvent drag synthesis
- emits `ui_summary` and `recommended_targets` to make target selection easier for models, including focused element, likely actions, text inputs, scroll regions, dangerous actions, and visible table/list summaries
- emits annotated screenshot overlays with AX/OCR candidate marks when screenshots are available
- adds verification metadata and suggested next actions to action results
- `computer_use` now runs a conservative bounded loop for deterministic low-risk tasks:
  observe, plan, risk-check, act, verify, and re-plan up to `max_steps`
- `computer_use` returns `approval_required` for sensitive intents such as sending, submitting, deleting, credentials, Terminal/shell, payments, installs, or system settings
- the bridge now persists approval requests, issues one-time approval tokens, and records audit events
- event-synthesis actions now guard against frontmost app/window drift before posting keyboard, mouse, drag, paste, or scroll events
- `computer_use` uses initial app profiles for browsers, Finder, Notes, messaging apps, Terminal, System Settings, and credential apps
- action verification can include lightweight visual digest and OCR evidence for text/scroll/submit-style actions
- the bridge can export audit records and clean local screenshot, overlay, and audit artifacts via retention controls
- supports higher-level scrolling helpers:
  - `scroll_to_bottom`
  - `scroll_until_text_visible`
- decides whether vision fallback should be recommended

The helper does **not** yet do these things:
- model-side image grounding from the screenshot itself
- multi-step gesture planning beyond the low-level fallback primitives
- broad app-specific workflow profiles beyond the initial browser/Finder/Notes/messaging/system/credential profiles

## Run locally

### 1. Build the Swift helper

```bash
cd /Users/liuxu/lifeProjects/openclaw-computer-use-local
swift build --package-path ./helper-swift
```

### 2. Start the local bridge

```bash
node ./bridge/server.mjs
```

Or:

```bash
./scripts/run-bridge.sh
```

### 3. Smoke test

```bash
curl http://127.0.0.1:4458/health
curl http://127.0.0.1:4458/health?deep=1
curl -X POST http://127.0.0.1:4458/computer.observe -H 'content-type: application/json' -d '{"target_app":"Safari","mode":"ax_with_screenshot","max_nodes":80,"include_screenshot":true}'
```

For local setup diagnostics:

```bash
npm run doctor
npm run doctor -- --verbose
```

Optional local eval smoke checks:

```bash
npm run eval
COMPUTER_USE_EVAL_SCREENSHOT=1 npm run eval
```

## Screenshot artifacts

Captured screenshots are currently written under the system temp directory, typically:

```text
/var/folders/.../T/openclaw-computer-use-local/screenshots/
```

The observation payload includes:
- `session_id`
- `scene_digest`
- `session.recent_observations`
- `session.recent_actions`
- `screenshot.path`
- `screenshot.capture_kind`
- `screenshot.screen_frame`
- `overlay.path` when an annotated target overlay was generated
- `overlay.legend` with marks such as `A1`, `T1`, `S1`, `D1`, and `O1`

`vision_click` interprets `x` and `y` as **screenshot-relative coordinates** when a stored observation has screenshot metadata.
Element-level actions can use either `id` or an overlay `mark`. For example, `{ "type": "press", "mark": "A1" }`.
`vision_click` can also use an OCR overlay mark such as `{ "type": "vision_click", "mark": "O1" }`.
`vision_click_text` requires that the latest observation included a usable screenshot artifact.
`vision_drag` interprets `x`, `y`, `x2`, and `y2` the same way.

Useful retention and privacy knobs:

```bash
COMPUTER_USE_DISABLE_SCREENSHOT_PERSISTENCE=1
COMPUTER_USE_REDACT_SCREENSHOTS=1
COMPUTER_USE_SCREENSHOT_TTL_SECONDS=3600
COMPUTER_USE_MAX_SCREENSHOTS=50
COMPUTER_USE_AUDIT_LOG_RETENTION_DAYS=14
```

`COMPUTER_USE_DISABLE_SCREENSHOT_PERSISTENCE=1` and `COMPUTER_USE_REDACT_SCREENSHOTS=1` prevent raw screenshot artifacts from being written. Cleanup is also available through `/computer.cleanup` and the `computer_cleanup` tool.

## Logging and timeouts

The bridge and helper write JSONL diagnostics to the system temp directory by default. Sensitive text fields, AX values, task strings, OCR queries, large AX trees, element maps, and local screenshot paths are redacted unless you explicitly set:

```bash
COMPUTER_USE_LOG_FULL_PAYLOADS=1
```

Long-running actions use a bridge-side helper timeout budget derived from the action list. Useful knobs:

```bash
COMPUTER_USE_HELPER_REQUEST_TIMEOUT_MS=60000
COMPUTER_USE_HELPER_MAX_TIMEOUT_MS=180000
COMPUTER_USE_AX_CAPTURE_TIMEOUT_MS=2800
COMPUTER_USE_AX_CAPTURE_CONCURRENCY=1
```

## Recommended text-input pattern

For AX-sparse apps, prefer this flow over raw `key` + immediate Enter:

### Fast path

Use a single transactional action when you already know the target composer:

```json
{
  "type": "compose_and_submit",
  "id": "txt_12",
  "text": "hello",
  "strategy": "auto",
  "ms": 220,
  "retry_count": 1
}
```

`compose_and_submit` internally does:
- focus/prepare the target
- clear residual draft text
- replace with the requested text
- submit with settle + verification
- one repair pass if a residual draft is detected after submit

### Low-level path

If you need debugging visibility, use the explicit sequence:

1. `focus`
2. `clear_focused_text`
3. `replace_text`
4. `submit`

Typical `submit` usage:

```json
{
  "type": "submit",
  "strategy": "enter",
  "ms": 220
}
```

Useful strategies:
- `auto` — try Enter first, then fall back to clicking a likely nearby send/submit button
- `enter`
- `cmd_enter`
- `shift_enter`
- `option_enter`
- `ctrl_enter`
- `click_button`
- `button`

`submit` returns `retryable` when it cannot observe a committed-send transition. When possible, the helper now reports whether a residual draft still appears to be present.


## Hermes integration

This project also includes a local Hermes adaptation through MCP:

- `hermes-mcp/server.py` — FastMCP wrapper around the HTTP bridge
- `scripts/register-hermes-mcp.sh` — registers the wrapper into `~/.hermes/config.yaml`
- `docs/HERMES_INTEGRATION.md` — Hermes-specific setup notes

After the bridge is running, register it with:

```bash
cd /Users/liuxu/lifeProjects/openclaw-computer-use-local
./scripts/register-hermes-mcp.sh
```

Default Hermes tool names (with the default server name) become:
- `mcp_computer_use_local_computer_health`
- `mcp_computer_use_local_computer_observe`
- `mcp_computer_use_local_computer_act`
- `mcp_computer_use_local_computer_stop`
- `mcp_computer_use_local_computer_use`
- `mcp_computer_use_local_computer_approval_approve`
- `mcp_computer_use_local_computer_approval_deny`
- `mcp_computer_use_local_computer_audit`
- `mcp_computer_use_local_computer_audit_export`
- `mcp_computer_use_local_computer_cleanup`

## Project layout

```text
openclaw-computer-use-local/
  bridge/
  docs/
  helper-swift/
  skills/computer-use-local/
  src/
  scripts/
  openclaw.plugin.json
  package.json
```

## Next recommended work

1. add image grounding model loop on top of screenshot artifacts
2. add table/list-specific actions and eval tasks on top of the new visible-structure summaries
3. broaden app profiles and profile-specific eval tasks
4. add retry policy tuning driven by eval metrics
5. add local-only permission/bootstrap checks for the bridge and helper
