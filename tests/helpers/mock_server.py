#!/usr/bin/env python3
"""Local loopback mock inference server for assistit.nvim headless integration tests."""

import json
import socket
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class MockInferenceHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        # Silence default request logging to keep test output clean
        pass

    def _read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode("utf-8", errors="replace") if length > 0 else ""
        try:
            return json.loads(raw) if raw else {}, raw
        except Exception:
            return {}, raw

    def _send_json(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.endswith("/api/tags"):
            self._send_json(200, {"models": [{"name": "qwen2.5-coder:0.5b"}, {"name": "qwen2.5-coder:1.5b"}]})
        elif self.path.endswith("/health"):
            self._send_json(200, {"status": "ok"})
        elif self.path.endswith("/v1/models"):
            self._send_json(200, {"data": [{"id": "qwen2.5-coder-1.5b-instruct"}]})
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self):
        data, _ = self._read_json()
        scenario = self.headers.get("X-Mock-Scenario", "")

        if scenario == "slow":
            time.sleep(0.45)
        elif scenario == "disconnect":
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass
            self.connection.close()
            return
        elif scenario == "http500":
            self._send_json(500, {"error": "simulated internal server error"})
            return
        elif scenario == "malformed":
            raw = b"{not_valid_json_at_all"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return

        # Test endpoint fallback paths
        if self.path == "/no-infill/infill":
            self._send_json(404, {"error": "infill not supported"})
            return
        if self.path == "/chat-only/v1/completions":
            self._send_json(404, {"error": "completions not supported"})
            return

        is_stream = bool(data.get("stream", False))
        if scenario == "empty":
            completion_text = ""
        elif scenario == "large":
            completion_text = "\n".join(f"  local line_{i} = {i}" for i in range(1, 65))
        elif scenario == "overlap_paren":
            completion_text = "items)"
        elif scenario == "multiline":
            completion_text = "user in ipairs(users) do\n  if user.active then\n    notify(user)\n  end\nend"
        else:
            completion_text = "result = a + b\nreturn result"

        # 1. Ollama `/api/generate`
        if self.path.endswith("/api/generate"):
            if is_stream:
                chunks = [completion_text[:10], completion_text[10:]] if completion_text else [""]
                body_lines = [json.dumps({"response": c, "done": False}) + "\n" for c in chunks]
                body_lines.append(json.dumps({"response": "", "done": True}) + "\n")
                payload = "".join(body_lines).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/x-ndjson")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                for line in body_lines:
                    self.wfile.write(line.encode("utf-8"))
                    self.wfile.flush()
                    time.sleep(0.01)
                return
            self._send_json(200, {"response": completion_text, "done": True})
            return

        # 2. Ollama `/api/chat`
        if self.path.endswith("/api/chat"):
            reply = "Fixed undefined variable.\n```lua\nlocal result = input or {}\nreturn result\n```"
            self._send_json(200, {"message": {"role": "assistant", "content": reply}, "done": True})
            return

        # 3. llama.cpp `/infill` or `/completion`
        if self.path.endswith("/infill") or self.path.endswith("/completion"):
            if is_stream:
                chunks = [completion_text[:8], completion_text[8:]] if completion_text else [""]
                sse = "".join(f"data: {json.dumps({'content': c})}\n\n" for c in chunks) + "data: [DONE]\n\n"
                raw_sse = sse.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(raw_sse)))
                self.end_headers()
                self.wfile.write(raw_sse)
                return
            self._send_json(200, {"content": completion_text})
            return

        # 4. OpenAI-compatible `/v1/completions`
        if self.path.endswith("/v1/completions"):
            if is_stream:
                chunks = [completion_text[:8], completion_text[8:]] if completion_text else [""]
                sse = "".join(f"data: {json.dumps({'choices': [{'text': c}]})}\n\n" for c in chunks) + "data: [DONE]\n\n"
                raw_sse = sse.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(raw_sse)))
                self.end_headers()
                self.wfile.write(raw_sse)
                return
            self._send_json(200, {"choices": [{"text": completion_text}]})
            return

        # 5. OpenAI-compatible `/v1/chat/completions`
        if self.path.endswith("/v1/chat/completions"):
            msgs = data.get("messages", [])
            sys_msg = msgs[0].get("content", "") if msgs else ""
            if "inline code completion" in sys_msg.lower():
                reply = completion_text
            else:
                reply = "Proposed improvement.\n```lua\nlocal result = input or {}\nreturn result\n```"
            self._send_json(200, {"choices": [{"message": {"role": "assistant", "content": reply}}]})
            return

        self._send_json(404, {"error": "unknown route " + self.path})


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    server = ThreadingHTTPServer(("127.0.0.1", port), MockInferenceHandler)
    actual_port = server.server_address[1]
    sys.stdout.write(f"READY {actual_port}\n")
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
