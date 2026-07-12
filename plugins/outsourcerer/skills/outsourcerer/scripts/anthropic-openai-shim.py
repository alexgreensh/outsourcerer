#!/usr/bin/env python3
"""Minimal, stdlib-only Anthropic<->OpenAI translation shim (Outsourcerer local lane, plan U2).

Lets Claude Code (`claude -p`, which speaks the Anthropic Messages API) drive a LOCAL OpenAI-compatible
Chat Completions server (Ollama / LM Studio / llama.cpp) AGENTICALLY, so a local model can run inside
the harness with full tool use. Localhost only, keyless, on-demand, no third-party deps.

Env:
  OSRC_SHIM_UPSTREAM  local OpenAI base, e.g. http://localhost:11434/v1   (required)
  OSRC_SHIM_PORT      listen port on 127.0.0.1 (default 8788)
  OSRC_SHIM_KEY       bearer sent upstream (default "local"; local servers ignore it)

Routes:
  GET  /health        -> {"ok": true}
  POST /v1/messages   -> translates to {UPSTREAM}/chat/completions and back (stream + non-stream)

NOT hardened for the public internet: binds 127.0.0.1 only and refuses other binds.
"""
import json
import os
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("OSRC_SHIM_UPSTREAM", "").rstrip("/")
PORT = int(os.environ.get("OSRC_SHIM_PORT", "8788"))
KEY = os.environ.get("OSRC_SHIM_KEY", "local")
# Sol's #1 gap: the shim is a protocol adapter to a DIFFERENT model namespace. Claude Code sends its
# own model id (a "claude-*" default or ANTHROPIC_MODEL, brittle across versions/subagents/fast-model
# routes); a local server won't recognize it. Force the resolved local model when OSRC_SHIM_MODEL is set.
MODEL = os.environ.get("OSRC_SHIM_MODEL", "")


# ---------- request translation: Anthropic Messages -> OpenAI Chat Completions ----------
def _content_to_text(content):
    """Anthropic content (str or list of blocks) -> plain text (best-effort)."""
    if isinstance(content, str):
        return content
    parts = []
    for b in content or []:
        if isinstance(b, dict) and b.get("type") == "text":
            parts.append(b.get("text", ""))
    return "".join(parts)


def anthropic_to_openai(a):
    msgs = []
    if a.get("system"):
        msgs.append({"role": "system", "content": _content_to_text(a["system"])})
    for m in a.get("messages", []):
        role = m.get("role", "user")
        content = m.get("content")
        if isinstance(content, str):
            msgs.append({"role": role, "content": content})
            continue
        # list of blocks: split into text, tool_use (assistant->tool_calls), tool_result (->role tool)
        text_parts, tool_calls, tool_results = [], [], []
        for b in content or []:
            t = b.get("type")
            if t == "text":
                text_parts.append(b.get("text", ""))
            elif t == "tool_use":
                tool_calls.append({
                    "id": b.get("id", ""),
                    "type": "function",
                    "function": {"name": b.get("name", ""),
                                 "arguments": json.dumps(b.get("input", {}))},
                })
            elif t == "tool_result":
                tool_results.append({
                    "role": "tool",
                    "tool_call_id": b.get("tool_use_id", ""),
                    "content": _content_to_text(b.get("content", "")),
                })
        if tool_calls:
            msgs.append({"role": "assistant", "content": "".join(text_parts) or None,
                         "tool_calls": tool_calls})
        # OpenAI requires a role:"tool" message to IMMEDIATELY follow the assistant tool_calls it answers.
        # So emit tool_results BEFORE any companion user text (a Claude tool-result turn often carries both),
        # else the local server 400s and every agentic-local turn with text+tool_result dies.
        for tr in tool_results:
            msgs.append(tr)
        if text_parts and not tool_calls:
            msgs.append({"role": role, "content": "".join(text_parts)})

    o = {"model": MODEL or a.get("model", "local"), "messages": msgs,
         "stream": bool(a.get("stream")), "max_tokens": a.get("max_tokens", 4096)}
    if a.get("temperature") is not None:
        o["temperature"] = a["temperature"]
    if a.get("tools"):
        o["tools"] = [{"type": "function",
                       "function": {"name": t.get("name"),
                                    "description": t.get("description", ""),
                                    "parameters": t.get("input_schema", {})}}
                      for t in a["tools"]]
    tc = a.get("tool_choice")
    if isinstance(tc, dict):
        if tc.get("type") == "auto":
            o["tool_choice"] = "auto"
        elif tc.get("type") == "tool" and tc.get("name"):
            o["tool_choice"] = {"type": "function", "function": {"name": tc["name"]}}
    return o


