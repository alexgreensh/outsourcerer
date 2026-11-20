#!/usr/bin/env python3
"""advise_parse.py — live benchmark-source parsers + the (family, effort) normalizer
for `outsourcerer advise`.

Subcommands:
  parse   --dir DIR --pool POOL.txt   Rebuild DIR/rows.jsonl + per-source .meta parse fields
                                     from the raw caches (cursorbench.html, tbench.html,
                                     or-bench.json, or-endpoints.json). POOL.txt holds
                                     `alias|resolved|lane|tier` candidate rows; the candidate
                                     family vocabulary is derived from it (no hand list).
  factors --dir DIR --category CAT --effort E
                                     stdin: `alias|resolved|lane|tier` rows ->
                                     stdout: `resolved|q|qsrc|cost|csrc|tokens|tps|lat|secs`
                                     one line per input row (empty fields when unknown).
  norm                               stdin names -> `name<TAB>family<TAB>effort` (debug/test).

The normalizer is ONE function applied to source display names, OpenRouter permaslugs,
endpoint ids, and our own resolved ids/aliases. Matching is by normalized equality or a
dash-boundary suffix hit (covers vendor-dropped display names like "Opus 5.5"). Rows that
match no candidate family are reported as unmatched in the source meta, never guessed.
"""
import json
import os
import re
import sys

# ---------------------------------------------------------------------------
# Normalizer. Effort vocabulary is GENERIC (a fixed rung ladder), not a model
# list — the family vocabulary is derived from the candidate pool at runtime.
# ---------------------------------------------------------------------------
_EFFORT_RANK = {"none": 0, "minimal": 1, "low": 2, "medium": 3,
                "high": 4, "xhigh": 5, "max": 6}
# Tokens after ':' that are catalog decorations, not part of the model name.
_JUNK_TAG = {"free", "beta", "exacto", "extended", "nitro", "floor"}


def _base_norm(s):
    """lowercase vendor-strip -> canonical dash form. 'Anthropic: Claude Opus 5.5',
    'anthropic/claude-opus-5.5', and 'claude-opus-5-5' all -> 'claude-opus-5-5'."""
    s = (s or "").strip().lower()
    if "/" in s:
        s = s.split("/")[-1]
    if ":" in s:
        parts = s.split(":")
        s = parts[0] if parts[-1].strip() in _JUNK_TAG else parts[-1]
    s = re.sub(r"[^a-z0-9]+", "-", s)
    return re.sub(r"-{2,}", "-", s).strip("-")


def _strip_date(n):
    """Drop trailing date tokens: 8+ digits (20251001) or MMDD-shaped 4 digits
    (1017, 0902, 0813 as on Terminal-Bench snapshot labels)."""
    t = n.split("-")
    while t and t[-1].isdigit():
        d = t[-1]
        if len(d) >= 6 or (len(d) == 4 and 1 <= int(d[:2]) <= 12):
            t.pop()
        else:
            break
    return "-".join(t)


def _split_effort(n):
    """'gemini-4-neon-extra-high' -> ('gemini-4-neon','xhigh'). Bare -> effort ''."""
    t = n.split("-")
    if len(t) >= 2 and t[-2:] == ["extra", "high"]:
        return "-".join(t[:-2]), "xhigh"
    if len(t) >= 2 and t[-1] in _EFFORT_RANK:
        return "-".join(t[:-1]), t[-1]
    return n, ""


def norm_key(s):
    """Full pipeline -> (family, effort)."""
    return _split_effort(_strip_date(_base_norm(s)))


