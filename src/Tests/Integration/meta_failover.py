"""Run with python3 src/Tests/Integration/meta_failover.py (no real credentials).

Exercises the bundled CLIProxyAPI against a local mock compatible provider.
The first account always fails; a successful response must use another account.
"""
import http.server
import json
import pathlib
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parents[3]


def check(strategy, failure_status):
    seen = []

    class Upstream(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            account = self.headers.get("Authorization")
            seen.append(account)
            failed = account == seen[0]
            payload = {"error": {"message": "mock failure", "type": "upstream_error"}} if failed else {
                "id": "test", "object": "chat.completion", "model": "muse-spark-1.3",
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"},
                             "finish_reason": "stop"}],
            }
            body = json.dumps(payload).encode()
            self.send_response(failure_status if failed else 200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
    threading.Thread(target=upstream.serve_forever, daemon=True).start()
    try:
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        with tempfile.TemporaryDirectory(prefix="meta-failover-") as tmp:
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
openai-compatibility:
  - name: "meta"
    base-url: "http://127.0.0.1:{upstream.server_port}/v1"
    api-key-entries:
      - api-key: "fake-account-one"
      - api-key: "fake-account-two"
    models:
      - name: "muse-spark-1.3"
      - name: "muse-spark-1.3-contributor"
""")
            with (pathlib.Path(tmp) / "backend.log").open("w") as log:
                process = subprocess.Popen(
                    [str(ROOT / "src/Sources/Resources/cli-proxy-api"), "--config", str(config)],
                    cwd=tmp, stdout=log, stderr=log,
                )
                try:
                    for _ in range(100):
                        if process.poll() is not None:
                            raise AssertionError("Backend exited before readiness")
                        try:
                            with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                                break
                        except OSError:
                            time.sleep(0.1)
                    request = urllib.request.Request(
                        f"http://127.0.0.1:{port}/v1/chat/completions",
                        data=json.dumps({"model": "muse-spark-1.3", "stream": False,
                                         "messages": [{"role": "user", "content": "test"}]}).encode(),
                        headers={"Content-Type": "application/json"},
                    )
                    with urllib.request.urlopen(request, timeout=15) as response:
                        body = json.load(response)
                    assert body["choices"][0]["message"]["content"] == "ok", body
                    assert len(set(seen)) == 2, "Request did not fail over to another account"
                    print(f"PASS: {strategy}, HTTP {failure_status} -> second account -> 200")
                finally:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
    finally:
        upstream.shutdown()
        upstream.server_close()


if __name__ == "__main__":
    for strategy in ("round-robin", "fill-first"):
        for status in (401, 429, 500):
            check(strategy, status)
