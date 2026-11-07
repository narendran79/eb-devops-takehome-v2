"""Tiny HTTP service: GET / -> app info, GET /healthz -> 200. Stdlib only."""
import json
import os
import signal
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


CONFIG_DIR = os.environ.get("CONFIG_DIR", "/etc/app-config")


def setting(name: str, default: str) -> str:
    try:
        with open(os.path.join(CONFIG_DIR, name)) as f:
            value = f.read().strip()
            if value:
                return value
    except OSError:
        pass
    return os.environ.get(name, default)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            self._send(200, {"status": "ok"})
        elif path == "/":
            self._send(200, {
                "app": setting("APP_NAME", "unset"),
                "version": setting("VERSION", "unset"),
                "pod": socket.gethostname(),
            })
        else:
            self._send(404, {"error": "not found"})


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)

    def stop(*_):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    server.serve_forever()


if __name__ == "__main__":
    main()