def _vocab_from_pool(pool_path):
    """Candidate family vocabulary from pool rows (`alias|resolved|lane|tier`)
    or bare ids, one per line. Includes alias-normalized forms too, so a bench row
    can land on an alias-shaped family as well as the resolved one."""
    fams = set()
    try:
        with open(pool_path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                parts = line.split("|")
                cand = parts[1] if len(parts) >= 2 else parts[0]
                fam, _ = norm_key(cand)
                if fam:
                    fams.add(fam)
                if len(parts) >= 2:
                    af, _ = norm_key(parts[0])
                    if af:
                        fams.add(af)
    except OSError:
        pass
    return fams


def match_family(name, vocab):
    """-> (family, effort, matched). Order: exact, effort-strip+exact, suffix,
    effort-strip+suffix. Suffix hits take the LONGEST family ('sonnet-5-5' binds
    'claude-sonnet-5-5', never a bare 'sonnet')."""
    n = _strip_date(_base_norm(name))
    b, e = _split_effort(n)
    if n in vocab:
        return n, "", True
    if b != n and b in vocab:
        return b, e, True
    for eff, key in (("", n), (e, b)):
        if not key:
            continue
        hits = [f for f in vocab if f != key and f.endswith("-" + key)]
        if hits:
            hits.sort(key=len, reverse=True)
            return hits[0], eff, True
    return (n or b), e, False


# ---------------------------------------------------------------------------
# Source parsers. Each returns (rows, as_of, err). A parser NEVER raises; a
# shape change yields err + empty rows so the caller can flag the source stale.
# ---------------------------------------------------------------------------
def parse_cursorbench(text):
    m = re.search(r"<table[^>]*>(.*?)</table>", text, re.S)
    if not m:
        return [], "", "no <table> on page"
    rows = []
    for tr in re.findall(r"<tr[^>]*>(.*?)</tr>", m.group(1), re.S):
        cells = [re.sub(r"<[^>]+>", "", c).strip()
                 for c in re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)]
        if len(cells) < 6 or not cells[0].isdigit():
            continue
        def num(x):
            x = re.sub(r"[^\d.]", "", x)
            return float(x) if x else None
        rows.append({"name": cells[1], "score": num(cells[2]),
                     "cost": num(cells[3]), "tokens": num(cells[4]),
                     "steps": num(cells[5])})
    # Two identical responsive tables ship on the page; dedupe by name.
    seen, dedup = set(), []
    for r in rows:
        if r["name"] in seen:
            continue
        seen.add(r["name"])
        dedup.append(r)
    as_of = ""
    dates = re.findall(r'dateTime="(\d{4}-\d{2}-\d{2})"', text)
    if dates:
        as_of = max(dates)
    return dedup, as_of, ""


def _json_island_array(text, key='"rows":['):
    """Terminal-Bench embeds the leaderboard as an ESCAPED JSON string island.
    Unescape \\" -> " then bracket-match the rows array (string-aware)."""
    i = text.find("leaderboard_id")
    if i < 0:
        return None
    seg = text[max(0, i - 5000):i + 600000].replace('\\"', '"')
    ri = seg.find(key)
    if ri < 0:
        return None
    start = seg.find("[", ri)
    if start < 0:
        return None
    depth, j, instr, esc = 0, start, False, False
    while j < len(seg):
        c = seg[j]
        if esc:
            esc = False
        elif c == "\\":
            esc = True
        elif c == '"':
            instr = not instr
        elif not instr:
            if c == "[":
                depth += 1
            elif c == "]":
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(seg[start:j + 1])
                    except Exception:
                        return None
        j += 1
    return None


def parse_tbench(text):
    arr = _json_island_array(text)
    if arr is None:
        return [], "", "no embedded leaderboard JSON"
    rows, as_of = [], ""
    for r in arr:
        try:
            md = r["metadata"]
            mm = r["metrics"]
            n = mm.get("n_trials") or r.get("n_trials") or 0
            cost = mm.get("total_cost_usd")
            rows.append({
                "name": md["model_display"]["label"],
                "agent": md.get("agent_display", {}).get("label", ""),
                "effort": md.get("reasoning_effort", ""),
                "score": mm.get("accuracy"),
                "cost": (cost / n) if cost is not None and n else None,
                "tokens": (mm.get("total_tokens") or 0) / n if n else None,
                "secs": mm.get("avg_trial_duration_sec"),
                "as_of": md.get("date", ""),
            })
            as_of = max(as_of, md.get("date", "") or "")
        except Exception:
            continue
    return rows, as_of, ""


