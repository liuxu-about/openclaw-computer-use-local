# Local bridge API (v0)

The local bridge is a small HTTP service intended to sit between OpenClaw tools and the native helper.

## Health

### `GET /health`
Returns bridge status and the helper launch configuration.
Also includes `active_invocations`, describing any helper requests that are currently in flight.
Also includes `helper_daemon`, describing the warm stdio RPC helper process when it is running.

### `GET /health?deep=1`
Invokes the helper and returns runtime readiness:
- Accessibility trust
- screen-recording trust
- frontmost app identity

The deep response also includes bridge metadata and `active_invocations`.

## Endpoints

### `POST /computer.observe`
Request:
- `target_app?`
- `target_window?`
- `mode?`: `ax | ax_with_screenshot | vision`
- `max_nodes?`
- `include_screenshot?`

Response:
- `observation_id`
- `source`
- `active_app`
- `active_window`
- `screen`
- `tree`
- `elements`
- `screenshot?`
  - `path`
  - `mime_type`
  - `width`
  - `height`
  - `capture_kind`
  - `screen_frame` — global screen-space frame of the captured window/display
  - `created_at`
- `screenshot_error?`
- `fallback_recommended`
- `fallback_reason?`

### `POST /computer.act`
Request:
- `observation_id`
- `actions[]`

Supported action shapes include:
- `{ "type": "press", "id": "..." }`
- `{ "type": "focus", "id": "..." }`
- `{ "type": "set_value", "id": "...", "text": "..." }`
- `{ "type": "append_text", "id": "...", "text": "..." }`
- `{ "type": "clear_focused_text", "id": "..." }`
- `{ "type": "paste_text", "id": "...", "text": "..." }`
- `{ "type": "replace_text", "id": "...", "text": "..." }`
- `{ "type": "compose_and_submit", "id": "...", "text": "hello", "strategy": "auto", "ms": 220, "retry_count": 1 }`
- `{ "type": "submit", "strategy": "enter", "ms": 220 }`
- `{ "type": "submit", "strategy": "cmd_enter", "retry_count": 1 }`
- `{ "type": "submit", "strategy": "auto", "retry_count": 1 }`
- `{ "type": "submit", "strategy": "click_button" }`
- `{ "type": "key", "keys": ["cmd", "l"] }`
- `{ "type": "key", "text": "hello" }`
- `{ "type": "type", "text": "hello" }`
- `{ "type": "keypress", "keys": ["cmd", "l"] }`
- `{ "type": "scroll", "id": "...", "direction": "down", "amount": 3 }`
- `{ "type": "scroll_to_bottom", "direction": "down", "retry_count": 7 }`
- `{ "type": "scroll_until_text_visible", "text": "BotFather", "direction": "down", "retry_count": 7 }`
- `{ "type": "scroll", "x": 120, "y": 120, "direction": "down", "amount": 2 }`
- `{ "type": "vision_click", "x": 700, "y": 400, "reason": "..." }`
- `{ "type": "vision_click_text", "text": "BotFather" }`
- `{ "type": "vision_drag", "x": 80, "y": 110, "x2": 140, "y2": 110, "ms": 120 }`

`vision_click` treats `x` and `y` as screenshot-relative coordinates when the referenced observation included screenshot metadata.
`vision_click_text` runs local OCR against the referenced observation screenshot, finds the best matching text box, and clicks its center via the same vision-click path.
`vision_drag` treats `x`, `y`, `x2`, and `y2` the same way.
`scroll` first tries AX-native scroll-to-visible when an element id resolves; otherwise it falls back to a CGEvent wheel gesture around the target element, the supplied coordinates, or the target window center.
`scroll_to_bottom` sends repeated scroll gestures until the scene stops changing or a max-step budget is reached.
`scroll_until_text_visible` uses live OCR over the current window while scrolling until the requested text becomes visible.
`clear_focused_text`, `paste_text`, and `replace_text` can operate on the current focused element when `id` is omitted.
`compose_and_submit` is a higher-level text transaction that stages the text, submits it, verifies the UI transition, and performs one residual-draft repair pass before giving up.
`submit` waits before and after the key combo, then checks for a post-submit state change.
- `auto` tries Enter first, then falls back to pressing a likely nearby send/submit button.
- If the helper still sees the draft text in the input region, it reports that as residual-draft evidence.
- If no observable committed-send change appears, it returns `retryable` instead of claiming success.

Response:
- `ok`
- `results[]`
- `next_observation?`

When an action references an old `element_id` that no longer exists in the latest AX snapshot, the helper may fuzzy-remap it to a new id if the role, label, path, and bounding box still closely match. In that case:
- `results[i].id` becomes the resolved id
- `results[i].message` is prefixed with the remap note

Recommended text pattern for AX-sparse chat / compose surfaces:

1. Prefer `compose_and_submit` when you already know the target compose field.
2. Otherwise use the explicit sequence:
   - `focus`
   - `clear_focused_text`
   - `replace_text`
   - `submit`

### `POST /computer.stop`
Request: `{}`

Response:
- `ok`
- `stopped`
- `count`
- `request_ids[]`
- `message`

This endpoint now terminates active helper subprocesses, so it can interrupt a long-running `observe` / `act` / `use` request even though the helper is still request-scoped.
When using the warm helper daemon, stopping active work also recycles that daemon; the next request will automatically spawn a fresh one.

### `POST /computer.use`
Request:
- `task`
- `target_app`
- `approval_mode?`
- `allow_vision_fallback?`
- `target_window?` — optional window-title hint for multi-window apps

Response:
- `ok`
- `status`
- `mode`
- `task`
- `target_app`
- `observation`
- `notes[]`
