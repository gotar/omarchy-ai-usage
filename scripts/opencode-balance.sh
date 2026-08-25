#!/usr/bin/env bash
# opencode-balance — fetch the Opencode Zen credit wallet balance.
#
# Uses a DEDICATED Chromium profile (never the default browser profile), so it
# never touches / copies your everyday Google sign-in cookies. Sign in once
# with `--login` and the headless fetch reuses only that profile's session.
#
# Usage:
#   opencode-balance                # JSON from cache if fresh (TTL), else headless fetch
#   opencode-balance --refresh      # force headless fetch (ignore cache)
#   opencode-balance --login        # open headed Chromium in the dedicated profile & sign in
#   opencode-balance <workspaceID> [flags]
#
# Output (stdout, single JSON object):
#   {"balance":"$4.10","amount":4.10,"workspace":"wrk_...","url":"...","fetchedAt":"...","cached":false}
#   {"error":"not-logged-in", ...}
#
# Env:
#   OPCODE_BALANCE_WORKSPACE   default workspace id
#   OPCODE_BALANCE_HOME        state dir (default ~/.config/opencode-balance)
#   OPCODE_BALANCE_TTL         cache TTL seconds (default 600)
#   OPCODE_BALANCE_PROFILE     dedicated chromium profile dir (default $HOME_DIR/chromium-profile)

set -uo pipefail

WORKSPACE_ID="${OPCODE_BALANCE_WORKSPACE:-}"
MODE="auto"
for a in "$@"; do
  case "$a" in
    --login) MODE="login" ;;
    --refresh) MODE="refresh" ;;
    -h|--help) sed -n '1,30p' "$0"; exit 0 ;;
    wrk_*) WORKSPACE_ID="$a" ;;
    *) echo "{\"error\":\"unknown arg: $a\"}" >&2; exit 2 ;;
  esac
done
WORKSPACE_ID="${OPCODE_BALANCE_WORKSPACE:-$WORKSPACE_ID}"

URL="https://opencode.ai/workspace/${WORKSPACE_ID}/billing"
HOME_DIR="${OPCODE_BALANCE_HOME:-$HOME/.config/opencode-balance}"
PROFILE_DIR="${OPCODE_BALANCE_PROFILE:-$HOME_DIR/chromium-profile}"
CACHE_FILE="$HOME_DIR/cache.json"
TTL="${OPCODE_BALANCE_TTL:-600}"
NOW_EPOCH=$(date +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

emit() { echo "$1"; }
fail() {
  local hint=""; [ -n "${2:-}" ] && hint=",\"hint\":\"$2\""
  emit "{\"error\":\"$1\"${hint},\"fetchedAt\":\"$NOW_ISO\"}"
  exit 1
}

[ -n "$WORKSPACE_ID" ] || fail "no-workspace-id" "set opencodeWorkspaceId in the widget settings or OPCODE_BALANCE_WORKSPACE"
mkdir -p "$HOME_DIR"

is_fresh_cache() {
  [ -f "$CACHE_FILE" ] || return 1
  local ts
  ts=$(python3 -c "import json,sys;print(int(json.load(open(sys.argv[1])).get('fetchedEpoch',0)))" "$CACHE_FILE" 2>/dev/null) || return 1
  [ -n "$ts" ] && [ $((NOW_EPOCH - ts)) -lt "$TTL" ]
}

# ── 1) Dedicated-profile headless fetch (preferred: no visible tab, isolated session) ──
fetch_headless() {
  local BALANCE AMOUNT html
  mkdir -p "$PROFILE_DIR"
  # Abort fast if the dedicated profile has never been signed in (no cookies yet).
  [ -s "$PROFILE_DIR/Default/Cookies" ] || return 2
  html=$(timeout 20 chromium --headless --disable-gpu --user-data-dir="$PROFILE_DIR" --dump-dom "$URL" 2>/dev/null) || return 1
  # Extract balance: hydration splits it as $<!--$-->4.07 — use python to join
  BALANCE=$(python3 -c "
import re,sys
html=open('/dev/stdin',encoding='utf-8',errors='ignore').read()
m=re.search(r'data-slot=\"balance-value\"[^>]*>(.*?)</span>', html, re.S)
if not m: sys.exit(1)
inner=m.group(1)
inner=re.sub(r'<!--.*?-->', '', inner)
inner=inner.strip()
print(inner)
" <<< "$html" 2>/dev/null | xargs)
  [ -n "$BALANCE" ] || return 1
  AMOUNT=$(printf '%s' "$BALANCE" | grep -oE '[0-9]+([,.][0-9]+)?' | head -1 | tr ',' '.')
  [ -n "$AMOUNT" ] || return 1
  # Emit
  local payload
  payload=$(python3 - "$BALANCE" "$AMOUNT" "$WORKSPACE_ID" "$URL" "$NOW_ISO" "$NOW_EPOCH" <<'PYEOF'
import json, sys
balance, amount, workspace, url, iso, epoch = sys.argv[1:7]
print(json.dumps({"balance": balance, "amount": float(amount), "currency": "USD", "workspace": workspace, "url": url, "fetchedAt": iso, "fetchedEpoch": int(epoch), "cached": False}))
PYEOF
) || return 1
  local t
  t=$(mktemp "$HOME_DIR/.cache.XXXXXX") && printf '%s' "$payload" > "$t" && mv "$t" "$CACHE_FILE"
  emit "$payload"
  return 0
}

# ── 2) One-time interactive login: headed Chromium on the dedicated profile ──
do_login() {
  mkdir -p "$PROFILE_DIR"
  echo "Opening dedicated Chromium profile for opencode-balance…" >&2
  echo "Sign in to opencode.ai in the window, then CLOSE it when done (or Ctrl+Q)." >&2
  echo "Afterwards run: opencode-balance --refresh" >&2
  chromium --user-data-dir="$PROFILE_DIR" "$URL" >/dev/null 2>&1
  [ "$?" -eq 0 ] || { echo "{\"error\":\"browser-open-failed\"}" >&2; exit 1; }
  echo "Login window closed. Checking whether the session cookie was stored…" >&2
  sleep 1
  [ -s "$PROFILE_DIR/Default/Cookies" ] && echo "OK: dedicated profile has cookies." >&2
  return 0
}

if [ "$MODE" = "login" ]; then
  do_login
  exit 0
fi

if [ "$MODE" = "auto" ] && is_fresh_cache; then
  python3 -c "import json,sys;d=json.load(open(sys.argv[1]));d['cached']=True;json.dump(d,sys.stdout)" "$CACHE_FILE"
  exit 0
fi

fetch_headless
rc=$?
[ $rc -eq 0 ] && exit 0

if [ $rc -eq 2 ]; then
  fail "not-logged-in" "dedicated profile has no session yet — run: opencode-balance --login"
fi
fail "headless-fetch-failed" "opencode.ai did not return a balance — run: opencode-balance --login"