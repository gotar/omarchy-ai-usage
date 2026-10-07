#!/usr/bin/env python3
"""opencode-balance — fetch the OpenCode Zen credit wallet balance.

Source of truth is the console JSON API (used by https://opencode.ai/console/<workspace>):

    GET /console/api/billing/status   -> BillingStatus { balanceMicroCents, availableMicroCents, ... }
    GET /console/api/orgs/current     -> Org { balanceMicroCents, availableMicroCents, ... }
    GET /console/api/auth/session     -> session probe

The console API is cookie-authenticated, so we drive a headless Chromium on the
DEDICATED profile (never the everyday browser profile), let it load the console
origin and evaluate the fetch inside the page. Cookies stay inside that browser
(they are App-Bound encrypted and unreadable from disk on purpose).

Usage:
    opencode-balance                # JSON from cache if fresh (TTL), else fetch
    opencode-balance --refresh      # force fetch (ignore cache)
    opencode-balance --login        # open headed Chromium on the dedicated profile & sign in
    opencode-balance --ttl N        # cache TTL seconds

Output (stdout, single JSON object):
    {"balance":"$4.10","amount":4.10,"currency":"USD","workspace":"wrk_...","url":"...",
     "fetchedAt":"...","fetchedEpoch":0,"cached":false}
    {"error":"not-logged-in","hint":"...","fetchedAt":"..."}

Env:
    OPCODE_BALANCE_WORKSPACE   default workspace id (wrk_… / org_…)
    OPCODE_BALANCE_HOME        state dir (default ~/.config/opencode-balance)
    OPCODE_BALANCE_TTL         cache TTL seconds (default 600)
    OPCODE_BALANCE_PROFILE     dedicated chromium profile dir (default $HOME_DIR/chromium-profile)
    OPCODE_BALANCE_CHROMIUM    chromium binary (default: chromium)
"""

import base64
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
from datetime import datetime, timezone

HOME_DIR = os.environ.get("OPCODE_BALANCE_HOME") or os.path.expanduser("~/.config/opencode-balance")
PROFILE_DIR = os.environ.get("OPCODE_BALANCE_PROFILE") or os.path.join(HOME_DIR, "chromium-profile")
CACHE_FILE = os.path.join(HOME_DIR, "cache.json")
CHROMIUM = os.environ.get("OPCODE_BALANCE_CHROMIUM") or shutil.which("chromium") or "chromium"
ORIGIN = "https://opencode.ai"
DEFAULT_TTL = 600
# Console reports money as scaled bigints: 641139568 == $6.41139568 (1e8 per dollar).
MONEY_SCALE = 100_000_000


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def die(error, hint=""):
    payload = {"error": error, "fetchedAt": now_iso()}
    if hint:
        payload["hint"] = hint
    print(json.dumps(payload))
    sys.exit(1)


def parse_args(argv):
    workspace = os.environ.get("OPCODE_BALANCE_WORKSPACE", "")
    mode, ttl = "auto", None
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--login":
            mode = "login"
        elif arg == "--refresh":
            mode = "refresh"
        elif arg in ("-h", "--help"):
            sys.stdout.write(__doc__)
            sys.exit(0)
        elif arg == "--ttl":
            i += 1
            ttl = argv[i] if i < len(argv) else ""
        elif arg.startswith("--ttl="):
            ttl = arg[len("--ttl="):]
        elif arg.startswith(("wrk_", "org_")):
            workspace = arg
        else:
            die("unknown-arg", f"unknown arg: {arg}")
        i += 1
    workspace = workspace or os.environ.get("OPCODE_BALANCE_WORKSPACE", "")
    try:
        ttl = int(ttl) if ttl not in (None, "") else int(os.environ.get("OPCODE_BALANCE_TTL", DEFAULT_TTL))
    except ValueError:
        ttl = int(os.environ.get("OPCODE_BALANCE_TTL", DEFAULT_TTL))
    return workspace, mode, ttl


# ── minimal CDP client ────────────────────────────────────────────────────────

def clear_stale_singleton_lock():
    """Make the dedicated profile launchable: drop locks left by dead/killed headless runs.

    Returns False when a *headed* window currently owns the profile (interactive
    `--login` in progress) — the caller then reports the profile as busy.
    """
    lock = os.path.join(PROFILE_DIR, "SingletonLock")
    if not os.path.lexists(lock):
        return True
    owner = os.readlink(lock) if os.path.islink(lock) else ""
    pid = owner.rsplit("-", 1)[-1]
    if not pid.isdigit():
        return True
    alive = True
    try:
        os.kill(int(pid), 0)
    except OSError:
        alive = False
    if alive:
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as fh:
                cmdline = fh.read().decode("utf-8", "ignore")
        except OSError:
            cmdline = ""
        if "--headless" not in cmdline or PROFILE_DIR not in cmdline:
            return False  # a real browser window holds the profile
        # leftover headless instance of this script — stop it
        subprocess.run(["pkill", "-f", "--", f"--user-data-dir={PROFILE_DIR}"], check=False)
        for _ in range(40):
            try:
                os.kill(int(pid), 0)
            except OSError:
                break
            time.sleep(0.25)
    for name in ("SingletonLock", "SingletonSocket", "SingletonCookie"):
        try:
            os.unlink(os.path.join(PROFILE_DIR, name))
        except OSError:
            pass
    return True


