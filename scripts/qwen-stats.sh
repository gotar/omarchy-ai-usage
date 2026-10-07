#!/bin/bash
# qwen-stats — emits one-line JSON with local-model tokens/sec + ctx stats + task duration + queue + client + prompt preview
# Usage: qwen-stats.sh [host:port] [systemd-unit]   defaults 127.0.0.1:8080 llama-cpp-server.service
set -e
HOST="${1:-127.0.0.1:8080}"
HOST="${HOST#http://}"
HOST="${HOST#https://}"
UNIT="${2:-llama-cpp-server.service}"
PORT="${HOST##*:}"
export QWEN_STATS_UNIT="$UNIT" QWEN_STATS_PORT="$PORT"

python3 - "$HOST" <<'PY'
import json, re, sys, subprocess, urllib.request, os, glob, time
from datetime import datetime, timezone

host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1:8080"
base = f"http://{host}"

def fetch(path, timeout=1.5):
    try:
        with urllib.request.urlopen(base + path, timeout=timeout) as r:
            return r.read().decode("utf-8", errors="ignore")
    except Exception:
        return None

slots_raw = fetch("/slots")
props_raw = fetch("/props")
metrics_raw = fetch("/metrics")

data = {
    "active": False,
    "processing": False,
    "model": "Qwen3.8-27B-UD-Q4_K_M",
    "ctx_used": 0,
    "ctx_total": 122880,
    "ctx_pct": 0.0,
    "prompt_tps": None,
    "gen_tps": None,
    "live_tps": None,
    "live_tps_3s": None,
    "draft_accept": None,
    "n_decoded": 0,
    "n_remain": 0,
    "n_prompt": 0,
    "id_task": 0,
    "task_duration_sec": 0,
    "task_duration_str": "",
    "queue_deferred": 0,
    "queue_processing": 0,
    "client_ip": "",
    "client_host": "",
    "conn_count": 0,
    "prompt_preview": "",
}

# props
if props_raw:
    try:
        p = json.loads(props_raw)
        if isinstance(p, dict):
            ds = p.get("default_generation_settings", {})
            n_ctx = ds.get("n_ctx") if isinstance(ds, dict) else None
            if isinstance(n_ctx, int) and n_ctx > 0:
                data["ctx_total"] = n_ctx
            alias = p.get("model_alias")
            if isinstance(alias, str) and alias:
                data["model"] = alias
    except: pass

# slots
id_task = None
if slots_raw:
    try:
        s = json.loads(slots_raw)
        if isinstance(s, list) and len(s) > 0:
            slot = s[0] if isinstance(s[0], dict) else {}
            data["active"] = True
            data["processing"] = bool(slot.get("is_processing"))
            n_prompt = slot.get("n_prompt_tokens")
            n_ctx_slot = slot.get("n_ctx")
            if isinstance(n_prompt, int):
                data["n_prompt"] = n_prompt
                data["ctx_used"] = n_prompt
            nt = slot.get("next_token")
            if isinstance(nt, list) and len(nt) > 0 and isinstance(nt[0], dict):
                nd = nt[0].get("n_decoded")
                nr = nt[0].get("n_remain")
                if isinstance(nd, int):
                    data["n_decoded"] = nd
                if isinstance(nr, int):
                    data["n_remain"] = nr
            if isinstance(n_ctx_slot, int) and n_ctx_slot > 0:
                data["ctx_total"] = n_ctx_slot
            if data["ctx_total"] > 0 and data["ctx_used"] > 0:
                data["ctx_pct"] = round(data["ctx_used"] / data["ctx_total"] * 100, 1)
            it = slot.get("id_task")
            if isinstance(it, int):
                data["id_task"] = it
                id_task = it
        elif isinstance(s, dict):
            data["active"] = True
    except:
        data["active"] = slots_raw is not None
else:
    h = fetch("/health", timeout=1.0)
    if h and '"ok"' in h:
        data["active"] = True

# metrics for queue
if metrics_raw:
    try:
        m = re.search(r'llamacpp:requests_processing\s+(\d+)', metrics_raw)
        if m: data["queue_processing"] = int(m.group(1))
        m2 = re.search(r'llamacpp:requests_deferred\s+(\d+)', metrics_raw)
        if m2: data["queue_deferred"] = int(m2.group(1))
    except: pass