def parse_orbench(text):
    try:
        data = json.loads(text)
        as_of = data.get("meta", {}).get("as_of", "")
    except Exception:
        return [], "", "invalid JSON"
    rows = []
    for d in data.get("data") or []:
        slug = d.get("model_permaslug") or ""
        if not slug:
            continue
        scores = {k: d.get(k) for k in (
            "intelligence_index", "coding_index", "agentic_index",
            "engineering_index", "finance_index", "legal_index",
            "healthcare_index", "economics_index", "strategy_index")
            if d.get(k) is not None}
        pr = d.get("pricing") or {}
        rows.append({"name": slug, "scores": scores,
                     "price_in": pr.get("prompt"), "price_out": pr.get("completion"),
                     "as_of": as_of})
    return rows, as_of, ""


def parse_endpoints(text):
    """Merged cache shape: {"fetched_at": epoch, "models": {id: {endpoints:[...]}}}."""
    try:
        data = json.loads(text)
    except Exception:
        return [], "", "invalid JSON"
    rows = []
    for mid, body in (data.get("models") or {}).items():
        eps = body.get("endpoints") or []
        tps = sorted(e["throughput_last_30m"]["p50"] for e in eps
                     if (e.get("throughput_last_30m") or {}).get("p50"))
        lat = sorted(e["latency_last_30m"]["p50"] for e in eps
                     if (e.get("latency_last_30m") or {}).get("p50"))
        if not tps and not lat:
            continue
        midx = len(tps) // 2
        lidx = len(lat) // 2
        rows.append({
            "name": mid, "providers": len(eps),
            "tps_p50": tps[midx] if tps else None,
            "lat_p50_ms": lat[lidx] if lat else None,
            "as_of": str(data.get("fetched_at") or ""),
        })
    return rows, str(data.get("fetched_at") or ""), ""


_SOURCES = (("cursorbench", "cursorbench.html", parse_cursorbench),
            ("tbench", "tbench.html", parse_tbench),
            ("orbench", "or-bench.json", parse_orbench),
            ("endpoints", "or-endpoints.json", parse_endpoints))


def _meta_read(path):
    d = {}
    try:
        with open(path) as fh:
            for line in fh:
                k, _, v = line.partition("=")
                d[k.strip()] = v.rstrip("\n")
    except OSError:
        pass
    return d


def _meta_write(path, d):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        for k, v in d.items():
            fh.write("%s=%s\n" % (k, v))
    os.replace(tmp, path)


def cmd_parse(advise_dir, pool_path):
    vocab = _vocab_from_pool(pool_path)
    out_path = os.path.join(advise_dir, "rows.jsonl")
    tmp_path = out_path + ".tmp"
    total, unmatched_total = 0, 0
    with open(tmp_path, "w") as out:
        for source, fname, fn in _SOURCES:
            raw = os.path.join(advise_dir, fname)
            meta_path = os.path.join(advise_dir, source + ".meta")
            meta = _meta_read(meta_path)
            try:
                text = open(raw, errors="replace").read()
            except OSError:
                meta.update(status="missing", rows="0")
                _meta_write(meta_path, meta)
                continue
            raw_rows, as_of, err = fn(text)
            if err:
                meta.update(status="parse-failed:" + err, rows="0")
                _meta_write(meta_path, meta)
                continue
            if not raw_rows:
                meta.update(status="parse-empty", rows="0")
                _meta_write(meta_path, meta)
                continue
            unmatched = []
            for r in raw_rows:
                nm = r.pop("name")
                fam, eff, ok = match_family(nm, vocab)
                if r.get("effort"):
                    eff = _base_norm(r.pop("effort")) or eff
                elif "effort" in r:
                    r.pop("effort")
                rec = {"family": fam, "effort": eff, "source": source,
                       "matched": ok, "name": nm}
                rec.update(r)
                if not ok:
                    unmatched.append(nm)
                out.write(json.dumps(rec, separators=(",", ":")) + "\n")
            total += len(raw_rows)
            unmatched_total += len(unmatched)
            meta.update(status="ok", rows=str(len(raw_rows)),
                        unmatched=str(len(unmatched)),
                        unmatched_names="|".join(unmatched[:12]))
            if as_of:
                meta["as_of"] = as_of
            _meta_write(meta_path, meta)
    os.replace(tmp_path, out_path)
    print("parsed %d source rows (%d unmatched) -> %s"
          % (total, unmatched_total, out_path))
    return 0