class Cdp:
    def __init__(self, proc, sock):
        self.proc, self.sock, self.next_id = proc, sock, 0

    @classmethod
    def launch(cls, url="about:blank", headless=True):
        os.makedirs(PROFILE_DIR, exist_ok=True)
        if not clear_stale_singleton_lock():
            raise RuntimeError("profile-busy (a Chromium window is open on the dedicated profile)")
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
        sock.close()
        cmd = [CHROMIUM, f"--remote-debugging-port={port}", f"--user-data-dir={PROFILE_DIR}"]
        if headless:
            cmd += ["--headless", "--disable-gpu", "--no-first-run", "--no-default-browser-check"]
        cmd.append(url)
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 25
        ws_url = None
        while time.time() < deadline:
            if proc.poll() is not None:
                raise RuntimeError("chromium exited")
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=2) as fh:
                    tabs = json.load(fh)
                page = next((t for t in tabs if t.get("type") == "page"), None)
                if page:
                    ws_url = page["webSocketDebuggerUrl"]
                    break
            except Exception:
                time.sleep(0.4)
        if not ws_url:
            proc.terminate()
            raise RuntimeError("cdp-unavailable")
        hostport, _, path = ws_url.split("//", 1)[1].partition("/")
        host, _, pport = hostport.partition(":")
        s = socket.create_connection((host, int(pport)), timeout=20)
        s.settimeout(60)
        s.sendall(
            (
                f"GET /{path} HTTP/1.1\r\nHost: {hostport}\r\nUpgrade: websocket\r\n"
                f"Connection: Upgrade\r\nSec-WebSocket-Key: {base64.b64encode(os.urandom(16)).decode()}\r\n"
                "Sec-WebSocket-Version: 13\r\n\r\n"
            ).encode()
        )
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = s.recv(4096)
            if not chunk:
                raise RuntimeError("cdp-handshake-failed")
            buf += chunk
        return cls(proc, s)

    def _send(self, payload):
        data = json.dumps(payload).encode()
        mask = os.urandom(4)
        n = len(data)
        if n < 126:
            header = bytes([0x81, 0x80 | n])
        elif n < 65536:
            header = bytes([0x81, 0x80 | 126]) + struct.pack(">H", n)
        else:
            header = bytes([0x81, 0x80 | 127]) + struct.pack(">Q", n)
        self.sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _recv(self):
        head = self._read(2)
        length = head[1] & 0x7F
        if length == 126:
            length = struct.unpack(">H", self._read(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._read(8))[0]
        return json.loads(self._read(length) or b"null")

    def _read(self, n):
        data = b""
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk:
                raise RuntimeError("cdp-closed")
            data += chunk
        return data

    def call(self, method, params=None, timeout=30):
        self.next_id += 1
        msg_id = self.next_id
        self._send({"id": msg_id, "method": method, "params": params or {}})
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.sock.settimeout(max(0.5, deadline - time.time()))
            try:
                msg = self._recv()
            except socket.timeout:
                break
            if msg.get("id") == msg_id:
                if "error" in msg:
                    raise RuntimeError(f"cdp {method}: {msg['error']}")
                return msg.get("result", {})
        raise RuntimeError(f"cdp timeout on {method}")

    def close(self):
        try:
            self.sock.close()
        finally:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
            subprocess.run(["pkill", "-f", "--", f"--user-data-dir={PROFILE_DIR}"], check=False)


# ── API fetch ─────────────────────────────────────────────────────────────────

JS_FETCH = """
(async () => {
  const ws = %s;
  const get = async (path) => {
    const r = await fetch(path, { headers: { 'x-org-id': ws }, credentials: 'include' });
    const text = await r.text();
    let json = null;
    try { json = JSON.parse(text); } catch (e) {}
    return { status: r.status, tag: json && json._tag ? json._tag : null, json, raw: text };
  };
  const session = await get('/console/api/auth/session');
  const status = await get('/console/api/billing/status');
  const org = status.status === 200 ? { status: 200, json: null, raw: null } : await get('/console/api/orgs/current');
  return { session: { status: session.status, tag: session.tag },
           status: { status: status.status, tag: status.tag, json: status.json, raw: status.raw },
           org: { status: org.status, tag: org.tag, json: org.json, raw: org.raw } };
})()
"""


def api_fetch(workspace):
    cdp = Cdp.launch(f"{ORIGIN}/console/{workspace}")
    try:
        cdp.call("Page.enable", timeout=20)
        cdp.call("Runtime.enable", timeout=20)
        cdp.call("Page.navigate", {"url": f"{ORIGIN}/console/{workspace}"}, timeout=30)
        time.sleep(3.5)  # let the SPA load so session cookie + origin are live
        expr = JS_FETCH % json.dumps(workspace)
        result = cdp.call(
            "Runtime.evaluate", {"expression": expr, "awaitPromise": True, "returnByValue": True}, timeout=45
        )
        if result.get("exceptionDetails"):
            raise RuntimeError("js-exception")
        return (result.get("result") or {}).get("value") or {}
    finally:
        cdp.close()


def amount_from(payload):
    """availableMicroCents / balanceMicroCents -> dollars.

    Both arrive as scaled-bigint *strings* (Effect Schema), so parse them, and
    divide by MONEY_SCALE (1e8 per USD), not by 1e6.
    """
    for key in ("availableMicroCents", "balanceMicroCents"):
        value = payload.get(key)
        if isinstance(value, bool) or value is None:
            continue
        if isinstance(value, str):
            value = value.strip()
            if not value.lstrip("-").isdigit():
                continue
            value = int(value)
        if isinstance(value, (int, float)):
            return round(value / MONEY_SCALE, 6)
    return None


def fetch(workspace):
    url = f"{ORIGIN}/console/{workspace}"
    if not os.path.isfile(os.path.join(PROFILE_DIR, "Default", "Cookies")):
        return die("not-logged-in", "dedicated profile has no session yet — run: opencode-balance --login")

    try:
        data = api_fetch(workspace)
    except Exception as exc:  # browser/CDP trouble — keep the last good value if we have one
        cached = read_cache()
        if cached:
            cached["cached"] = True
            cached["stale"] = True
            print(json.dumps(cached))
            sys.exit(0)
        die("fetch-failed", f"{type(exc).__name__}: {exc} — run: opencode-balance --login")

    session_status = (data.get("session") or {}).get("status")
    if session_status in (401, 403) or (data.get("status") or {}).get("status") in (401, 403):
        die("not-logged-in", "console session expired — run: opencode-balance --login")

    for key in ("status", "org"):
        node = data.get(key) or {}
        if node.get("status") == 200 and isinstance(node.get("json"), dict):
            amount = amount_from(node["json"])
            if amount is not None:
                body = node["json"]
                payload = {
                    "balance": f"${amount:,.2f}",
                    "amount": amount,
                    "currency": "USD",
                    "workspace": workspace,
                    "url": url,
                    "source": f"{key}-api",
                    "fetchedAt": now_iso(),
                    "fetchedEpoch": int(time.time()),
                    "cached": False,
                }
                for extra in ("billingMode", "accountMode", "creditLimitMicroCents"):
                    if extra in body:
                        payload[extra] = body[extra]
                write_cache(payload)
                print(json.dumps(payload))
                return

    hint = "console API returned no balance"
    statuses = {(data.get(key) or {}).get("status") for key in ("status", "org")}
    if 404 in statuses:
        die("workspace-not-found", f"{workspace} is unknown to the console API (or your account cannot see it)")
    if os.environ.get("OPCODE_BALANCE_DEBUG"):
        for key in ("status", "org"):
            node = data.get(key) or {}
            print(f"# {key} status={node.get('status')} raw={(node.get('raw') or '')[:600]}", file=sys.stderr)
    for key in ("status", "org"):
        node = data.get(key) or {}
        if node.get("status"):
            hint += f" · {key}={node['status']} {node.get('tag') or ''}".rstrip()
    die("no-balance-in-response", hint)


# ── cache / login ─────────────────────────────────────────────────────────────


def read_cache():
    try:
        with open(CACHE_FILE) as fh:
            return json.load(fh)
    except Exception:
        return None


def write_cache(payload):
    os.makedirs(HOME_DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=HOME_DIR, prefix=".cache.")
    with os.fdopen(fd, "w") as fh:
        json.dump(payload, fh)
    os.replace(tmp, CACHE_FILE)


def do_login(workspace):
    os.makedirs(PROFILE_DIR, exist_ok=True)
    print("Opening dedicated Chromium profile for opencode-balance…", file=sys.stderr)
    print("Sign in to opencode.ai, then CLOSE the window when done.", file=sys.stderr)
    subprocess.run([CHROMIUM, f"--user-data-dir={PROFILE_DIR}", f"{ORIGIN}/console/{workspace}"])
    time.sleep(1)
    print("Login window closed; verifying session…", file=sys.stderr)
    try:
        data = api_fetch(workspace)
    except Exception as exc:
        die("verify-failed", f"{type(exc).__name__}: {exc}")
    ok = (data.get("session") or {}).get("status") == 200
    if not ok:
        die("not-logged-in", "console session still not valid — sign in again")
    print(json.dumps({"balance": None, "session": "ok", "workspace": workspace, "fetchedAt": now_iso()}))


def main():
    workspace, mode, ttl = parse_args(sys.argv[1:])
    if not workspace:
        die("no-workspace-id", "set opencodeWorkspaceId in the widget settings or OPCODE_BALANCE_WORKSPACE")
    os.makedirs(HOME_DIR, exist_ok=True)

    if mode == "login":
        do_login(workspace)
        return

    if mode == "auto":
        cached = read_cache()
        if (
            cached
            and cached.get("workspace") == workspace
            and isinstance(cached.get("fetchedEpoch"), int)
            and time.time() - cached["fetchedEpoch"] < ttl
        ):
            cached["cached"] = True
            print(json.dumps(cached))
            return

    fetch(workspace)


if __name__ == "__main__":
    main()