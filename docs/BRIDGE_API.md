# Local bridge API (v0)

The local bridge is a small HTTP service intended to sit between OpenClaw tools and the native helper.

## Health

### `GET /health`
Returns bridge status and the helper launch configuration.
Also includes `active_invocations`, describing any helper requests that are currently in flight.
Also includes `helper_daemon`, describing the warm stdio RPC helper process when it is running.
Also includes artifact/retention metadata:
- `artifact_root`
- `retention`

### `GET /health?deep=1`
Invokes the helper and returns runtime readiness:
- Accessibility trust
- screen-recording trust
- frontmost app identity

The deep response also includes bridge metadata and `active_invocations`.
It also includes `readiness`:
- `ready`
- `checks[]`
  - `id`
  - `ok`
  - `message`
  - `fix?`
- `suggestions[]`

## Endpoints

### `POST /computer.observe`
Request:
- `session_id?`
- `target_app?`
- `target_window?`
- `mode?`: `ax | ax_with_screenshot | vision`
- `max_nodes?`
- `include_screenshot?`

Response:
- `observation_id`
- `session_id`
- `scene_digest`
- `source`
- `active_app`
- `active_window`
- `screen`
- `tree`
- `elements`
- `ui_summary`
  - `focused_element`
  - `primary_actions`
  - `text_inputs`
  - `scroll_regions`
  - `dangerous_actions`
  - `tables[]?`
    - `id`
    - `role`
    - `label`
    - `rows_visible?`
    - `columns_visible?`
    - `children_visible`
    - `sample_labels[]`
    - `bbox`
  - `lists[]?`
    - same shape as `tables[]`
  - `visible_element_count`
- `recommended_targets[]`
  - `id`
  - `kind`: `primary_action | clickable | text_input | scroll_region | dangerous_action`
  - `role`
  - `name`
  - `description`
  - `score`
  - `reason`
  - `bbox`
  - `actions`
- `screenshot?`
  - `path`
  - `mime_type`
  - `width`
  - `height`
  - `capture_kind`
  - `screen_frame` — global screen-space frame of the captured window/display
  - `created_at`
- `overlay?`
  - `path`
  - `mime_type`
  - `width`
  - `height`
  - `legend[]` — visual marks for recommended AX targets and OCR boxes
- `screenshot_error?`
- `fallback_recommended`
- `fallback_reason?`
- `session?`
  - `session_id`
  - `observation_count`
  - `action_count`
  - `last_observation_id`
  - `last_scene_digest`
  - `recent_observations[]`
  - `recent_actions[]`

### `POST /computer.act`
Request:
- `session_id?`
- `observation_id`
- `actions[]`

Supported action shapes include:
- `{ "type": "press", "id": "..." }`
- `{ "type": "press", "mark": "A1" }`
- `{ "type": "focus", "id": "..." }`
- `{ "type": "select", "id": "..." }`
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
- `{ "type": "vision_click", "mark": "O1", "reason": "OCR overlay mark from latest observation" }`
- `{ "type": "vision_click_text", "text": "BotFather" }`
- `{ "type": "vision_drag", "x": 80, "y": 110, "x2": 140, "y2": 110, "ms": 120 }`

`vision_click` treats `x` and `y` as screenshot-relative coordinates when the referenced observation included screenshot metadata.
When an observation includes `overlay.legend`, element actions can use `mark` instead of `id`; AX marks resolve to element ids and OCR marks resolve to screenshot-relative bbox centers for `vision_click`.
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
- `session_id`
- `results[]`
  - `retryable`
  - `verification`
    - `verified`
    - `confidence`
    - `evidence[]`
    - `before_digest`
    - `after_digest`
    - `visual_before_digest?`
    - `visual_after_digest?`
    - `ocr_evidence?`
  - `suggested_next_action?`
- `next_observation?`
- `session?`