# ---------------------------------------------------------------------------
# factors: join candidates (stdin `alias|resolved|lane|tier`) against rows.jsonl.
# ---------------------------------------------------------------------------
# Lane -> Terminal-Bench agent scaffold. Lane names are our lane codes, not a
# model list; an unlisted lane uses the family's best-accuracy row.
_TB_AGENT = {"cc": "claude code", "cx": "codex", "gm": "antigravity cli",
             "agy": "antigravity cli"}

# Per-class quality source priority. cb=CursorBench, tb=Terminal-Bench,
# orb:<idx>=OpenRouter/AA index. First non-empty wins; empty falls back to the
# caller's legacy bench score (tier proxy).
_Q_PRIORITY = {
    "code": ("cb", "tb", "orb:engineering_index", "orb:intelligence_index"),
    "agentic": ("tb", "cb", "orb:agentic_index", "orb:intelligence_index"),
    "reasoning": ("orb:intelligence_index", "tb", "cb"),
    "creative": ("orb:intelligence_index",),
    "simple": ("orb:intelligence_index",),
}

# Cost source priority per class: measured $/task first (class-appropriate
# bench), then list-price x measured tokens estimate.
_C_PRIORITY = {"agentic": ("tb", "cb"), "code": ("cb", "tb")}


def _nearest(rows, want_eff):
    """Pick a row dict from rows (each with 'effort') closest to want_eff rung."""
    if not rows:
        return None
    want = _EFFORT_RANK.get(want_eff, -1)
    def key(r):
        e = r.get("effort") or ""
        if e == want_eff:
            return (0, 0)
        re_ = _EFFORT_RANK.get(e, -1)
        d = abs(re_ - want) if want >= 0 and re_ >= 0 else 9
        return (1, d)
    return sorted(rows, key=key)[0]