def _finish_to_stop(reason):
    return {"stop": "end_turn", "length": "max_tokens",
            "tool_calls": "tool_use", "function_call": "tool_use"}.get(reason, "end_turn")


# ---------- response translation ----------
def openai_to_anthropic_nonstream(o, model):
    choice = (o.get("choices") or [{}])[0]
    msg = choice.get("message", {}) or {}
    blocks = []
    if msg.get("content"):
        blocks.append({"type": "text", "text": msg["content"]})
    for tc in msg.get("tool_calls") or []:
        fn = tc.get("function", {}) or {}
        try:
            args = json.loads(fn.get("arguments") or "{}")
        except Exception:
            args = {}
        blocks.append({"type": "tool_use", "id": tc.get("id", ""),
                       "name": fn.get("name", ""), "input": args})
    if not blocks:
        blocks = [{"type": "text", "text": ""}]
    usage = o.get("usage", {}) or {}
    return {
        "id": o.get("id", "msg_shim"), "type": "message", "role": "assistant",
        "model": model, "content": blocks,
        "stop_reason": _finish_to_stop(choice.get("finish_reason")),
        "stop_sequence": None,
        "usage": {"input_tokens": usage.get("prompt_tokens", 0),
                  "output_tokens": usage.get("completion_tokens", 0)},
    }


def _sse(event, data):
    return ("event: %s\ndata: %s\n\n" % (event, json.dumps(data))).encode()


def stream_openai_to_anthropic(resp, model, write):
    """Pump an upstream OpenAI SSE response, emitting the Anthropic event sequence via write(bytes)."""
    write(_sse("message_start", {"type": "message_start", "message": {
        "id": "msg_shim", "type": "message", "role": "assistant", "model": model,
        "content": [], "stop_reason": None, "usage": {"input_tokens": 0, "output_tokens": 0}}}))
    text_idx = None        # anthropic block index of the open text block, or None
    tool_map = {}          # openai tool_call `index` -> anthropic block index (parallel-safe)
    next_block = 0
    stop_reason = "end_turn"
    usage_out = 0
    for raw in resp:
        line = raw.decode("utf-8", "replace").strip()
        if not line or not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if payload == "[DONE]":
            break
        try:
            chunk = json.loads(payload)
        except Exception:
            continue  # malformed chunk must not crash the stream
        choice = (chunk.get("choices") or [{}])[0]
        delta = choice.get("delta", {}) or {}
        if choice.get("finish_reason"):
            stop_reason = _finish_to_stop(choice["finish_reason"])
        # text delta -> one text block (opened on first token)
        if delta.get("content"):
            if text_idx is None:
                text_idx = next_block
                next_block += 1
                write(_sse("content_block_start", {"type": "content_block_start", "index": text_idx,
                      "content_block": {"type": "text", "text": ""}}))
            write(_sse("content_block_delta", {"type": "content_block_delta", "index": text_idx,
                  "delta": {"type": "text_delta", "text": delta["content"]}}))
            usage_out += 1
        # tool-call deltas: OpenAI fragments each call across chunks, keyed by tool_call `index`.
        # Accumulate by that index into a distinct anthropic tool_use block (parallel-safe:
        # never route arg fragments to the wrong call). The first fragment of an index carries id+name.
        for tcd in delta.get("tool_calls") or []:
            oai_i = tcd.get("index", 0)
            fn = tcd.get("function", {}) or {}
            if oai_i not in tool_map:
                if text_idx is not None:   # text precedes tools; close it before opening tool blocks
                    write(_sse("content_block_stop", {"type": "content_block_stop", "index": text_idx}))
                    text_idx = None
                b = next_block
                next_block += 1
                tool_map[oai_i] = b
                write(_sse("content_block_start", {"type": "content_block_start", "index": b,
                      "content_block": {"type": "tool_use", "id": tcd.get("id", ""),
                                        "name": fn.get("name", ""), "input": {}}}))
            if fn.get("arguments"):
                write(_sse("content_block_delta", {"type": "content_block_delta", "index": tool_map[oai_i],
                      "delta": {"type": "input_json_delta", "partial_json": fn["arguments"]}}))
    if text_idx is not None:
        write(_sse("content_block_stop", {"type": "content_block_stop", "index": text_idx}))
    for b in sorted(tool_map.values()):
        write(_sse("content_block_stop", {"type": "content_block_stop", "index": b}))
    if text_idx is None and not tool_map:   # content-less stream -> emit an empty text block
        write(_sse("content_block_start", {"type": "content_block_start", "index": 0,
              "content_block": {"type": "text", "text": ""}}))
        write(_sse("content_block_stop", {"type": "content_block_stop", "index": 0}))
    write(_sse("message_delta", {"type": "message_delta",
          "delta": {"stop_reason": stop_reason, "stop_sequence": None},
          "usage": {"output_tokens": usage_out}}))
    write(_sse("message_stop", {"type": "message_stop"}))


