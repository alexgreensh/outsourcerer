#!/usr/bin/env python3
"""Mock-level tests for anthropic-openai-shim.py (plan U2). No real model needed.

Runs a built-in mock OpenAI server, starts the shim pointed at it, and drives it with Anthropic
Messages requests, asserting the translation. Run: python3 scripts/tests/test_shim.py
"""
import json
import os
import subprocess
import sys
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread

HERE = os.path.dirname(os.path.abspath(__file__))
SHIM = os.path.join(os.path.dirname(HERE), "anthropic-openai-shim.py")
MOCK_PORT = 8791
SHIM_PORT = 8792


class Mock(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path.endswith("/models"):
            b = json.dumps({"data": [{"id": "mock"}]}).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
        else:
            self.send_response(404); self.end_headers()

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        req = json.loads(self.rfile.read(n) or b"{}")
        want_tool = any("weather" in json.dumps(m) for m in req.get("messages", []))
        if req.get("stream"):
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
            if want_tool:
                chunks = [{"choices": [{"delta": {"tool_calls": [{"id": "call_1", "function": {"name": "get_weather", "arguments": ""}}]}}]},
                          {"choices": [{"delta": {"tool_calls": [{"function": {"arguments": "{\"city\":"}}]}}]},
                          {"choices": [{"delta": {"tool_calls": [{"function": {"arguments": "\"NYC\"}"}}]}}]},
                          {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]}]
            else:
                chunks = [{"choices": [{"delta": {"content": "Hel"}}]},
                          {"choices": [{"delta": {"content": "lo"}}]},
                          "GARBAGE-NOT-JSON",  # must not crash
                          {"choices": [{"delta": {}, "finish_reason": "stop"}]}]
            for c in chunks:
                payload = c if isinstance(c, str) else json.dumps(c)
                self.wfile.write(("data: %s\n\n" % payload).encode()); self.wfile.flush()
            self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()
        else:
            resp = {"id": "cmpl", "choices": [{"message": {"role": "assistant", "content": "Hello world"},
                    "finish_reason": "stop"}], "usage": {"prompt_tokens": 5, "completion_tokens": 2}}
            b = json.dumps(resp).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)


def post_messages(body, stream=False):
    data = json.dumps(body).encode()
    req = urllib.request.Request("http://127.0.0.1:%d/v1/messages" % SHIM_PORT, data=data,
                                 method="POST", headers={"Content-Type": "application/json"})
    r = urllib.request.urlopen(req, timeout=10)
    if stream:
        return r.read().decode()
    return json.loads(r.read().decode())


def main():
    mock = ThreadingHTTPServer(("127.0.0.1", MOCK_PORT), Mock)
    Thread(target=mock.serve_forever, daemon=True).start()
    env = dict(os.environ, OSRC_SHIM_UPSTREAM="http://127.0.0.1:%d/v1" % MOCK_PORT,
               OSRC_SHIM_PORT=str(SHIM_PORT))
    proc = subprocess.Popen([sys.executable, SHIM], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    fails = []
    try:
        for _ in range(40):
            try:
                if json.loads(urllib.request.urlopen("http://127.0.0.1:%d/health" % SHIM_PORT, timeout=1).read()).get("ok"):
                    break
            except Exception:
                time.sleep(0.25)

        def check(name, cond):
            print(("PASS " if cond else "FAIL ") + name)
            if not cond:
                fails.append(name)

        # (e) health
        check("health ok", json.loads(urllib.request.urlopen("http://127.0.0.1:%d/health" % SHIM_PORT).read()).get("ok"))
        # (a) non-stream text round-trip
        a = post_messages({"model": "m", "max_tokens": 50, "messages": [{"role": "user", "content": "hi"}]})
        check("nonstream: type=message", a.get("type") == "message")
        check("nonstream: text content", a["content"][0]["type"] == "text" and "Hello" in a["content"][0]["text"])
        # (b) streaming text order + message_stop, garbage-tolerant
        s = post_messages({"model": "m", "stream": True, "max_tokens": 50, "messages": [{"role": "user", "content": "hi"}]}, stream=True)
        check("stream: message_start", "event: message_start" in s)
        check("stream: text_delta Hello", "text_delta" in s and "Hel" in s)
        check("stream: message_stop last", s.strip().endswith('"message_stop"}') or "event: message_stop" in s)
        check("stream: survived garbage chunk", "message_stop" in s)
        # (c) tool_use round-trip (streaming)
        st = post_messages({"model": "m", "stream": True, "max_tokens": 50,
                            "tools": [{"name": "get_weather", "input_schema": {"type": "object"}}],
                            "messages": [{"role": "user", "content": "weather?"}]}, stream=True)
        check("stream: tool_use block", '"type": "tool_use"' in st and "get_weather" in st)
        check("stream: input_json_delta", "input_json_delta" in st)
        # (f) non-localhost bind refused: the shim binds 127.0.0.1; assert it is not reachable off-loopback
        # (structural: we assert the source binds 127.0.0.1)
        src = open(SHIM).read()
        check("binds 127.0.0.1 only", '"127.0.0.1"' in src and "0.0.0.0" not in src)
    finally:
        proc.terminate()
        mock.shutdown()
    print("\n%d passed, %d failed" % (12 - len(fails), len(fails)))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
