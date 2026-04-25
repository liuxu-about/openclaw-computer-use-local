#!/usr/bin/env bash
set -euo pipefail

HERMES_BIN="${HERMES_BIN:-$HOME/.hermes/hermes-agent-upgrade-v2026.4.16/venv/bin/hermes}"
SERVER_NAME="${SERVER_NAME:-computer_use_local}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_PY="$PROJECT_DIR/hermes-mcp/server.py"
PYTHON_BIN="${HERMES_PYTHON:-$HOME/.hermes/hermes-agent-upgrade-v2026.4.16/venv/bin/python}"
BRIDGE_URL="${COMPUTER_USE_BRIDGE_URL:-http://127.0.0.1:4458}"

if [[ ! -x "$HERMES_BIN" ]]; then
  echo "Hermes binary not found: $HERMES_BIN" >&2
  exit 1
fi
if [[ ! -f "$SERVER_PY" ]]; then
  echo "Hermes MCP server not found: $SERVER_PY" >&2
  exit 1
fi
if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "Hermes Python not found: $PYTHON_BIN" >&2
  exit 1
fi

"$HERMES_BIN" mcp remove "$SERVER_NAME" >/dev/null 2>&1 || true
printf 'y\n' | "$HERMES_BIN" mcp add "$SERVER_NAME" \
  --command "$PYTHON_BIN" \
  --args "$SERVER_PY" \
  --env "COMPUTER_USE_BRIDGE_URL=$BRIDGE_URL" "PYTHONUNBUFFERED=1"
