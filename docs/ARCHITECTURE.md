# Architecture

This project now has a concrete local skeleton for an **AX-first, Vision-fallback** computer-use stack:

```text
OpenClaw agent/plugin tools
  -> local HTTP bridge (Node)
  -> Swift helper CLI
     -> AX subtree snapshot + element ids
     -> AX action executor
     -> ScreenCaptureKit screenshot capture
     -> observation metadata store
     -> stale-id fuzzy remap
     -> vision-click translation (screenshot -> screen)
     -> AX hit-test / CGEvent fallback
     -> keyboard / wheel / drag synthesis
```

## Layers

### 1. Plugin layer
Existing typed tools remain the OpenClaw-facing contract:
- `computer_use`
- `computer_observe`
- `computer_act`
- `computer_stop`

### 2. Local bridge
`bridge/server.mjs`
- exposes HTTP endpoints
- normalizes JSON in/out
- keeps a warm Swift helper daemon over stdio JSON-RPC
- tracks in-flight helper invocations so `/computer.stop` can cancel a running request

### 3. Swift helper
`helper-swift/`
- resolves the target app
- checks Accessibility and screen-recording readiness
- traverses the focused window AX subtree
- can pin observations to a specific window title when `target_window` is supplied
- emits deterministic element ids for useful nodes
- executes AX-native actions when supported by the target element
- captures window/display screenshots through ScreenCaptureKit when requested
- persists lightweight observation metadata for later coordinate translation
- fuzzy-remaps stale element ids against the newest AX snapshot when labels/path/bbox still roughly match
- executes `vision_click` through AX hit-testing first, then CGEvent fallback
- executes `vision_drag` through CGEvent drag synthesis
- executes `key` through CGEvent keyboard synthesis
- exposes higher-level text reliability primitives:
  - `clear_focused_text`
  - `paste_text`
  - `replace_text`
  - `submit`
- applies settle / verify semantics around text submission so `type -> immediate enter` can be replaced with a safer transaction
- falls back to CGEvent wheel gestures for `scroll`
- applies AX-first / vision-fallback heuristics

## What is real already

- target app resolution
- frontmost app info
- focused window title + frame when AX allows it
- subtree walking under the focused window
- element-level ids for useful AX nodes
- AX-native `focus`, `press`, `set_value`, `append_text`, and `scroll` to visible
- CGEvent-backed `key`
- CGEvent-backed `vision_drag`
- CGEvent fallback for `scroll`
- keyboard fallback for `set_value` / `append_text`
- clipboard-backed `paste_text` with clipboard restore
- `replace_text` implemented as clear + paste
- `submit` with strategy selection (`auto`, `enter`, `cmd_enter`, etc.)
- `auto` submit tries Enter first, then falls back to a likely nearby send/submit button
- stronger post-submit verification:
  - focused draft cleared
  - focus moved away from composer
  - scene changed without residual draft
  - composed text reappeared outside the input region
- stale-id fuzzy remap for small label/path/bbox shifts
- ScreenCaptureKit screenshot capture for `ax_with_screenshot` / `vision`
- screenshot-relative -> global coordinate translation for `vision_click`
- AX hit-test + CGEvent left-click fallback
- screenshot-relative -> global coordinate translation for `vision_drag`
- fallback recommendation logic
- end-to-end JSON transport from bridge -> helper -> bridge

## What is still skeletal

- model-side image grounding
- approval and audit layers
- stronger stale-id recovery across larger DOM/UI refreshes
- screenshot/OCR-assisted verification for apps whose committed state stays invisible to AX
- richer long-lived semantic sessions (today the daemon is warm, but task/session state is still lightweight)
