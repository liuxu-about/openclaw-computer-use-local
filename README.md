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
- supports AX-native `focus`, `press`, `set_value`, `append_text`, and `scroll-to-visible` when the target app exposes those capabilities
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
- bridge-level `/computer.stop` can now terminate an in-flight helper request
- the bridge keeps a warm helper daemon over stdio JSON-RPC instead of cold-spawning the helper for every request
- falls back to CGEvent wheel gestures for `scroll`
- captures a screenshot artifact with **ScreenCaptureKit** when `include_screenshot` is true or when mode is `ax_with_screenshot` / `vision`
- persists lightweight observation metadata so later actions can translate screenshot-relative coordinates
- attempts fuzzy remapping from stale element ids to the latest matching AX element after small UI refreshes
- supports `vision_click(x, y, reason)` using:
  - AX hit-testing first
  - CGEvent left-click fallback second
- supports `vision_click_text(text)` using local OCR over the stored screenshot, then AX/CGEvent click at the matched text location
- supports `vision_drag(x, y, x2, y2, ms?)` through CGEvent drag synthesis
- supports higher-level scrolling helpers:
  - `scroll_to_bottom`
  - `scroll_until_text_visible`
- decides whether vision fallback should be recommended

The helper does **not** yet do these things:
- model-side image grounding from the screenshot itself
- approval / audit persistence
- multi-step gesture planning beyond the low-level fallback primitives
- true semantic sessions inside the helper (the warm daemon exists now, but app/window/task sessions are still lightweight)

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

## Screenshot artifacts

Captured screenshots are currently written under the system temp directory, typically:

```text
/var/folders/.../T/openclaw-computer-use-local/screenshots/
```

The observation payload includes:
- `screenshot.path`
- `screenshot.capture_kind`
- `screenshot.screen_frame`

`vision_click` interprets `x` and `y` as **screenshot-relative coordinates** when a stored observation has screenshot metadata.
`vision_click_text` requires that the latest observation included a usable screenshot artifact.
`vision_drag` interprets `x`, `y`, `x2`, and `y2` the same way.

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

1. add stronger remap / retry behavior across larger UI refreshes and virtualized lists
2. add image grounding model loop on top of screenshot artifacts
3. add approval routing before sensitive actions
4. add richer AX table/list summarization
5. add optional cleanup / retention controls for raw screenshot artifacts
