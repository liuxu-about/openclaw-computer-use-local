#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Literal, Optional

try:
    from mcp.server.fastmcp import FastMCP
except ImportError as exc:  # pragma: no cover
    print(
        "Error: FastMCP is unavailable. Run this server with a Python environment that has the 'mcp' package installed.",
        file=sys.stderr,
    )
    raise SystemExit(1) from exc

logger = logging.getLogger("computer_use_local.hermes_mcp")

DEFAULT_BASE_URL = os.environ.get("COMPUTER_USE_BRIDGE_URL", "http://127.0.0.1:4458")
DEFAULT_TIMEOUT_S = float(os.environ.get("COMPUTER_USE_BRIDGE_TIMEOUT", "180"))


class BridgeClientError(RuntimeError):
    pass


class BridgeClient:
    def __init__(self, base_url: str, timeout_s: float = DEFAULT_TIMEOUT_S):
        self.base_url = base_url.rstrip("/")
        self.timeout_s = timeout_s

    def get(self, path: str, params: Optional[dict[str, Any]] = None) -> dict[str, Any]:
        query = f"?{urllib.parse.urlencode(params)}" if params else ""
        url = f"{self.base_url}{path}{query}"
        req = urllib.request.Request(url, method="GET")
        return self._execute(req, timeout=min(self.timeout_s, 60.0))

    def post(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        req = urllib.request.Request(
            f"{self.base_url}{path}",
            data=data,
            method="POST",
            headers={"content-type": "application/json"},
        )
        return self._execute(req, timeout=self.timeout_s)

    def _execute(self, request: urllib.request.Request, timeout: float) -> dict[str, Any]:
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                body = response.read().decode("utf-8", errors="replace")
                return self._decode_json(body)
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace") if hasattr(exc, "read") else ""
            raise BridgeClientError(self._format_http_error(exc.code, body)) from exc
        except urllib.error.URLError as exc:
            reason = getattr(exc, "reason", exc)
            raise BridgeClientError(
                f"Failed to reach local computer-use bridge at {self.base_url}: {reason}"
            ) from exc
        except TimeoutError as exc:
            raise BridgeClientError(f"Bridge request to {self.base_url} timed out after {timeout:.1f}s") from exc

    @staticmethod
    def _decode_json(text: str) -> dict[str, Any]:
        try:
            payload = json.loads(text)
        except json.JSONDecodeError as exc:
            raise BridgeClientError(f"Bridge returned invalid JSON: {exc}") from exc
        if not isinstance(payload, dict):
            raise BridgeClientError("Bridge returned a non-object JSON payload")
        return payload

    @staticmethod
    def _format_http_error(status: int, body: str) -> str:
        if not body:
            return f"Bridge returned HTTP {status}"
        try:
            parsed = json.loads(body)
            if isinstance(parsed, dict):
                message = parsed.get("error") or parsed.get("message") or body
                return f"Bridge returned HTTP {status}: {message}"
        except json.JSONDecodeError:
            pass
        trimmed = body.strip().replace("\n", " ")
        if len(trimmed) > 500:
            trimmed = trimmed[:497] + "..."
        return f"Bridge returned HTTP {status}: {trimmed}"


CLIENT = BridgeClient(DEFAULT_BASE_URL, DEFAULT_TIMEOUT_S)


def _json(result: dict[str, Any]) -> str:
    return json.dumps(result, ensure_ascii=False, indent=2)


def _bridge_call(method: Literal["GET", "POST"], path: str, payload: Optional[dict[str, Any]] = None) -> str:
    try:
        if method == "GET":
            result = CLIENT.get(path, payload)
        else:
            result = CLIENT.post(path, payload or {})
        return _json(result)
    except BridgeClientError as exc:
        return _json({"ok": False, "error": str(exc), "bridge_url": CLIENT.base_url, "path": path})


def create_server() -> FastMCP:
    mcp = FastMCP(
        "computer_use_local",
        instructions=(
            "Local macOS computer-use bridge for Hermes. Prefer AX-first element actions. "
            "Call computer_observe before computer_act. Use element ids when available; use coordinate-based vision actions only as fallback. "
            "If AX is sparse and screenshot capture fails, treat the UI as low-confidence rather than continuing to blindly type or click."
        ),
    )

    @mcp.tool()
    def computer_health(deep: bool = False) -> str:
        """Check whether the local computer-use bridge is reachable.

        Args:
            deep: When true, also query helper readiness (Accessibility, screen recording, frontmost app).
        """
        params = {"deep": 1} if deep else None
        return _bridge_call("GET", "/health", params)

    @mcp.tool()
    def computer_observe(
        session_id: Optional[str] = None,
        target_app: Optional[str] = None,
        target_window: Optional[str] = None,
        mode: Literal["ax", "ax_with_screenshot", "vision"] = "ax",
        max_nodes: int = 120,
        include_screenshot: Optional[bool] = None,
    ) -> str:
        """Observe a local macOS app through the computer-use bridge.

        Returns the latest AX snapshot, element ids, and optional screenshot metadata.
        """
        payload: Dict[str, Any] = {
            "session_id": session_id,
            "target_app": target_app,
            "target_window": target_window,
            "mode": mode,
            "max_nodes": max_nodes,
        }
        if include_screenshot is not None:
            payload["include_screenshot"] = include_screenshot
        payload = {key: value for key, value in payload.items() if value is not None}
        return _bridge_call("POST", "/computer.observe", payload)

    @mcp.tool()
    def computer_act(observation_id: str, actions: List[Dict[str, Any]], session_id: Optional[str] = None) -> str:
        """Perform element-level or fallback computer-use actions against a prior observation.

        Args:
            observation_id: The observation_id returned by computer_observe.
            actions: Action objects such as press/focus/replace_text/submit/vision_click.
        """
        return _bridge_call("POST", "/computer.act", {
            "session_id": session_id,
            "observation_id": observation_id,
            "actions": actions,
        })

    @mcp.tool()
    def computer_stop() -> str:
        """Interrupt active computer-use work on the local bridge."""
        return _bridge_call("POST", "/computer.stop", {})

    @mcp.tool()
    def computer_use(
        task: str,
        target_app: str,
        session_id: Optional[str] = None,
        target_window: Optional[str] = None,
        approval_mode: Literal["strict", "normal"] = "normal",
        allow_vision_fallback: bool = True,
        auto_execute: Optional[bool] = None,
        max_steps: Optional[int] = None,
        approval_token: Optional[str] = None,
    ) -> str:
        """High-level wrapper for a local computer-use task.

        Prefer the lower-level observe/act pair when you need precise multi-step control.
        """
        payload = {
            "session_id": session_id,
            "task": task,
            "target_app": target_app,
            "target_window": target_window,
            "approval_mode": approval_mode,
            "allow_vision_fallback": allow_vision_fallback,
            "auto_execute": auto_execute,
            "max_steps": max_steps,
            "approval_token": approval_token,
        }
        payload = {key: value for key, value in payload.items() if value is not None}
        return _bridge_call("POST", "/computer.use", payload)

    @mcp.tool()
    def computer_approval_approve(
        approval_request_id: str,
        approved_by: Optional[str] = None,
        ttl_ms: Optional[int] = None,
    ) -> str:
        """Approve a pending local computer-use request and return a one-time approval token."""
        payload = {
            "approval_request_id": approval_request_id,
            "approved_by": approved_by,
            "ttl_ms": ttl_ms,
        }
        payload = {key: value for key, value in payload.items() if value is not None}
        return _bridge_call("POST", "/computer.approval/approve", payload)

    @mcp.tool()
    def computer_approval_deny(
        approval_request_id: str,
        denied_by: Optional[str] = None,
        reason: Optional[str] = None,
    ) -> str:
        """Deny a pending local computer-use approval request."""
        payload = {
            "approval_request_id": approval_request_id,
            "denied_by": denied_by,
            "reason": reason,
        }
        payload = {key: value for key, value in payload.items() if value is not None}
        return _bridge_call("POST", "/computer.approval/deny", payload)

    @mcp.tool()
    def computer_audit(limit: int = 50) -> str:
        """Read recent local computer-use audit records."""
        return _bridge_call("POST", "/computer.audit", {"limit": limit})

    @mcp.tool()
    def computer_audit_export(limit: int = 500) -> str:
        """Export recent local computer-use audit records to a local JSON artifact."""
        return _bridge_call("POST", "/computer.audit/export", {"limit": limit})

    @mcp.tool()
    def computer_cleanup(
        dry_run: bool = False,
        older_than_seconds: Optional[int] = None,
        max_screenshots: Optional[int] = None,
        audit_retention_days: Optional[int] = None,
        include_overlays: bool = True,
        include_file_names: bool = False,
    ) -> str:
        """Clean local screenshot, overlay, and audit artifacts according to retention settings."""
        payload = {
            "dry_run": dry_run,
            "older_than_seconds": older_than_seconds,
            "max_screenshots": max_screenshots,
            "audit_retention_days": audit_retention_days,
            "include_overlays": include_overlays,
            "include_file_names": include_file_names,
        }
        payload = {key: value for key, value in payload.items() if value is not None}
        return _bridge_call("POST", "/computer.cleanup", payload)

    return mcp


def main() -> None:
    parser = argparse.ArgumentParser(description="Hermes MCP wrapper for the local computer-use bridge")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL, help="Local computer-use bridge base URL")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S, help="Bridge request timeout in seconds")
    parser.add_argument("--verbose", action="store_true", help="Enable debug logging to stderr")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.WARNING,
        stream=sys.stderr,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    global CLIENT
    CLIENT = BridgeClient(args.base_url, args.timeout)
    server = create_server()

    async def _run() -> None:
        await server.run_stdio_async()

    try:
        asyncio.run(_run())
    except KeyboardInterrupt:
        logger.debug("Shutting down computer-use Hermes MCP server")


if __name__ == "__main__":
    main()
