"""Local-only Responses/SSE fixture; never contacts an upstream provider."""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

request_log = Path(sys.argv[1])


class Gateway(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send_body(self, status, body, content_type="application/json"):
        encoded = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        if "/unauth/" in self.path:
            self.send_body(401, '{"error":"reflected-secret-that-must-not-be-printed"}')
        else:
            self.send_body(200, json.dumps({"data": [{"id": "company-coding"}]}))

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with request_log.open("a", encoding="utf-8") as log:
            log.write(json.dumps({"path": self.path, "auth_ok": self.headers.get("Authorization") == "Bearer dummy-local-test-key", "body": body}) + "\n")
        if "/chat-only/" in self.path:
            self.send_body(404, '{"error":"no responses endpoint"}')
            return
        if "/json-only/" in self.path:
            self.send_body(200, '{"status":"completed","output":[]}')
            return
        if "/truncated/" in self.path:
            self.send_body(200, 'data: {"type":"response.created"}\n\n', "text/event-stream")
            return
        if "/cli/" in self.path:
            output = [{"id": "msg_test", "type": "message", "role": "assistant", "status": "completed", "content": [{"type": "output_text", "text": "OK", "annotations": []}]}]
        elif isinstance(body["input"], str):
            output = [{"type": "function_call", "id": "fc_test", "name": "codex_setup_probe", "call_id": "call_test", "arguments": '{"value":"OK"}', "status": "completed"}]
        else:
            outputs = [x for x in body["input"] if x.get("type") == "function_call_output"]
            if len(outputs) != 1 or outputs[0]["call_id"] != "call_test" or outputs[0]["output"] != "OK":
                self.send_body(400, '{"error":"bad tool continuation"}')
                return
            output = [{"id": "msg_test", "type": "message", "role": "assistant", "status": "completed", "content": [{"type": "output_text", "text": "OK", "annotations": []}]}]
        response = {"id": "resp_test", "object": "response", "status": "completed", "output": output}
        events = [
            {"type": "response.created", "response": {"id": "resp_test", "status": "in_progress"}},
        ]
        if "/cli/" in self.path:
            message = output[0]
            part = message["content"][0]
            events.extend([
                {"type": "response.output_item.added", "output_index": 0, "item": {**message, "status": "in_progress", "content": []}},
                {"type": "response.content_part.added", "item_id": "msg_test", "output_index": 0, "content_index": 0, "part": {**part, "text": ""}},
                {"type": "response.output_text.delta", "item_id": "msg_test", "output_index": 0, "content_index": 0, "delta": "OK"},
                {"type": "response.output_text.done", "item_id": "msg_test", "output_index": 0, "content_index": 0, "text": "OK"},
                {"type": "response.content_part.done", "item_id": "msg_test", "output_index": 0, "content_index": 0, "part": part},
                {"type": "response.output_item.done", "output_index": 0, "item": message},
            ])
        events.append({"type": "response.completed", "response": response})
        self.send_body(200, "".join("data: " + json.dumps(e) + "\n\n" for e in events), "text/event-stream")


server = HTTPServer(("127.0.0.1", 0), Gateway)
print(server.server_address[1], flush=True)
server.serve_forever()
