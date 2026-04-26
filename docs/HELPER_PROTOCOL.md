# Swift helper protocol

The local bridge invokes the Swift helper as a CLI process.

## Commands

- `openclaw-computer-helper health`
- `openclaw-computer-helper observe`
- `openclaw-computer-helper act`
- `openclaw-computer-helper stop`
- `openclaw-computer-helper use`

For every command except `health` and `stop`, the bridge writes a JSON payload to stdin.
The helper writes a JSON payload to stdout.

## Current status

This protocol currently implements:

- frontmost / target app resolution
- AX trust detection
- screen-recording trust detection
- focused-window AX subtree capture
- element-level ids for useful nodes
- AX-native actions for:
  - `focus`
  - `press`
  - `select`
  - `set_value`
  - `append_text`
  - `scroll` (mapped to `AXScrollToVisible` when available)
- CGEvent keyboard synthesis for:
  - `key`
  - `type`
  - `keypress`
  - `set_value` / `append_text` fallback when AXValue is unavailable
- clipboard-backed text primitives for:
  - `clear_focused_text`
  - `paste_text`
  - `replace_text`
  - `submit`
- `submit` auto mode can press a likely nearby send/submit button when Enter-based submission leaves a residual draft
- CGEvent wheel fallback for `scroll`
- ScreenCaptureKit screenshot capture for:
  - `include_screenshot: true`
  - `mode: ax_with_screenshot`
  - `mode: vision`
- observation persistence for screenshot-relative coordinate translation
- lightweight session history with `session_id`, recent observation refs, recent action refs, and scene digests
- fuzzy stale-id remapping using stored element summaries and semantic fingerprints from the original observation
- `vision_click` execution with:
  - AX hit-test + `AXPress` when available
  - CGEvent left-click fallback when AX press is unavailable
- `vision_drag` execution through screenshot-relative coordinate translation + CGEvent drag synthesis
- stronger submit verification via:
  - focused-value deltas
  - focused-target deltas
  - scene-digest deltas
  - residual-draft detection
  - sent-text appearance outside the input region
- vision-fallback recommendation logic
- `ui_summary` / `recommended_targets` observation summaries, including table/list visible-structure summaries
- annotated screenshot overlays for AX and OCR candidates
- overlay mark resolution for low-level actions, including AX marks such as `A1` and OCR marks such as `O1`
- action-level verification metadata and suggested next actions
- conservative bounded `computer_use` loop for low-risk deterministic tasks
- risk assessment with approval-required status for sensitive intents
- bridge-level approval requests, one-time approval tokens, and audit records
- frontmost app/window guard before CGEvent-backed keyboard, mouse, drag, paste, and scroll actions
- app profiles for submit/search strategy and sensitive-app classification
- screenshot/OCR-assisted action verification via visual digests and targeted OCR evidence
- screenshot persistence opt-out with `COMPUTER_USE_DISABLE_SCREENSHOT_PERSISTENCE=1` or `COMPUTER_USE_REDACT_SCREENSHOTS=1`

Still TODO:
- model-side image grounding / coordinate proposal beyond overlay labels
- broader app profile coverage and profile-specific eval tasks
