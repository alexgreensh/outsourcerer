#!/usr/bin/env python3
"""Read-only plan probes for the Mission Control plans card (lib/plan-probe.sh drives these).

Every probe is bounded, makes no model call and reads no credential file. Output is one JSON
object on stdout: {"ok": true, ...} or {"ok": false, "why": "<short reason>"}.

  plan_probe.py codex <secs>       codex app-server JSON-RPC account/rateLimits/read
  plan_probe.py run <secs> cmd...  run cmd with a hard bound (whole process group), pass stdout through
  plan_probe.py agy-parse          stdin: Antigravity `/usage` screen text -> quota groups
  plan_probe.py devin-parse <models-file> <auth-file>   plan name + free model ids
  plan_probe.py droid-parse        stdin: `droid doctor --json --checks auth` -> sign-in state
"""
import json
import os
import re
import select
import signal
import subprocess
import sys
import time


def out(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")


def fail(why):
    out({"ok": False, "why": why[:160]})
    return 0


def _spawn(cmd, **kw):
    return subprocess.Popen(cmd, start_new_session=True, **kw)


def _kill(p):
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except Exception:
        try:
            p.kill()
        except Exception:
            pass
    try:
        p.wait(timeout=2)
    except Exception:
        pass


def bound(secs):
    try:
        return max(1.0, min(60.0, float(secs)))
    except Exception:
        return 15.0


# ---- codex ---------------------------------------------------------------------------------
def codex_windows(rl):
    """rateLimits object -> {codex5h|codexwk: {used, renews_at, mins}} bucketed by window length."""
    wins = {}
    for slot in ("primary", "secondary"):
        w = (rl or {}).get(slot)
        if not isinstance(w, dict) or w.get("usedPercent") is None:
            continue
        mins = w.get("windowDurationMins") or 0
        key = "codex5h" if mins and mins <= 360 else "codexwk"
        wins[key] = {"used": w.get("usedPercent"), "renews_at": w.get("resetsAt"), "mins": mins}
    return wins


def probe_codex(secs):
    t = bound(secs)
    try:
        p = _spawn(["codex", "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                   stderr=subprocess.DEVNULL)
    except Exception as e:  # not installed / not executable
        return fail("codex app-server would not start: %s" % e.__class__.__name__)
    end = time.time() + t
    buf = b""
    try:
        for msg in ({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                     "params": {"clientInfo": {"name": "outsourcerer-plans", "version": "1"}}},
                    {"jsonrpc": "2.0", "method": "initialized"},
                    {"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read"}):
            p.stdin.write((json.dumps(msg) + "\n").encode("utf-8"))
        p.stdin.flush()
        while time.time() < end:
            r, _, _ = select.select([p.stdout], [], [], 0.5)
            if not r:
                if p.poll() is not None:
                    break
                continue
            chunk = os.read(p.stdout.fileno(), 65536)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    m = json.loads(line.decode("utf-8", "replace"))
                except Exception:
                    continue
                if m.get("id") != 2:
                    continue
                if "error" in m:
                    return fail("codex app-server refused: %s" % (m["error"] or {}).get("message", "error"))
                res = m.get("result") or {}
                rl = res.get("rateLimits") or {}
                wins = codex_windows(rl)
                if not wins:
                    return fail("codex app-server returned no rate-limit window")
                cr = rl.get("credits") or {}
                out({"ok": True, "source": "codex app-server", "plan": rl.get("planType") or "",
                     "windows": wins, "reached": rl.get("rateLimitReachedType") or "",
                     "credits": {"has": bool(cr.get("hasCredits")), "unlimited": bool(cr.get("unlimited")),
                                 "balance": str(cr.get("balance") or "")},
                     "resets_available": int((res.get("rateLimitResetCredits") or {}).get("availableCount") or 0)})
                return 0
        return fail("codex app-server did not answer within %ds" % int(t))
    except Exception as e:
        return fail("codex app-server probe failed: %s" % e.__class__.__name__)
    finally:
        _kill(p)


# ---- bounded runner --------------------------------------------------------------------------
def run(secs, cmd):
    t = bound(secs)
    try:
        p = _spawn(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except Exception:
        return 127
    try:
        data, _ = p.communicate(timeout=t)
    except subprocess.TimeoutExpired:
        _kill(p)
        return 124
    sys.stdout.buffer.write(data)
    return p.returncode


# ---- antigravity /usage screen ----------------------------------------------------------------
PCT = re.compile(r"(\d+(?:\.\d+)?)%")
REFRESH = re.compile(r"Refreshes in\s+(?:(\d+)\s*d\s*)?(?:(\d+)\s*h\s*)?(?:(\d+)\s*m)?", re.I)


def agy_parse(text, now=None):
    now = int(now if now is not None else time.time())
    lines = [ln.rstrip() for ln in text.splitlines()]
    if not any("Models & Quota" in ln for ln in lines):
        return {"ok": False, "why": "Antigravity /usage screen not found"}
    groups, g, win = [], None, None
    for ln in lines:
        s = ln.strip().lstrip("│").strip()
        if not s:
            continue
        # Group headings are all-caps lines with no box/bar glyphs ("GEMINI MODELS", "GEMINI 4 ARGON").
        if re.fullmatch(r"[A-Z0-9][A-Z0-9 .&/-]{2,}", s) and ln.startswith(s[:1]):
            g = {"name": s.title().replace("Gpt", "GPT").replace("And", "and"), "models": "", "windows": []}
            groups.append(g)
            win = None
            continue
        if g is None:
            continue
        if s.startswith("Models within this group:"):
            g["models"] = s.split(":", 1)[1].strip()
            continue
        low = s.lower()
        if re.fullmatch(r"(?:[A-Za-z0-9 .]+ )?(?:Weekly|Five Hour|5-Hour) Limit(?: Remaining)?", s, re.I):
            win = {"kind": "5h" if ("five hour" in low or "5-hour" in low) else "week", "left": None,
                   "renews_at": None, "note": ""}
            g["windows"].append(win)
            continue
        if win is None:
            continue
        m = PCT.search(s)
        if s.startswith("[") and m:
            win["left"] = float(m.group(1))
            continue
        r = REFRESH.search(s)
        if r and any(r.groups()):
            d, h, mi = (int(x or 0) for x in r.groups())
            win["renews_at"] = now + d * 86400 + h * 3600 + mi * 60
            continue
        if low.startswith("disabled"):
            win["note"] = "Paused: the weekly limit is spent, so the 5-hour limit does not apply."
            win["disabled"] = True
            continue
        if low.startswith("quota available"):
            win["note"] = "Quota available"
    for x in groups:
        x["windows"] = [w for w in x["windows"] if w["left"] is not None or w.get("disabled")]
    groups = [x for x in groups if x["windows"]]
    if not groups:
        return {"ok": False, "why": "Antigravity /usage screen had no quota groups"}
    return {"ok": True, "source": "agy /usage", "groups": groups}


# ---- devin ------------------------------------------------------------------------------------
def devin_parse(models_txt, auth_txt):
    free = re.findall(r"^\s+([a-z0-9][a-z0-9.-]+)\s+.*?\[(?:[^\]]*,)?\s*Free\s*(?:,[^\]]*)?\]\s*$", models_txt, re.M)
    plan = ""
    for ln in auth_txt.splitlines():   # only the plan lines; never names, emails or ids
        m = re.match(r"\s*(Plan|Tier):\s*(.+?)\s*$", ln)
        if m and not plan:
            plan = m.group(2)
        if m and m.group(1) == "Plan":
            plan = m.group(2)
    logged = bool(re.search(r"\blogged in\b", auth_txt, re.I))
    if not free and not logged:
        return {"ok": False, "why": "devin models listed no models and auth status showed no login"}
    return {"ok": True, "source": "devin models", "plan": plan[:40], "free": free[:40], "logged_in": logged}


# ---- droid ------------------------------------------------------------------------------------
def droid_parse(txt):
    try:
        d = json.loads(txt)
    except Exception:
        return {"ok": False, "why": "droid doctor gave no JSON"}
    res = {r.get("id"): r for r in d.get("results") or [] if isinstance(r, dict)}
    cred = res.get("auth.credentials") or {}
    exp = res.get("auth.tokenExpiry") or {}
    if cred.get("status") != "pass":
        return {"ok": False, "why": "droid doctor: %s" % (cred.get("detail") or "no stored login")[:120]}
    m = re.search(r"valid until (\S+?)(?:;|$)", exp.get("detail") or "")
    return {"ok": True, "source": "droid doctor", "signed_in": True, "token_until": m.group(1) if m else "",
            "token_ok": exp.get("status") == "pass"}


def _read(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except Exception:
        return ""


def main(argv):
    if len(argv) < 2:
        return fail("usage")
    cmd = argv[1]
    if cmd == "codex":
        return probe_codex(argv[2] if len(argv) > 2 else 15)
    if cmd == "run":
        if len(argv) < 4:
            return 2
        return run(argv[2], argv[3:])
    if cmd == "agy-parse":
        out(agy_parse(sys.stdin.buffer.read().decode("utf-8", "replace"), argv[2] if len(argv) > 2 else None))
        return 0
    if cmd == "devin-parse":
        out(devin_parse(_read(argv[2]), _read(argv[3])))
        return 0
    if cmd == "droid-parse":
        out(droid_parse(sys.stdin.buffer.read().decode("utf-8", "replace")))
        return 0
    return fail("unknown probe")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