# ---------- HTTP ----------
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _route(self):
        # claude -p calls /v1/messages?beta=true — drop the query string (and trailing slash) before matching.
        return self.path.split("?", 1)[0].rstrip("/")

    def do_GET(self):
        if self._route() == "/health":
            return self._json(200, {"ok": True, "upstream": UPSTREAM})
        sys.stderr.write("[shim] unmatched GET %s\n" % self.path)   # so we SEE what claude -p probes
        return self._json(404, {"error": "not found"})

    def do_POST(self):
        path = self._route()
        n = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(n) or b"{}"   # always drain the body so the socket stays sane
        # Optional endpoint claude -p may probe: return a conservative token estimate.
        if path == "/v1/messages/count_tokens":
            try:
                approx = len(raw.decode("utf-8", "replace")) // 4
            except Exception:
                approx = 0
            return self._json(200, {"input_tokens": max(1, approx)})
        if path != "/v1/messages":
            sys.stderr.write("[shim] unmatched POST %s\n" % self.path)
            return self._json(404, {"error": "not found"})
        try:
            areq = json.loads(raw)
        except Exception:
            return self._json(400, {"type": "error", "error": {"message": "bad json"}})
        model = MODEL or areq.get("model", "local")
        oreq = anthropic_to_openai(areq)
        data = json.dumps(oreq).encode()
        req = urllib.request.Request(UPSTREAM + "/chat/completions", data=data, method="POST",
                                     headers={"Content-Type": "application/json",
                                              "Authorization": "Bearer " + KEY})
        try:
            up = urllib.request.urlopen(req, timeout=int(os.environ.get("OSRC_SHIM_TIMEOUT", "900")))
        except Exception as e:
            return self._json(502, {"type": "error", "error": {"message": "upstream: %s" % e}})
        if oreq["stream"]:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            try:
                stream_openai_to_anthropic(up, model, self._safe_write)
            except Exception as e:
                try:
                    self._safe_write(_sse("error", {"type": "error", "error": {"message": str(e)}}))
                except Exception:
                    pass
        else:
            try:
                obj = json.loads(up.read().decode("utf-8", "replace"))
            except Exception as e:
                return self._json(502, {"type": "error", "error": {"message": "decode: %s" % e}})
            self._json(200, openai_to_anthropic_nonstream(obj, model))

    def _safe_write(self, b):
        self.wfile.write(b)
        self.wfile.flush()


def main():
    if not UPSTREAM:
        sys.stderr.write("OSRC_SHIM_UPSTREAM is required (e.g. http://localhost:11434/v1)\n")
        sys.exit(2)
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)  # localhost only
    sys.stderr.write("[shim] 127.0.0.1:%d -> %s\n" % (PORT, UPSTREAM))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
