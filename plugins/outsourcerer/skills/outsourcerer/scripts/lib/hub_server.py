#!/usr/bin/env python3
"""Mission Control local server for outsourcerer hub serve.

Loopback only (127.0.0.1), Python 3 standard library only. GET / and
/assets/* are public static content (no data); every API route takes the
X-Hub-Token header.
Endpoints: GET / , GET /api/projects, GET /api/answers, POST /api/answers,
POST /api/refresh, POST /api/projects/<id>/status (Mark done / Move back). Re-exports every REFRESH_SECS seconds in a background
thread, but only while a page has polled within IDLE_SECS and only when
state under OSRC_HOME actually changed (idle dashboards cost no CPU).
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import socketserver


class HubHTTPServer(ThreadingHTTPServer):
    """ThreadingHTTPServer without the reverse-DNS lookup in server_bind. The stock bind calls
    socket.getfqdn(host), which can hang for many seconds on a macOS CI runner before the URL is
    printed (CI run 5: no URL after 24 s). The name is only used for logging; the bind address is it."""
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port

REFRESH_SECS = int(os.environ.get("OSRC_HUB_REFRESH_SECS") or 30)
# A first GET /api/projects waits this long for the startup export, then answers {"starting": true}
# so the page (15 s fetch abort) keeps "Loading" and asks again instead of failing (MC-8 r2).
STARTING_WAIT = float(os.environ.get("OSRC_HUB_STARTING_WAIT") or 10)
IDLE_SECS = int(os.environ.get("OSRC_HUB_IDLE_SECS") or 300)
ANSWER_MAX = 16384
# Directories whose mtimes count as "state changed" for the refresh loop.
# Every tree the export reads must be here or a change under it never wakes
# a re-export (r4 smaller: autodetach and review were missing).
WATCH_DIRS = ("jobs", "hub", "owners", "remote", "autodetach", "review")
WATCH_FILES = ("rate-limits.json",)
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}--[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
# Project slugs, same rule as hub.sh _osrc_hub_slug_ok: no leading dot, <=128.
# Always fullmatch: re.match with "$" also accepts a trailing newline (MC-5 #5).
SLUG_RE = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$")
STATUS_PATH_RE = re.compile(r"^/api/projects/([^/]+)/status$")


def _write_small(path, text):
    """Atomic best-effort write of a small state file (never raises)."""
    try:
        tmp = "%s.tmp.%d" % (path, os.getpid())
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except OSError:
        pass


class Hub:
    def __init__(self, osrc_home, engine, page_path, token):
        self.osrc_home = osrc_home
        self.engine = engine
        self.page_path = page_path
        # Vendored assets (fonts, licences) live next to the page and are the
        # only files served without a token — they are static and read-only.
        self.assets_dir = os.path.join(
            os.path.dirname(os.path.abspath(page_path)), "hub-assets")
        self.token = token
        self.answers_dir = os.path.join(osrc_home, "hub", "answers")
        os.makedirs(self.answers_dir, mode=0o700, exist_ok=True)
        # Mark done overrides go to hub/status/<slug>.json (write_status); hub export
        # merges them last, so no card write can undo a status the user set.
        self.export_file = os.path.join(osrc_home, "hub", "export.json")
        self.cache = None          # {"generated_at": int, "projects": [...]}
        self.export_lock = threading.Lock()
        self.plans_finished = 0.0
        self.cache_ts = 0.0
        self.export_error = ""
        self.lock = threading.Lock()
        self.export_lock = threading.Lock()
        self.last_poll = time.time()
        self.last_state_mtime = -1.0
        # Set once the first export has finished (ok or not). main() prints the URL before that
        # export runs (a slow export kept the URL back past the CI wait, MC-8); data requests wait here.
        self.first_export = threading.Event()
        self.warming = False       # serving the last saved export while the startup export runs
        self.fresh_export = threading.Event()   # the startup export itself finished (warm start or not)
        # CSP hashes for the page's inline <script> blocks, computed once so
        # script-src can drop 'unsafe-inline' (r4 finding 2). The page is one
        # self-contained file, so its blocks are knowable at startup.
        self.script_hashes = self._script_hashes()
        self.tab_seen = 0.0
        self.keys_file = os.path.join(osrc_home, "hub", "keys.json")
        self.remember_key()

    # Keys this OSRC_HOME's hubs have served, as salted SHA-256 (never the key itself), in
    # hub/keys.json (0600): [{salt, hash, current, retired_at}]. A key stops being current when a hub
    # starts with a different one; it is accepted by /reopen for KEY_TTL after that, newest KEY_KEEP only.
    KEY_TTL = 7 * 86400
    KEY_KEEP = 5

    @staticmethod
    def _key_hash(salt, key):
        return hashlib.sha256((salt + ":" + key).encode("utf-8", "replace")).hexdigest()

    def _load_keys(self):
        try:
            with open(self.keys_file, encoding="utf-8") as f:
                keys = json.load(f)
            return [k for k in keys if isinstance(k, dict) and k.get("salt") and k.get("hash")]
        except (OSError, ValueError):
            return []

    def _is_key(self, entry, key):
        return hmac.compare_digest(self._key_hash(entry["salt"], key), entry["hash"])

    def remember_key(self):
        now = int(time.time())
        keys = []
        for k in self._load_keys():
            if self._is_key(k, self.token):
                continue
            if k.get("current"):
                k["current"] = False
                k["retired_at"] = now
            if now - int(k.get("retired_at") or 0) < self.KEY_TTL:
                keys.append(k)
        salt = os.urandom(16).hex()
        keys = keys[-(self.KEY_KEEP - 1):] + [{"salt": salt, "hash": self._key_hash(salt, self.token), "current": True}]
        tmp = "%s.tmp.%d" % (self.keys_file, os.getpid())
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(keys, f)
            os.replace(tmp, self.keys_file)
        except OSError:
            pass

    def retired_key_ok(self, key):
        """True when <key> is a key an earlier hub served here, retired less than KEY_TTL ago."""
        if not key or len(key) > 256:
            return False
        now = int(time.time())
        for k in self._load_keys():
            if not k.get("current") and now - int(k.get("retired_at") or 0) < self.KEY_TTL and self._is_key(k, key):
                return True
        return False

    def note_tab(self):
        """A tab fetched data with the current token. The engine reads hub/tab.seen to decide
        whether work starting should pop Mission Control (lib/mc_alive.sh). Throttled to 10 s."""
        now = time.time()
        if now - self.tab_seen < 10:
            return
        self.tab_seen = now
        _write_small(os.path.join(self.osrc_home, "hub", "tab.seen"), "%d\n" % int(now))

    def _script_hashes(self):
        try:
            with open(self.page_path, "rb") as f:
                data = f.read()
        except OSError:
            return []
        return [
            "sha256-" + base64.b64encode(hashlib.sha256(m.group(1)).digest()).decode()
            for m in re.finditer(rb"<script>(.*?)</script>", data, re.S)
        ]

    def state_mtime(self):
        # Newest mtime anywhere state can live; cheap walk, no file reads.
        best = 0.0
        for name in WATCH_FILES:
            try:
                best = max(best, os.path.getmtime(os.path.join(self.osrc_home, name)))
            except OSError:
                pass
        for sub in WATCH_DIRS:
            root = os.path.join(self.osrc_home, sub)
            for dirpath, _dirnames, filenames in os.walk(root):
                for n in filenames:
                    try:
                        best = max(best, os.path.getmtime(os.path.join(dirpath, n)))
                    except OSError:
                        continue
        return best

    def run_export(self, timeout=300, force=False, check_plans=False):
        requested = time.monotonic()
        deadline = requested + timeout
        if check_plans:
            if not self.fresh_export.wait(timeout):
                raise TimeoutError("plans check timed out waiting for startup")
            if not self.export_lock.acquire(timeout=max(0, deadline - time.monotonic())):
                raise TimeoutError("plans check timed out waiting for export")
        else:
            self.export_lock.acquire()
        try:
            if check_plans and self.plans_finished >= requested:
                return self.cache
            if check_plans:
                timeout = deadline - time.monotonic()
                if timeout <= 0:
                    raise TimeoutError("plans check deadline expired")
            data = self._export(timeout, force, check_plans)
            if check_plans:
                self.plans_finished = time.monotonic()
            return data
        finally:
            self.export_lock.release()

    def _export(self, timeout, force, check_plans):
        env = dict(os.environ)
        env["OSRC_HOME"] = self.osrc_home
        # Settled-project cache + stale-while-revalidate limits (hub-perf.sh, MC2 r2 #4).
        env.setdefault("OSRC_HUB_FAST", "1")
        if force:
            env["OSRC_HUB_REFRESH"] = "1"
        if check_plans:
            env.update(OSRC_HUB_CHECK_PLANS="1", OSRC_PROBE_SYNC="1", OSRC_PROBE_TTL="0",
                       OSRC_PROBE_TTL_CODEX="0", OSRC_PROBE_TTL_AGY="0")
        proc = subprocess.run(
            [self.engine, "hub", "export"],
            capture_output=True, encoding="utf-8", errors="replace", timeout=timeout, env=env,
        )
        if proc.returncode != 0:
            raise RuntimeError((proc.stderr or proc.stdout or "export failed").strip()[:300])
        data = json.loads(proc.stdout)
        if not isinstance(data, dict) or "projects" not in data:
            raise RuntimeError("export output is not a SCHEMA document")
        data["exported_at"] = int(time.time())
        data = self._with_status(data)
        self._safe_write("", "export.json", data)
        with self.lock:
            self.cache = data
            self.cache_ts = time.time()
            self.export_error = ""
        self.last_state_mtime = self.state_mtime()
        return data

    def refresh_loop(self):
        while True:
            try:
                if time.time() - self.last_poll <= IDLE_SECS \
                        and (self.state_mtime() != self.last_state_mtime or time.time() - self.cache_ts > REFRESH_SECS + 10):
                    self.run_export()
            except Exception as e:  # keep serving last good cache; surface the error
                with self.lock:
                    self.export_error = str(e)[:300]
            time.sleep(REFRESH_SECS)

    def load_saved(self):
        """Warm start: serve the last export.json this hub wrote while the first export runs, so a
        restart never shows an endless "Loading" (a cold export took about a minute, 0.16.3)."""
        try:
            if os.path.islink(self.export_file) or not os.path.isfile(self.export_file) \
                    or os.path.getsize(self.export_file) > 16 * 1024 * 1024:
                return False
            with open(self.export_file, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            return False
        if not isinstance(data, dict) or not isinstance(data.get("projects"), list):
            return False
        with self.lock:
            self.cache = data
            self.cache_ts = time.time()
            self.warming = True
        return True

    def _with_status(self, data):
        # A warm snapshot can predate a saved click, including after a failed export.
        projects = []
        for project in data.get("projects", []):
            slug = project.get("id")
            if isinstance(slug, str) and SLUG_RE.fullmatch(slug):
                rec = self._read_project_file("status", slug)
                if rec.get("shippedBy") == "user":
                    project = dict(project, **{k: rec[k] for k in
                                   ("shippedAt", "shippedBy", "prevStatus") if k in rec})
                    project["status"] = "shipped"
                elif rec.get("restoredBy") == "user" and project.get("status") == "shipped":
                    card = self._read_card(slug)
                    same_card = ("cardStatus" in rec and card.get("status") == rec["cardStatus"]
                                 and card.get("shippedAt") == rec.get("cardShippedAt"))
                    if same_card or (project.get("shippedBy") == "user" and card.get("status") != "shipped"):
                        status = card.get("status")
                        if not status or status == "shipped":
                            status = rec.get("prevStatus") or "building"
                        project = dict(project, status=status)
                        for key in ("shippedBy", "shippedAt", "prevStatus"):
                            project.pop(key, None)
            projects.append(project)
        return dict(data, projects=projects)

    def projects_payload(self):
        data, error = self._projects_snapshot()
        return self._with_status(data), error

    def _projects_snapshot(self):
        self.first_export.wait(timeout=95)   # the startup export, not a second one racing it
        with self.lock:
            if self.cache is not None:
                return self.cache, self.export_error
        try:
            return self.run_export(), ""
        except Exception as e:
            with self.lock:
                if self.cache is not None:
                    return self.cache, str(e)[:300]
            return {"generated_at": int(time.time()), "projects": []}, str(e)[:300]

    def answers(self):
        out = {}
        try:
            names = os.listdir(self.answers_dir)
        except OSError:
            return out
        for n in names:
            if not n.endswith(".json"):
                continue
            try:
                with open(os.path.join(self.answers_dir, n), encoding="utf-8") as f:
                    out[n[:-5]] = json.load(f)
            except Exception:
                continue
        return out

    def write_answer(self, body):
        if not isinstance(body, dict):
            return None, "body must be a JSON object"
        aid = body.get("id")
        if not isinstance(aid, str) or not ID_RE.fullmatch(aid):
            return None, "bad answer id"
        choice = body.get("choice")
        note = body.get("note")
        if choice is None:
            choice = ""
        if note is None:
            note = ""
        # The page offers "your own answer" in the note, so a note alone is a full
        # answer (MC-4: a typed-only answer used to 400 and vanish). One of the two
        # must carry text.
        if not isinstance(choice, str) or len(choice) > 4000:
            return None, "bad choice"
        if not isinstance(note, str) or len(note) > 4000:
            return None, "bad note"
        if not choice.strip() and not note.strip():
            return None, "empty answer"
        rec = {
            "project": str(body.get("project") or "")[:200],
            "decision": str(body.get("decision") or "")[:200],
            "question": str(body.get("question") or "")[:2000],
            "choice": choice.strip()[:4000],
            "note": note.strip()[:4000],
            "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        try:
            self._safe_write("answers", aid + ".json", rec)
        except OSError as e:
            return None, "cannot write answer: %s" % str(e)[:200]
        return rec, None

    # ---- symlink-safe writes (MC-5 #3) ----------------------------------------------------
    # Every file the server writes lives in <osrc_home>/hub[/<sub>]. A planted symlink (the
    # folder, the target, or a guessable temp name) must never redirect a write: the folder
    # must resolve to exactly where it should be, the temp file is created exclusively with
    # a random name (mkstemp, mode 600), and a symlinked target is refused.
    def _safe_dir(self, sub):
        parts = ("hub", sub) if sub else ("hub",)
        d = os.path.join(self.osrc_home, *parts)
        want = os.path.join(os.path.realpath(self.osrc_home), *parts)
        os.makedirs(d, mode=0o700, exist_ok=True)
        if os.path.islink(d) or os.path.realpath(d) != want:
            raise OSError("refusing %s: it is a symlink or resolves outside OSRC_HOME" % d)
        os.chmod(d, 0o700)
        return d

    def _safe_write(self, sub, name, obj):
        d = self._safe_dir(sub)
        path = os.path.join(d, name)
        if os.path.islink(path):
            raise FileExistsError("refusing %s: it is a symlink" % path)
        fd, tmp = tempfile.mkstemp(dir=d, prefix="." + name + ".", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(obj, f)
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        return path


    def write_status(self, slug, body):
        """POST /api/projects/<slug>/status {status: "shipped"|"restore"}.

        Returns (http_code, payload). The slug must match SLUG_RE AND name a
        project in the current export, so a request can never create a file
        for something that does not exist."""
        if not SLUG_RE.fullmatch(slug or ""):
            return 400, {"error": "bad project id"}
        if not isinstance(body, dict) or body.get("status") not in ("shipped", "restore"):
            return 400, {"error": "status must be shipped or restore"}
        payload, _err = self.projects_payload()
        cur = next((p for p in payload.get("projects", [])
                    if isinstance(p, dict) and p.get("id") == slug), None)
        if cur is None:
            return 404, {"error": "no such project"}
        now = time.time()
        iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
        prev = cur.get("prevStatus") if cur.get("status") == "shipped" else cur.get("status")
        if not prev or prev == "shipped":
            prev = "building"
        if body["status"] == "shipped":
            rec = {"status": "shipped", "shippedAt": iso, "shippedBy": "user",
                   "prevStatus": prev}
        else:
            # Move back (MC-5 #2): remember what the card said about shipping at
            # click time. The restore holds through any number of card rewrites
            # (orchestrators rewrite the whole card to bump pct or the stamp) and
            # yields only when the card says something new about shipping: a
            # different status or shippedAt than it had when the user clicked.
            card = self._read_card(slug)
            rec = {"restoredBy": "user", "restoredAt": iso, "prevStatus": prev,
                   "cardStatus": card.get("status"), "cardShippedAt": card.get("shippedAt")}
        try:
            self._safe_write("status", slug + ".json", rec)
        except OSError as e:
            return 409, {"error": str(e)[:300]}
        proj = self._with_status({"projects": [cur]})["projects"][0]
        return 200, {"ok": True, "override": rec, "project": proj}


    def _read_card(self, slug):
        return self._read_project_file("projects", slug)

    def _read_project_file(self, folder, slug):
        directory = os.path.join(self.osrc_home, "hub", folder)
        path = os.path.join(directory, slug + ".json")
        try:
            if os.path.islink(directory) or os.path.islink(path):
                return {}
            with open(path, encoding="utf-8", opener=lambda p, flags:
                      os.open(p, flags | os.O_NONBLOCK | os.O_NOFOLLOW)) as f:
                if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                    return {}
                card = json.load(f)
            return card if isinstance(card, dict) else {}
        except (OSError, ValueError):
            return {}


def make_handler(hub):
    class Handler(BaseHTTPRequestHandler):
        server_version = "outsourcerer-hub/1"
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            # Never log the token: strip the WHOLE query string off the request
            # line (a %-encoded key would dodge a literal 't=' scrub).
            line = re.sub(r"\?\S*", "", fmt % args)
            sys.stderr.write("[hub] %s\n" % line)

        def _host_ok(self):
            # Exact host:port match, lower-cased first: "LOCALHOST" passes, a
            # missing port or a userinfo trick ("127.0.0.1:P@evil") does not.
            host = (self.headers.get("Host") or "").split(",")[0].strip().lower()
            port = self.server.server_address[1]
            return host in ("127.0.0.1:%d" % port, "localhost:%d" % port, "[::1]:%d" % port)

        def _token_ok(self):
            # X-Hub-Token is the only credential, and it only guards data
            # routes. GET / and /assets/* are static and carry no state, so
            # they need none — which is what keeps a reload working after the
            # page strips ?t= from the address bar (r4 finding 1). ?t= itself
            # is read by the page's own script into sessionStorage; the server
            # never reads it, so a token never sits in an API URL or a log
            # line (review A3). No cookie exists (review finding 4).
            t = self.headers.get("X-Hub-Token", "")
            # compare_digest needs bytes on both sides; a non-ASCII token must not raise.
            return hmac.compare_digest(t.encode("utf-8", "replace"), hub.token.encode("utf-8"))

        def _post_origin_ok(self):
            # A browser POST must come from this server's own page. Origin is the
            # strong signal; Sec-Fetch-Site catches browsers that omit it. Absent
            # headers pass: non-browser clients send neither and the token gates.
            origin = (self.headers.get("Origin") or "").strip().lower()
            port = self.server.server_address[1]
            if origin and origin not in ("http://127.0.0.1:%d" % port,
                                         "http://localhost:%d" % port,
                                         "http://[::1]:%d" % port):
                return False
            sfs = (self.headers.get("Sec-Fetch-Site") or "").strip().lower()
            if sfs and sfs not in ("same-origin", "none"):
                return False
            return True

        def _sec_headers(self):
            # Strict CSP: everything the page loads comes from this server.
            # The inline script is whitelisted by hash rather than
            # 'unsafe-inline' (r4 finding 2); inline style stays allowed
            # because style attributes pepper the markup and hashes cannot
            # cover those. Nothing remote is reachable regardless (review A2).
            script_src = "script-src 'self'"
            if hub.script_hashes:
                script_src += " " + " ".join("'%s'" % h for h in hub.script_hashes)
            self.send_header(
                "Content-Security-Policy",
                "default-src 'self'; %s; "
                "style-src 'self' 'unsafe-inline'; font-src 'self'; "
                "img-src 'self' data:; connect-src 'self'; "
                "object-src 'none'; frame-ancestors 'none'; base-uri 'none'" % script_src)
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")

        def _send_json(self, obj, code=200):
            data = json.dumps(obj).encode()
            self.send_response(code)
            self._sec_headers()
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _send_asset(self, path):
            # /assets/<name> serves the vendored hub-assets directory only:
            # realpath containment + a small extension allowlist, so no
            # traversal and no engine/source files ever leave through it.
            base = os.path.realpath(hub.assets_dir)
            rel = urllib.parse.unquote(path[len("/assets/"):])
            full = os.path.realpath(os.path.join(base, rel))
            ext = os.path.splitext(full)[1].lstrip(".").lower()
            ctype = {"woff2": "font/woff2",
                     "js": "text/javascript; charset=utf-8",
                     "css": "text/css; charset=utf-8",
                     "txt": "text/plain; charset=utf-8"}.get(ext)
            if (not ctype or full == base
                    or not full.startswith(base + os.sep)
                    or not os.path.isfile(full)):
                return self._send_json({"error": "not found"}, 404)
            with open(full, "rb") as f:
                data = f.read()
            self.send_response(200)
            self._sec_headers()
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _deny(self):
            self._send_json({"error": "forbidden"}, 403)

        REOPEN_DENIED = {"error": "unknown key",
                         "text": "This tab's key is not one this Mission Control issued. Run outsourcerer mc to open the current one."}

        def _reopen(self):
            # POST /reopen with X-Hub-Old-Token: a tab holding a key an earlier hub here served (and
            # retired within 7 days) gets the current page URL. Same-origin POST only, loopback Host
            # (do_POST). A script with no old key, or an unknown one, gets 403 and nothing else.
            if not hub.retired_key_ok((self.headers.get("X-Hub-Old-Token") or "").strip()):
                return self._send_json(self.REOPEN_DENIED, 403)
            self._send_json({"url": "/?t=" + urllib.parse.quote(hub.token)})

        def do_GET(self):
            if not self._host_ok():
                return self._deny()
            u = urllib.parse.urlparse(self.path)
            path = u.path
            if path == "/reopen":
                return self._send_json(self.REOPEN_DENIED, 403)   # POST with the old key only
            if path.startswith("/assets/"):
                # A font fetch means a page is open — count it as a poll so the
                # idle timer reflects real use.
                hub.last_poll = time.time()
                return self._send_asset(path)
            if path in ("/", "/index.html"):
                # The page is a static shell with no data, same as the fonts:
                # served without the token so a reload (which stripped ?t=)
                # and a bare URL still render. With no token the page itself
                # says to open the link `hub serve` printed; the API behind
                # it stays header-token only (r4 finding 1).
                hub.last_poll = time.time()
                try:
                    with open(hub.page_path, "rb") as f:
                        data = f.read()
                except OSError:
                    return self._send_json({"error": "page missing"}, 500)
                self.send_response(200)
                self._sec_headers()
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(data)
                return
            if not self._token_ok():
                return self._deny()
            hub.last_poll = time.time()
            hub.note_tab()
            if path == "/api/projects":
                if not hub.first_export.wait(timeout=STARTING_WAIT):
                    return self._send_json({"generated_at": int(time.time()), "projects": [], "starting": True})
                payload, err = hub.projects_payload()
                if err:
                    payload["export_error"] = err
                self._send_json(payload)
            elif path == "/api/answers":
                self._send_json(hub.answers())
            else:
                self._send_json({"error": "not found"}, 404)

        def do_POST(self):
            if urllib.parse.urlparse(self.path).path == "/reopen":
                if not self._host_ok() or not self._post_origin_ok():
                    return self._deny()
                return self._reopen()
            if not self._host_ok() or not self._token_ok() or not self._post_origin_ok():
                return self._deny()
            hub.last_poll = time.time()
            u = urllib.parse.urlparse(self.path)
            try:
                n = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                n = 0
            if n < 0 or n > ANSWER_MAX:
                return self._send_json({"error": "bad body"}, 400)
            raw = self.rfile.read(n) if n > 0 else b""
            if u.path == "/api/refresh":
                # Refresh carries no payload; the page POSTs it empty.
                if u.query != "plans":
                    hub.fresh_export.wait()
                try:
                    data = hub.run_export(force=True, check_plans=(u.query == "plans"))
                except Exception as e:
                    return self._send_json({"error": str(e)[:300]}, 500)
                return self._send_json(data)
            if n <= 0:
                return self._send_json({"error": "bad body"}, 400)
            try:
                body = json.loads(raw.decode("utf-8", "replace"))
            except Exception:
                return self._send_json({"error": "bad json"}, 400)
            m = STATUS_PATH_RE.fullmatch(u.path)
            if m:
                code, out = hub.write_status(urllib.parse.unquote(m.group(1)), body)
                return self._send_json(out, code)
            if u.path == "/api/answers":
                rec, err = hub.write_answer(body)
                if err:
                    return self._send_json({"error": err}, 400)
                return self._send_json({"ok": True, "answer": rec})
            self._send_json({"error": "not found"}, 404)

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--page", required=True)
    ap.add_argument("--engine", required=True)
    ap.add_argument("--osrc-home", required=True)
    ap.add_argument("--no-open", action="store_true")
    ap.add_argument("--scan", type=int, default=0,
                    help="try the next free port, up to N after --port")
    args = ap.parse_args()

    token = os.environ.get("OSRC_HUB_TOKEN") or os.urandom(16).hex()
    hub = Hub(args.osrc_home, args.engine, args.page, token)

    # Fixed default port for a bookmarkable URL; --scan lets it slide to
    # the next free port and we say so (an explicit --port stays strict).
    httpd = None
    last_err = None
    for port in range(args.port, args.port + args.scan + 1):
        try:
            httpd = HubHTTPServer((args.bind, port), make_handler(hub))
            break
        except OSError as e:
            last_err = e
    if httpd is None:
        raise SystemExit("hub serve: no free port in %d..%d: %s"
                         % (args.port, args.port + args.scan, last_err))
    port = httpd.server_address[1]
    if port != args.port:
        sys.stderr.write("[hub] port %d busy — serving on %d instead\n" % (args.port, port))
    url = "http://127.0.0.1:%d/?t=%s" % (port, urllib.parse.quote(token))
    # Who serves this OSRC_HOME, so work starting can open the page once per hub process.
    serve_json = os.path.join(args.osrc_home, "hub", "serve.json")
    _write_small(serve_json, json.dumps({"pid": os.getpid(), "port": port, "started": int(time.time())}) + "\n")
    print("[outsourcerer] hub: %s" % url, flush=True)

    # The URL is out first; the first export then runs in the background and the first
    # /api/projects waits for it (projects_payload), so the first page load is still not empty.
    def first_then_loop():
        if hub.load_saved():
            hub.first_export.set()   # the saved copy answers at once; the fresh export replaces it
        try:
            hub.run_export()
        except Exception as e:
            sys.stderr.write("[hub] initial export failed (will retry): %s\n" % e)
        finally:
            with hub.lock:
                hub.warming = False
            hub.first_export.set()
            hub.fresh_export.set()
            sys.stderr.write("[hub] startup export done\n")
            sys.stderr.flush()
        hub.refresh_loop()
    threading.Thread(target=first_then_loop, daemon=True).start()

    if not args.no_open and os.environ.get("OSRC_HUB_NO_OPEN") != "1":
        try:
            webbrowser.open(url)
        except Exception:
            pass
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
