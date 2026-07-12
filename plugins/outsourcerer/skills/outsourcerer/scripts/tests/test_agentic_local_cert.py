#!/usr/bin/env python3
"""Agentic-local CONFORMANCE test (Sol-designed, plan R6-mock).

Proves the vehicle-B loop end to end WITHOUT a local model: a mock OpenAI /chat/completions server
plays the local model deterministically, the real vendored shim translates, and the real `claude -p`
harness drives it. Certifies the plumbing (tool-call round-trip, multi-turn loop) that a real Ollama/
LM Studio only has to reproduce with its own model.

Flow:
  claude -p  --(Anthropic Messages)-->  shim  --(OpenAI Chat)-->  mock
  turn 1: mock returns a streamed tool_call (Read <fixture>), args fragmented across 2 chunks.
  claude EXECUTES the real Read tool -> reads a nonce fixture -> sends a tool_result back.
  turn 2: mock asserts the tool_call_id round-tripped + the nonce is in history, returns final text w/ nonce.
  assert: claude exits 0, prints the nonce, mock saw >=2 completion calls with a tool-result round-trip.

Skips (exit 0, SKIP) if the `claude` CLI is absent. Fails loudly on a real conformance break.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SHIM = os.path.join(os.path.dirname(HERE), "anthropic-openai-shim.py")
NONCE = "NONCE-c0ffee-42-agentic-ok"

# ---- mock OpenAI server: records requests, drives the two-turn tool loop ----
_calls = []           # list of parsed request bodies to /chat/completions
_lock = threading.Lock()


def _sse(obj):
    return ("data: %s\n\n" % json.dumps(obj)).encode()


class MockOpenAI(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        if self.path.rstrip("/") not in ("/v1/chat/completions", "/chat/completions"):
            self.send_response(404); self.end_headers(); return
        n = int(self.headers.get("Content-Length", 0) or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        with _lock:
            _calls.append(body)
        msgs = body.get("messages", [])
        has_tool_result = any(m.get("role") == "tool" for m in msgs)
        tools = body.get("tools") or []
        tool_names = [t.get("function", {}).get("name") for t in tools]

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        if not has_tool_result and "Read" in tool_names:
            # TURN 1: emit a Read tool call for the fixture, arguments fragmented across two chunks.
            fixture = os.environ["CERT_FIXTURE"]
            self.wfile.write(_sse({"choices": [{"index": 0, "delta": {"role": "assistant",
                "tool_calls": [{"index": 0, "id": "call_cert_1", "type": "function",
                                "function": {"name": "Read", "arguments": '{"file_path":"'}}]}}]}))
            self.wfile.write(_sse({"choices": [{"index": 0, "delta": {
                "tool_calls": [{"index": 0, "function": {"arguments": fixture + '"}'}}]}}]}))
            self.wfile.write(_sse({"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}))
        else:
            # TURN 2 (or any follow-up): final answer containing the nonce, split across chunks.
            self.wfile.write(_sse({"choices": [{"index": 0, "delta": {"role": "assistant",
                                                                      "content": "The nonce is "}}]}))
            self.wfile.write(_sse({"choices": [{"index": 0, "delta": {"content": NONCE}}]}))
            self.wfile.write(_sse({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}))
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def _free_port():
    import socket
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def main():
    if not subprocess.run(["bash", "-lc", "command -v claude"], capture_output=True).stdout.strip():
        print("SKIP: claude CLI not on PATH (cannot certify the live loop here)"); return 0
    if not os.path.isfile(SHIM):
        print("FAIL: shim not found at %s" % SHIM); return 1

    mock_port, shim_port = _free_port(), _free_port()
    fixture = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, prefix="cert_")
    fixture.write("The secret nonce is %s. Report it exactly.\n" % NONCE); fixture.close()
    os.environ["CERT_FIXTURE"] = fixture.name

    mock = ThreadingHTTPServer(("127.0.0.1", mock_port), MockOpenAI)
    threading.Thread(target=mock.serve_forever, daemon=True).start()

    shim_env = dict(os.environ,
                    OSRC_SHIM_UPSTREAM="http://127.0.0.1:%d/v1" % mock_port,
                    OSRC_SHIM_PORT=str(shim_port),
                    OSRC_SHIM_MODEL="cert-local-model",
                    OSRC_SHIM_KEY="local")
    shim = subprocess.Popen([sys.executable, SHIM], env=shim_env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    ok = False
    for _ in range(40):
        try:
            urllib.request.urlopen("http://127.0.0.1:%d/health" % shim_port, timeout=1); ok = True; break
        except Exception:
            time.sleep(0.25)
    if not ok:
        print("FAIL: shim never became healthy"); shim.kill(); return 1

    # strip nested Claude Code env (same fix the lane uses) so claude -p auths against the shim
    cenv = dict(os.environ)
    for k in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID",
              "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_EXECPATH", "ANTHROPIC_API_KEY"):
        cenv.pop(k, None)
    # Mirror the WORKING delegate_cc recipe: --bare (below) makes claude accept an arbitrary model id
    # (the advisor/catalog ranking that rejects unknown models is off in bare mode); the shim forces
    # OSRC_SHIM_MODEL upstream regardless.
    cenv.update(ANTHROPIC_BASE_URL="http://127.0.0.1:%d" % shim_port,
                ANTHROPIC_AUTH_TOKEN="local",
                ANTHROPIC_MODEL="cert-local-model",
                ANTHROPIC_SMALL_FAST_MODEL="cert-local-model")
    task = "Use the Read tool on the file at %s and report the exact nonce it contains." % fixture.name
    rc, out = 1, ""
    try:
        # prompt via STDIN: --allowedTools is variadic (<tools...>) and greedily eats a trailing
        # positional prompt, so the prompt must not follow it on argv.
        p = subprocess.run(["claude", "-p", "--bare", "--permission-mode", "default", "--allowedTools", "Read"],
                           input=task, env=cenv, capture_output=True, text=True, timeout=120)
        rc, out = p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        print("FAIL: claude -p hung against the shim (120s)"); shim.kill(); mock.shutdown(); return 1

    shim.terminate()
    try:
        shim_err = shim.stderr.read().decode("utf-8", "replace") if shim.stderr else ""
    except Exception:
        shim_err = ""
    mock.shutdown()
    os.unlink(fixture.name)

    # ---- assertions ----
    fails = []
    with _lock:
        n_calls = len(_calls)
        saw_tool_result = any(any(m.get("role") == "tool" for m in c.get("messages", [])) for c in _calls)
        forced_model = all(c.get("model") == "cert-local-model" for c in _calls) if _calls else False
        roundtrip_id = any(
            any(m.get("role") == "tool" and NONCE in json.dumps(m.get("content", "")) for m in c.get("messages", []))
            for c in _calls)
    if rc != 0:
        fails.append("claude -p exit=%d (expected 0)" % rc)
    if NONCE not in out:
        fails.append("nonce not in claude output (loop did not complete)")
    if n_calls < 2:
        fails.append("mock saw %d completion calls (expected >=2: tool turn + final)" % n_calls)
    if not saw_tool_result:
        fails.append("no tool_result reached the mock (Claude never executed the tool)")
    if not roundtrip_id:
        fails.append("nonce did not round-trip through the tool_result into turn 2")
    if not forced_model:
        fails.append("shim did not force OSRC_SHIM_MODEL (saw %s)" %
                     {c.get("model") for c in _calls})

    if fails:
        print("FAIL agentic-local conformance:")
        for f in fails:
            print("  - " + f)
        print("--- claude output (tail) ---")
        print("\n".join(out.splitlines()[-15:]))
        print("--- shim stderr (routes claude probed) ---")
        print(shim_err[-1500:])
        return 1
    print("PASS agentic-local conformance: %d completion calls, tool executed, "
          "nonce round-tripped, model forced, claude exit 0." % n_calls)
    return 0


if __name__ == "__main__":
    sys.exit(main())