def cmd_factors(advise_dir, category, want_eff):
    path = os.path.join(advise_dir, "rows.jsonl")
    try:
        rows = [json.loads(l) for l in open(path) if l.strip()]
    except OSError:
        return 1
    cb, tb, orb, ep = {}, {}, {}, {}
    tok_pool = []
    # Read candidates first: unmatched source rows are re-matched HERE against the
    # lane-resolved ids (opus -> claude-opus-5-5), because the parse-time vocab only
    # knew the bare aliases. match_family's exact/suffix order applies unchanged.
    cand_lines = [l.rstrip("\n") for l in sys.stdin]
    vocab = set()
    for line in cand_lines:
        parts = line.split("|")
        if len(parts) < 4:
            continue
        for nm in (parts[1], parts[0]):
            f0, _ = norm_key(nm)
            if f0:
                vocab.add(f0)
    for r in rows:
        if r.get("tokens"):
            tok_pool.append(r["tokens"])
        f = r.get("family")
        if not r.get("matched"):
            f2, _, ok = match_family(r.get("name") or "", vocab)
            if not ok:
                continue
            f = f2
        if r["source"] == "cursorbench":
            cb.setdefault(f, []).append(r)
        elif r["source"] == "tbench":
            tb.setdefault(f, []).append(r)
        elif r["source"] == "orbench":
            orb[f] = r
        elif r["source"] == "endpoints":
            ep[f] = r
    tok_pool.sort()
    median_tok = tok_pool[len(tok_pool) // 2] if tok_pool else 0

    def tb_pick(fam, lane, eff=""):
        cands = tb.get(fam) or []
        agent = _TB_AGENT.get(lane, "")
        if agent:
            mine = [r for r in cands if (r.get("agent") or "").lower() == agent]
            if mine:
                cands = mine
        if eff:
            exact = [r for r in cands if (r.get("effort") or "") == eff]
            if exact:
                return _nearest(exact, eff)
            return None
        return _nearest(cands, want_eff) or \
            (max(cands, key=lambda r: r.get("score") or 0) if cands else None)

    def emit(out_id, cbrow, tbrow, orow, erow):
        q, qsrc = "", ""
        for src in _Q_PRIORITY.get(category, _Q_PRIORITY["simple"]):
            if src == "cb" and cbrow and cbrow.get("score") is not None:
                q, qsrc = cbrow["score"], "cursorbench"
            elif src == "tb" and tbrow and tbrow.get("score") is not None:
                q, qsrc = tbrow["score"], "tbench"
            elif src.startswith("orb:") and orow:
                v = (orow.get("scores") or {}).get(src[4:])
                if v is not None:
                    q, qsrc = v, "or-bench:" + src[4:]
            if q != "":
                break

        cost, csrc = "", ""
        for src in _C_PRIORITY.get(category, ("cb", "tb")):
            row = cbrow if src == "cb" else tbrow
            if row and row.get("cost") is not None:
                cost, csrc = row["cost"], ("cursorbench" if src == "cb" else "tbench")
                break
        tokens = ""
        if cost == "":
            est_tok = (cbrow or {}).get("tokens") or (tbrow or {}).get("tokens") or median_tok
            pin = (orow or {}).get("price_in")
            pout = (orow or {}).get("price_out")
            try:
                if est_tok and pin is not None:
                    # 75/25 in/out blend of list price over measured-or-median tokens/task.
                    cost = est_tok * (0.75 * float(pin) + 0.25 * float(pout or 0))
                    csrc = "est:list-price"
                    tokens = est_tok
            except (TypeError, ValueError):
                pass
            if cost == "" and not est_tok and median_tok:
                tokens = median_tok   # let the caller estimate from models.json price
            elif cost == "" and est_tok:
                tokens = est_tok      # tokens known, price unknown -> caller may still estimate
        else:
            tokens = (cbrow or tbrow or {}).get("tokens") or ""

        sys.stdout.write("|".join(str(x) for x in (
            out_id,
            q, qsrc,
            ("%.4f" % cost if isinstance(cost, float) else cost), csrc,
            ("%.0f" % tokens if isinstance(tokens, float) else tokens),
            (erow or {}).get("tps_p50") or "",
            (erow or {}).get("lat_p50_ms") or "",
            (tbrow or {}).get("secs") or "",
        )) + "\n")

    for line in cand_lines:
        parts = line.split("|")
        if len(parts) < 4:
            continue
        alias, resolved, lane = parts[0], parts[1], parts[2]
        fam, cand_eff = norm_key(resolved)
        eff = cand_eff or want_eff
        orow = orb.get(fam)
        erow = ep.get(fam)
        # Pinned-effort candidates (fable@high) emit ONE row at that effort —
        # re-expanding them produced fable@high@low nonsense.
        if "@" in resolved:
            emit(resolved, _nearest(cb.get(fam), eff), tb_pick(fam, lane), orow, erow)
            continue
        # Every effort the family posts is its own candidate row (resolved@eff):
        # Opus 5.5 low/medium/high/xhigh/max have different scores AND prices.
        effs = sorted({r.get("effort") for r in (cb.get(fam) or []) + (tb.get(fam) or [])
                       if r.get("effort")})
        if not effs:
            emit(resolved, _nearest(cb.get(fam), eff), tb_pick(fam, lane), orow, erow)
            continue
        for e in effs:
            cbx = [r for r in (cb.get(fam) or []) if (r.get("effort") or "") == e]
            emit("%s@%s" % (resolved, e), _nearest(cbx, e) if cbx else None,
                 tb_pick(fam, lane, e), orow, erow)
    return 0


def main(argv):
    def opt(name, default=""):
        return argv[argv.index(name) + 1] if name in argv else default
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "parse":
        return cmd_parse(opt("--dir"), opt("--pool"))
    if cmd == "factors":
        return cmd_factors(opt("--dir"), opt("--category", "simple"),
                           opt("--effort", "high"))
    if cmd == "norm":
        for line in sys.stdin:
            n = line.rstrip("\n")
            fam, eff = norm_key(n)
            sys.stdout.write("%s\t%s\t%s\n" % (n, fam, eff))
        return 0
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