When an action references an old `element_id` that no longer exists in the latest AX snapshot, the helper may fuzzy-remap it to a new id if the role, label, path, bounding box, and persisted semantic fingerprint still closely match. Fingerprints include ancestor roles, sibling labels, descendant text, action signatures, and a semantic hash. In that case:
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
- `session_id?`
- `task`
- `target_app`
- `approval_mode?`
- `allow_vision_fallback?`
- `target_window?` — optional window-title hint for multi-window apps
- `auto_execute?` — defaults to true for low-risk deterministic plans
- `max_steps?` — bounded by the helper, currently capped at 5 planned action batches
- `approval_token?` — allows a previously approved high/medium-risk plan to proceed

Response:
- `ok`
- `status`
  - `ready_for_actions`
  - `planned`
  - `completed_step`
  - `completed_steps`
  - `completed`
  - `needs_recovery`
  - `needs_grounding`
  - `approval_required`
- `mode`
- `session_id`
- `task`
- `target_app`
- `observation`
- `session?`
- `steps[]`
- `risk`
  - `level`: `low | medium | high`
  - `reasons[]`
  - `requires_approval`
  - `approval_token_required`
- `planned_actions[]`
- `action_response?`
- `action_responses[]`
- `final_observation?`
- `suggested_next_actions[]`
- `notes[]`

`computer_use` now performs a conservative bounded loop for deterministic low-risk tasks:

```text
observe -> plan one small action -> risk_check -> act -> verify -> replan
```

Sensitive intents such as sending messages, submitting forms, deleting data, credentials, Terminal/shell, payments, installs, or system settings return `approval_required` unless an approval token is supplied.

The helper also applies app profiles for common app families. Profiles currently influence search submit strategy and sensitive-app classification for browsers, Finder, Notes, messaging apps, Terminal/shell apps, System Settings, and credential apps.

CGEvent-backed actions are guarded before dispatch. If the frontmost app or focused window no longer matches the observed target, the action returns a blocked result with `target_not_frontmost` or `target_window_changed` instead of posting keyboard/mouse events into the wrong UI.

When the bridge sees an `approval_required` result without an `approval_token`, it persists an approval request and includes:

- `approval_request`
  - `id`
  - `status`
  - `summary`
  - `risk`

Approve the request, then retry the same `/computer.use` payload with the returned `approval_token`.

### `POST /computer.approval/approve`
Request:
- `approval_request_id`
- `approved_by?`
- `ttl_ms?`

Response:
- `ok`
- `approval_token` — one-time token bound to the original task/session/target payload
- `expires_at`
- `approval_request`

### `POST /computer.approval/deny`
Request:
- `approval_request_id`
- `denied_by?`
- `reason?`

Response:
- `ok`
- `approval_request`

### `GET /computer.audit`
### `POST /computer.audit`
Request:
- `limit?`

Response:
- `ok`
- `audit_log`
- `records[]`

### `POST /computer.audit/export`
Request:
- `limit?`

Response:
- `ok`
- `export_path`
- `exported_at`
- `record_count`

### `POST /computer.cleanup`
Request:
- `dry_run?`
- `older_than_seconds?` — deletes screenshot/overlay artifacts older than this many seconds
- `max_screenshots?` — keeps only the newest N screenshots and overlays
- `audit_retention_days?` — removes audit records older than this many days
- `include_overlays?` — defaults to true
- `include_file_names?` — defaults to false to avoid exposing window-title-derived artifact names

Response:
- `ok`
- `artifacts`
  - `screenshots`
  - `overlays`
- `audit`

The cleanup endpoint also honors these environment defaults:

```bash
COMPUTER_USE_SCREENSHOT_TTL_SECONDS=3600
COMPUTER_USE_MAX_SCREENSHOTS=50
COMPUTER_USE_AUDIT_LOG_RETENTION_DAYS=14
```

Set either of these to prevent raw screenshot artifact persistence:

```bash
COMPUTER_USE_DISABLE_SCREENSHOT_PERSISTENCE=1
COMPUTER_USE_REDACT_SCREENSHOTS=1
```
