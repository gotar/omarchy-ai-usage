#!/bin/bash
# qwen-stats — emits one-line JSON with Qwen3.8 tokens/sec + ctx stats
# Usage: qwen-stats.sh [host:port]   default 127.0.0.1:8080
# Requires: curl, python3, journalctl (optional fallback)
set -e
HOST="${1:-127.0.0.1:8080}"
# strip scheme if passed
HOST="${HOST#http://}"
HOST="${HOST#https://}"

python3 - "$HOST" <<'PY'
import json, re, sys, subprocess, urllib.request, urllib.error

host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1:8080"
base = f"http://{host}"

def fetch(path, timeout=1.5):
    try:
        with urllib.request.urlopen(base + path, timeout=timeout) as r:
            return r.read().decode("utf-8", errors="ignore")
    except Exception as e:
        return None

slots_raw = fetch("/slots")
props_raw = fetch("/props")

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
    "n_prompt": 0,
}

# parse props for ctx_total / model
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

# parse slots for live state
if slots_raw:
    try:
        s = json.loads(slots_raw)
        if isinstance(s, list) and len(s) > 0:
            slot = s[0] if isinstance(s[0], dict) else {}
            data["active"] = True
            data["processing"] = bool(slot.get("is_processing"))
            # ctx usage
            n_prompt = slot.get("n_prompt_tokens")
            n_ctx_slot = slot.get("n_ctx")
            if isinstance(n_prompt, int):
                data["n_prompt"] = n_prompt
                data["ctx_used"] = n_prompt
            # n_decoded from next_token
            nt = slot.get("next_token")
            if isinstance(nt, list) and len(nt) > 0 and isinstance(nt[0], dict):
                nd = nt[0].get("n_decoded")
                if isinstance(nd, int):
                    data["n_decoded"] = nd
            if isinstance(n_ctx_slot, int) and n_ctx_slot > 0:
                data["ctx_total"] = n_ctx_slot
            if data["ctx_total"] > 0 and data["ctx_used"] > 0:
                data["ctx_pct"] = round(data["ctx_used"] / data["ctx_total"] * 100, 1)
        elif isinstance(s, dict):
            # sometimes single object
            data["active"] = True
    except: 
        # slots fetch succeeded but parse failed -> active
        data["active"] = slots_raw is not None
else:
    # try health
    h = fetch("/health", timeout=1.0)
    if h and '"ok"' in h:
        data["active"] = True

# journal fallback for t/s numbers (last 40 lines)
try:
    # use --user journal
    out = subprocess.run(
        ["journalctl", "--user", "-u", "llama-cpp-server.service", "-n", "50", "--no-pager", "--output", "cat", "-q"],
        capture_output=True, text=True, timeout=3
    )
    log = out.stdout if out.returncode == 0 else ""
    if not log:
        # try system journal as fallback
        out2 = subprocess.run(
            ["journalctl", "-u", "llama-cpp-server.service", "-n", "50", "--no-pager", "--output", "cat", "-q"],
            capture_output=True, text=True, timeout=3
        )
        log = out2.stdout if out2.returncode == 0 else ""
except Exception:
    log = ""

if log:
    # prompt eval: "prompt eval time = ... (  508.89 tokens per second)"
    m_prompt = re.findall(r"prompt eval time.*?([\d]+\.[\d]+)\s+tokens per second", log)
    if m_prompt:
        try: data["prompt_tps"] = round(float(m_prompt[-1]), 1)
        except: pass
    # also capture live prompt processing: "t = 71.16 s / 631.61 tokens per second"
    m_prompt_live = re.findall(r"prompt processing.*?([\d]+\.[\d]+)\s+tokens per second", log)
    if m_prompt_live:
        try: data["prompt_tps"] = round(float(m_prompt_live[-1]), 1)
        except: pass
    m_gen = re.findall(r"eval time\s*=\s*[\d\.]+\s*ms\s*/\s*\d+\s*tokens.*?\(.*?([\d]+\.[\d]+)\s+tokens per second\)", log)
    # fallback: second pattern without prefix duplication - pick last eval that is not prompt
    # The log has two eval lines: prompt eval and eval. We already captured prompt, now capture generic eval (including prompt line again)
    # So filter: take last that is not equal to prompt last if multiple
    if m_gen:
        # m_gen includes prompt eval too; the last entry is the gen eval
        try: data["gen_tps"] = round(float(m_gen[-1]), 1)
        except: pass
        # if prompt and gen are same line, gen would be duplicate; ensure gen != prompt when only one entry? keep as is.
    # live tg
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
    # if processing is true, live_tps is the current; otherwise gen_tps is the last completed
    # ctx_used from log's last total line? optional
    # n_gen from last tg line already drives n_decoded if slots not available

# if we have live but no gen, use live as gen when not processing
if data["gen_tps"] is None and data["live_tps"] is not None and not data["processing"]:
    data["gen_tps"] = data["live_tps"]

# cosmetics: ctx_pct from ctx values if not yet
if data["ctx_pct"] == 0 and data["ctx_total"] and data["ctx_used"]:
    data["ctx_pct"] = round(data["ctx_used"]/data["ctx_total"]*100, 1)

print(json.dumps(data, separators=(",",":")))
PY