# journal for t/s + duration
log = ""
try:
    out = subprocess.run(
        ["/usr/bin/journalctl", "--user", "-u", os.environ.get("QWEN_STATS_UNIT", "llama-cpp-server.service"), "-n", "300", "--no-pager", "--output", "short-iso", "-q"],
        capture_output=True, text=True, timeout=3
    )
    log = out.stdout if out.returncode == 0 else ""
    if not log:
        out2 = subprocess.run(
            ["/usr/bin/journalctl", "-u", os.environ.get("QWEN_STATS_UNIT", "llama-cpp-server.service"), "-n", "300", "--no-pager", "--output", "short-iso", "-q"],
            capture_output=True, text=True, timeout=3
        )
        log = out2.stdout if out2.returncode == 0 else ""
except Exception:
    log = ""

if log:
    m_prompt = re.findall(r"prompt eval time.*?([\d]+\.[\d]+)\s+tokens per second", log)
    if m_prompt:
        try: data["prompt_tps"] = round(float(m_prompt[-1]), 1)
        except: pass
    m_prompt_live = re.findall(r"prompt processing.*?([\d]+\.[\d]+)\s+tokens per second", log)
    if m_prompt_live:
        try: data["prompt_tps"] = round(float(m_prompt_live[-1]), 1)
        except: pass
    m_gen = re.findall(r"eval time\s*=\s*[\d\.]+\s*ms\s*/\s*\d+\s*tokens.*?\(.*?([\d]+\.[\d]+)\s+tokens per second\)", log)
    if m_gen:
        try: data["gen_tps"] = round(float(m_gen[-1]), 1)
        except: pass
    m_tg = re.findall(r"tg\s*=\s*([\d]+\.[\d]+)\s*t/s", log)
    if m_tg:
        try: data["live_tps"] = round(float(m_tg[-1]), 1)
        except: pass
    m_tg3 = re.findall(r"tg_3s\s*=\s*([\d]+\.[\d]+)\s*t/s", log)
    if m_tg3:
        try: data["live_tps_3s"] = round(float(m_tg3[-1]), 1)
        except: pass
    m_draft = re.findall(r"draft acceptance\s*=\s*([\d]+\.[\d]+)", log)
    if m_draft:
        try: data["draft_accept"] = round(float(m_draft[-1]), 3)
        except: pass
    # task duration: find first log line for current id_task
    if id_task is not None and id_task != 0:
        # short-iso lines start like "2026-09-01T09:55:04+02:00 tower llama-server[1037]: ..."
        pat = re.compile(r"^(\S+)\s+.*task\s+" + str(id_task) + r"\b")
        first_ts = None
        for line in log.splitlines():
            mm = pat.search(line)
            if mm:
                ts_str = mm.group(1)
                try:
                    # parse ISO like 2026-09-01T09:55:04+02:00
                    dt = datetime.fromisoformat(ts_str)
                    first_ts = dt
                    break  # with -n 300 we go newest first? actually journalctl prints oldest first? check.
                    # But we iterated top->bottom which is chronological ascending? journalctl default oldest first within -n window.
                    # So first match is earliest within window, which is good. If window is 300 lines, we need oldest occurrence.
                    # So we should not break on first newest-first? Instead find earliest timestamp.
                except:
                    continue
        # journalctl --user -n 300 outputs newest 300 in chronological order (oldest first among those 300)
        # So first match is indeed task start. But if task started >300 lines ago, we won't find it -> fallback to n_decoded/tps estimate
        # Try to find earliest; we already break on first found which is earliest in window.
        if first_ts:
            try:
                now = datetime.now(first_ts.tzinfo) if first_ts.tzinfo else datetime.now(timezone.utc)
                diff = (now - first_ts).total_seconds()
                if diff > 0 and diff < 86400*7:
                    data["task_duration_sec"] = int(diff)
                    # format: 1m, 2m 13s, 1h 5m
                    s = int(diff)
                    if s < 60:
                        data["task_duration_str"] = f"{s}s"
                    elif s < 3600:
                        m = s // 60
                        sec = s % 60
                        data["task_duration_str"] = f"{m}m {sec}s" if sec else f"{m}m"
                    else:
                        h = s // 3600
                        m = (s % 3600)//60
                        data["task_duration_str"] = f"{h}h {m}m"
            except: pass
        # fallback estimate if no timestamp found: use n_decoded / tps
        if data["task_duration_sec"] == 0 and data["n_decoded"] and data["live_tps"]:
            try:
                est = int(data["n_decoded"] / max(1, data["live_tps"]))
                if est > 0:
                    data["task_duration_sec"] = est
                    if est < 60: data["task_duration_str"] = f"~{est}s"
                    elif est < 3600: data["task_duration_str"] = f"~{est//60}m"
                    else: data["task_duration_str"] = f"~{est//3600}h"
            except: pass

