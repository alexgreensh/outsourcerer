#!/usr/bin/env python3
"""Mission Control local server for outsourcerer hub serve.

Loopback only (127.0.0.1), token-gated, Python 3 standard library only.
Endpoints: GET / , GET /api/projects, GET /api/answers, POST /api/answers,
POST /api/refresh. Re-exports every REFRESH_SECS seconds in a background thread.
"""
import argparse
import hmac
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.parse
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REFRESH_SECS = 30
ANSWER_MAX = 16384
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}--[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


class Hub:
    def __init__(self, osrc_home, engine, page_path, token):
        self.osrc_home = osrc_home
        self.engine = engine
        self.page_path = page_path
        self.token = token
        self.answers_dir = os.path.join(osrc_home, "hub", "answers")
        os.makedirs(self.answers_dir, exist_ok=True)
        self.export_file = os.path.join(osrc_home, "hub", "export.json")
        self.cache = None          # {"generated_at": int, "projects": [...]}
        self.cache_ts = 0.0
        self.export_error = ""
        self.lock = threading.Lock()

    def run_export(self, timeout=90):
        env = dict(os.environ)
        env["OSRC_HOME"] = self.osrc_home
        proc = subprocess.run(
            [self.engine, "hub", "export"],
            capture_output=True, text=True, timeout=timeout, env=env,
        )
        if proc.returncode != 0:
            raise RuntimeError((proc.stderr or proc.stdout or "export failed").strip()[:300])
        data = json.loads(proc.stdout)
        if not isinstance(data, dict) or "projects" not in data:
            raise RuntimeError("export output is not a SCHEMA document")
        data["exported_at"] = int(time.time())
        tmp = self.export_file + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, self.export_file)
        with self.lock:
            self.cache = data
            self.cache_ts = time.time()
            self.export_error = ""
        return data

    def refresh_loop(self):
        while True:
            try:
                self.run_export()
            except Exception as e:  # keep serving last good cache; surface the error
                with self.lock:
                    self.export_error = str(e)[:300]
            time.sleep(REFRESH_SECS)

    def projects_payload(self):
        with self.lock:
            if self.cache is not None and time.time() - self.cache_ts < REFRESH_SECS + 10:
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
                with open(os.path.join(self.answers_dir, n)) as f:
                    out[n[:-5]] = json.load(f)
            except Exception:
                continue
        return out

    def write_answer(self, body):
        if not isinstance(body, dict):
            return None, "body must be a JSON object"
        aid = body.get("id")
        if not isinstance(aid, str) or not ID_RE.match(aid):
            return None, "bad answer id"
        choice = body.get("choice")
        if not isinstance(choice, str) or not choice.strip() or len(choice) > 4000:
            return None, "bad choice"
        rec = {
            "project": str(body.get("project") or "")[:200],
            "decision": str(body.get("decision") or "")[:200],
            "question": str(body.get("question") or "")[:2000],
            "choice": choice.strip()[:4000],
            "note": str(body.get("note") or "")[:4000],
            "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        path = os.path.join(self.answers_dir, aid + ".json")
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(rec, f)
        os.replace(tmp, path)
        return rec, None


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
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            t = (q.get("t") or [""])[0]
            via = "query" if t else ""
            if not t:
                t = self.headers.get("X-OSRC-Token", "")
                via = "header" if t else ""
            if not t:
                for part in (self.headers.get("Cookie") or "").split(";"):
                    name, _, val = part.strip().partition("=")
                    if name == "osrc_hub_t":
                        t, via = val, "cookie"
                        break
            # compare_digest needs bytes on both sides; a non-ASCII token must not raise.
            ok = hmac.compare_digest(t.encode("utf-8", "replace"), hub.token.encode("utf-8"))
            # A tokened GET that did NOT use the cookie plants one, so the bare
            # URL (page strips ?t= for the address bar) still works on reload.
            self._want_cookie = ok and via in ("query", "header") and self.command == "GET"
            return ok

        def _send_cookie(self):
            if getattr(self, "_want_cookie", False):
                self.send_header(
                    "Set-Cookie",
                    "osrc_hub_t=%s; Path=/; HttpOnly; SameSite=Strict" % hub.token,
                )

        def _send_json(self, obj, code=200):
            data = json.dumps(obj).encode()
            self.send_response(code)
            self._send_cookie()
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _deny(self):
            self._send_json({"error": "forbidden"}, 403)

        def do_GET(self):
            if not self._host_ok() or not self._token_ok():
                return self._deny()
            u = urllib.parse.urlparse(self.path)
            path = u.path
            if path in ("/", "/index.html"):
                try:
                    with open(hub.page_path, "rb") as f:
                        data = f.read()
                except OSError:
                    return self._send_json({"error": "page missing"}, 500)
                self.send_response(200)
                self._send_cookie()
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(data)
            elif path == "/api/projects":
                payload, err = hub.projects_payload()
                if err:
                    payload["export_error"] = err
                self._send_json(payload)
            elif path == "/api/answers":
                self._send_json(hub.answers())
            else:
                self._send_json({"error": "not found"}, 404)

        def do_POST(self):
            if not self._host_ok() or not self._token_ok():
                return self._deny()
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
                try:
                    data = hub.run_export()
                except Exception as e:
                    return self._send_json({"error": str(e)[:300]}, 500)
                return self._send_json(data)
            if n <= 0:
                return self._send_json({"error": "bad body"}, 400)
            try:
                body = json.loads(raw.decode("utf-8", "replace"))
            except Exception:
                return self._send_json({"error": "bad json"}, 400)
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
    args = ap.parse_args()

    token = os.environ.get("OSRC_HUB_TOKEN") or os.urandom(16).hex()
    hub = Hub(args.osrc_home, args.engine, args.page, token)

    # First export synchronously so the first page load is not empty.
    try:
        hub.run_export()
    except Exception as e:
        sys.stderr.write("[hub] initial export failed (will retry): %s\n" % e)

    threading.Thread(target=hub.refresh_loop, daemon=True).start()

    httpd = ThreadingHTTPServer((args.bind, args.port), make_handler(hub))
    port = httpd.server_address[1]
    url = "http://127.0.0.1:%d/?t=%s" % (port, urllib.parse.quote(token))
    print("[outsourcerer] hub: %s" % url, flush=True)
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
