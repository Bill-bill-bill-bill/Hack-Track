"""hacktrack-bridge: local companion service for the Hack Track page on Kali.

The page is a static browser app, so anything that needs the machine (exam AI lockdown,
terminals, RDP, ...) goes through this service. Python stdlib only.

Routes live in ROUTES as (method, path) -> (handler, remote_ok). Rules:
- Listens on 127.0.0.1:8790. If HT_BRIDGE_HOST_IP is set (the VM's host-only address),
  it also listens there, but only for routes marked remote_ok, and those need the
  X-HT-Token header (the Windows host watcher).
- Loopback POSTs must send the X-HT-Bridge: 1 header. That forces a CORS preflight, and the
  preflight only allows local page origins, so a random website can't toggle Exam mode.

Feature modules add routes: exam.py ships /api/exam/*. Other features register theirs the same way.
"""
from __future__ import annotations

import argparse
import hmac
import json
import os
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import exam as exam_mod
from exam import Exam

ORIGIN_OK = re.compile(
    r"^(https?://(localhost|127\.0\.0\.1|\[::1\]|tauri\.localhost)(:\d+)?|tauri://localhost)$")
MAX_BODY = 64 * 1024

exam: Exam | None = None


def _exam_state(_h, _body):
    return 200, exam.public()


def _exam_schedule(_h, body):
    return 200, exam.set_schedule(body.get("start"), body.get("lead_min"))


def _exam_on(_h, _body):
    return 200, exam.turn_on("manual")


def _exam_off(_h, _body):
    return 200, exam.turn_off()


def _exam_host_state(_h, _body):
    return 200, exam.host_view()


def _exam_host_report(_h, body):
    return 200, exam.host_report(body)


HOST_KIT = ("ai-off.ps1", "ai-on.ps1", "host-watch.ps1")


def _exam_host_kit(h, _body):
    """Serve the Windows scripts to the host installer, so its paste stays short."""
    from urllib.parse import parse_qs, urlparse
    name = (parse_qs(urlparse(h.path).query).get("name") or [""])[0]
    if name not in HOST_KIT:
        return 404, {"error": "unknown file"}
    return 200, {"name": name, "text": (exam_mod.SCRIPTS / name).read_text()}


ROUTES = {
    ("GET", "/api/health"): (lambda h, b: (200, {"ok": True, "features": ["exam"]}), False),
    ("GET", "/api/exam/state"): (_exam_state, False),
    ("POST", "/api/exam/schedule"): (_exam_schedule, False),
    ("POST", "/api/exam/on"): (_exam_on, False),
    ("POST", "/api/exam/off"): (_exam_off, False),
    ("GET", "/api/exam/host"): (_exam_host_state, True),
    ("POST", "/api/exam/host-report"): (_exam_host_report, True),
    ("GET", "/api/exam/host-kit"): (_exam_host_kit, True),
}


class Handler(BaseHTTPRequestHandler):
    server_version = "hacktrack-bridge/1"
    remote = False  # set on the class used by the host-only listener

    def log_message(self, fmt, *args):  # quiet; systemd journal gets errors only
        pass

    def _cors(self):
        o = self.headers.get("Origin")
        if o and ORIGIN_OK.match(o):
            self.send_header("Access-Control-Allow-Origin", o)
            self.send_header("Vary", "Origin")
            self.send_header("Access-Control-Allow-Headers", "Content-Type, X-HT-Bridge")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

    def _send(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        if not self.remote:
            self._cors()
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):
        if self.remote:
            return self._send(403, {"error": "forbidden"})
        self.send_response(204)
        self._cors()
        self.end_headers()

    def _dispatch(self, method):
        path = self.path.split("?", 1)[0]
        route = ROUTES.get((method, path))
        if not route:
            return self._send(404, {"error": "not found"})
        fn, remote_ok = route
        if self.remote:
            tok = self.headers.get("X-HT-Token", "")
            if not remote_ok or not hmac.compare_digest(tok, exam.token):
                return self._send(403, {"error": "forbidden"})
        elif method == "POST" and self.headers.get("X-HT-Bridge") != "1":
            return self._send(403, {"error": "missing X-HT-Bridge header"})
        body = {}
        if method == "POST":
            n = int(self.headers.get("Content-Length") or 0)
            if n > MAX_BODY:
                return self._send(413, {"error": "too large"})
            try:
                body = json.loads(self.rfile.read(n) or b"{}")
                if not isinstance(body, dict):
                    raise ValueError
            except ValueError:
                return self._send(400, {"error": "bad json"})
        try:
            code, obj = fn(self, body)
        except ValueError as e:
            code, obj = 400, {"error": str(e)}
        self._send(code, obj)

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")


class RemoteHandler(Handler):
    remote = True


def serve(port: int, host_ip: str | None, state_dir=None) -> tuple[list, threading.Event]:
    global exam
    exam = Exam(state_dir)
    stop = threading.Event()
    threading.Thread(target=exam.loop, args=(stop,), daemon=True).start()
    servers = [ThreadingHTTPServer(("127.0.0.1", port), Handler)]
    if host_ip:
        servers.append(ThreadingHTTPServer((host_ip, port), RemoteHandler))
    for s in servers:
        threading.Thread(target=s.serve_forever, daemon=True).start()
    return servers, stop


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--port", type=int, default=int(os.environ.get("HT_BRIDGE_PORT", 8790)))
    ap.add_argument("--host-ip", default=os.environ.get("HT_BRIDGE_HOST_IP") or None,
                    help="also listen on this host-only address for the Windows watcher")
    ap.add_argument("--print-token", action="store_true", help="print the host watcher token and exit")
    a = ap.parse_args()
    if a.print_token:
        print(Exam().token)
        return
    servers, _ = serve(a.port, a.host_ip)
    print(f"hacktrack-bridge on 127.0.0.1:{a.port}" + (f" and {a.host_ip}:{a.port} (host watcher)" if a.host_ip else ""),
          flush=True)
    threading.Event().wait()


if __name__ == "__main__":
    main()
