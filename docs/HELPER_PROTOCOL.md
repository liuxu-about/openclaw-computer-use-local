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
- fuzzy stale-id remapping using stored element summaries from the original observation
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

Still TODO:
- model-side image grounding / coordinate proposal
- audit / approval hooks
- screenshot/OCR-assisted verification for apps whose post-submit state is invisible to AX