if data["gen_tps"] is None and data["live_tps"] is not None and not data["processing"]:
    data["gen_tps"] = data["live_tps"]
if data["ctx_pct"] == 0 and data["ctx_total"] and data["ctx_used"]:
    data["ctx_pct"] = round(data["ctx_used"]/data["ctx_total"]*100, 1)

# client info via ss
try:
    out = subprocess.run(["/usr/bin/ss","-Htn","state","established"], capture_output=True, text=True, timeout=2)
    txt = out.stdout if out.returncode == 0 else ""
    # count peers connected to :8080
    peers = []
    port = os.environ.get("QWEN_STATS_PORT", "8080")
    for line in txt.splitlines():
        if (":" + port) in line:
            parts = line.split()
            if len(parts) >= 4:
                # Local is parts[2], Peer is parts[3] for -Htn (4 cols), or parts[4] with State column
                # Find peer as first addr after Local that doesn't contain :8080
                for p in parts[2:]:
                    if (":" + port) in p:
                        continue
                    if ":" in p:
                        ip = p.rsplit(":",1)[0].strip("[]")
                        if ip and ip != "0.0.0.0":
                            # keep 127.0.0.1 but will be displayed as "local"
                            peers.append(ip)
                        break
    if peers:
        from collections import Counter
        cnt = Counter(peers)
        most_common = cnt.most_common(1)[0]
        data["client_ip"] = most_common[0]
        data["conn_count"] = len(peers)
        # resolve host - fast path, avoid blocking getent
        if data["client_ip"] == "127.0.0.1":
            data["client_host"] = "local"
        elif data["client_ip"] == "10.17.0.40":
            data["client_host"] = "steamdeck"
        else:
            data["client_host"] = data["client_ip"]
            try:
                out2 = subprocess.run(["/usr/bin/getent","hosts", data["client_ip"]], capture_output=True, text=True, timeout=0.8)
                if out2.returncode == 0 and out2.stdout.strip():
                    host_part = out2.stdout.strip().split()[-1]
                    if host_part:
                        data["client_host"] = host_part
            except:
                pass
            if data["client_host"] == data["client_ip"]:
                try:
                    out3 = subprocess.run(["/usr/bin/avahi-resolve","-a", data["client_ip"]], capture_output=True, text=True, timeout=0.8)
                    if out3.returncode == 0 and out3.stdout.strip():
                        data["client_host"] = out3.stdout.strip().split()[-1]
                except:
                    pass
    # also count total estab to 8080
    if not data["client_ip"] and peers:
        data["client_ip"] = peers[0]
        data["conn_count"] = len(peers)
except: pass

# prompt preview from --log-prompts-dir
prompt_dirs = ["/tmp/llama-prompts", os.path.expanduser("~/.cache/llama-prompts"), "/tmp/qwen-prompts"]
preview = ""
for d in prompt_dirs:
    try:
        if os.path.isdir(d):
            files = glob.glob(os.path.join(d, "*"))
            if files:
                files.sort(key=lambda x: os.path.getmtime(x), reverse=True)
                # read newest, limit 2KB
                with open(files[0], "r", encoding="utf-8", errors="ignore") as f:
                    txt = f.read(3000)
                    # take first non-empty 300 chars, strip whitespace/newlines
                    txt = txt.strip().replace("\r"," ").replace("\n"," ")
                    txt = re.sub(r"\s+", " ", txt)
                    if len(txt) > 300:
                        txt = txt[:300].rsplit(" ",1)[0] + "…"
                    # sanitize for QML: limit 500
                    preview = txt[:500]
                    break
    except: pass
# also try journal prompt content if verbose logging enabled (not yet)
if not preview and log:
    # try to find prompt log line pattern if any
    pass
data["prompt_preview"] = preview

print(json.dumps(data, separators=(",",":")))
PY
