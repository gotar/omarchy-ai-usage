#!/usr/bin/env bash
# Thin wrapper kept for compatibility (the widget calls scripts/opencode-balance.sh).
# Real implementation: scripts/opencode-balance.py — reads the balance from the
# OpenCode console JSON API (GET /console/api/billing/status) via a dedicated,
# cookie-authenticated headless Chromium profile.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$DIR/opencode-balance.py" "$@"