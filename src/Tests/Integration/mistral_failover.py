"""Run with python3 src/Tests/Integration/mistral_failover.py (no real credentials).

Loads the bundled CLIProxyAPI with one shared `openai-compatibility:` block holding
both a Meta and a Mistral entry (the shape OpenAICompatibilityConfig writes), against
local mock upstreams. The first Mistral key always fails; a successful response must
come from the second key, and each model must reach its own upstream.
"""
import http.server
import json
import pathlib
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parents[3]


def make_upstream(seen, model, fail_first, failure_status):
    class Upstream(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            account = self.headers.get("Authorization")
            seen.append(account)
            failed = fail_first and account == seen[0]
            payload = {"error": {"message": "mock failure", "type": "upstream_error"}} if failed else {
                "id": "test", "object": "chat.completion", "model": model,
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"},
                             "finish_reason": "stop"}],
            }
            body = json.dumps(payload).encode()
            self.send_response(failure_status if failed else 200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def chat(port, model):
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/chat/completions",
        data=json.dumps({"model": model, "stream": False,
                         "messages": [{"role": "user", "content": "test"}]}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.load(response)


def check(strategy, failure_status):
    mistral_seen, meta_seen = [], []
    mistral = make_upstream(mistral_seen, "mistral-large-4", True, failure_status)
    meta = make_upstream(meta_seen, "muse-wonder-1.0", False, 500)
    try:
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        with tempfile.TemporaryDirectory(prefix="mistral-failover-") as tmp:
            config = pathlib.Path(tmp) / "config.yaml"
            base = (ROOT / "src/Sources/Resources/config.yaml").read_text()
            base = base.replace("port: 8318", f"port: {port}")
            base = base.replace('auth-dir: "~/.cli-proxy-api"', f'auth-dir: "{tmp}/auth"')
            base = base.replace('strategy: "round-robin"', f'strategy: "{strategy}"')
            if strategy == "fill-first":
                base = base.replace("disable-cooling: true", "disable-cooling: false")
                base = base.replace("transient-error-cooldown-seconds: 0",
                                    "transient-error-cooldown-seconds: -1")
                base = base.replace("max-retry-interval: 0", "max-retry-interval: 30")
            config.write_text(base + f"""
# Meta Muse subscription (auto-added by DroidProxy)
# Mistral (auto-added by DroidProxy)
openai-compatibility:
  - name: "meta"
    base-url: "http://127.0.0.1:{meta.server_port}/v1"
    api-key-entries:
      - api-key: "fake-meta"
    models:
      - name: "muse-wonder-1.0"
  - name: "mistral"
    base-url: "http://127.0.0.1:{mistral.server_port}/v1"
    api-key-entries:
      - api-key: "fake-mistral-one"
      - api-key: "fake-mistral-two"
    models:
      - name: "mistral-large-4"
      - name: "zai-glm-5-3"
""")
            with (pathlib.Path(tmp) / "backend.log").open("w") as log:
                process = subprocess.Popen(
                    [str(ROOT / "src/Sources/Resources/cli-proxy-api"), "--config", str(config)],
                    cwd=tmp, stdout=log, stderr=log,
                )
                try:
                    for _ in range(100):
                        if process.poll() is not None:
                            raise AssertionError("Backend exited before readiness (bad YAML?)")
                        try:
                            with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                                break
                        except OSError:
                            time.sleep(0.1)
                    body = chat(port, "mistral-large-4")
                    assert body["choices"][0]["message"]["content"] == "ok", body
                    assert len(set(mistral_seen)) == 2, "Request did not fail over to the second Mistral key"
                    assert not meta_seen, "A Mistral model reached the Meta upstream"
                    body = chat(port, "muse-wonder-1.0")
                    assert body["choices"][0]["message"]["content"] == "ok", body
                    assert meta_seen == ["Bearer fake-meta"], meta_seen
                    print(f"PASS: {strategy}, HTTP {failure_status} -> second Mistral key -> 200; Meta unaffected")
                finally:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
    finally:
        for server in (mistral, meta):
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    for strategy in ("round-robin", "fill-first"):
        for status in (401, 429, 500):
            check(strategy, status)
