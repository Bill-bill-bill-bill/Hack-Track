"""Tests for hacktrack-bridge exam mode: schedule latch, sweeps, restore, HTTP auth rules.

Run: python3 -m unittest -v tools/hacktrack-bridge/test_bridge.py
"""
import json
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import exam as exam_mod  # noqa: E402

exam_mod.ROOT_DIR = Path(tempfile.mkdtemp()) / "absent"   # never touch the real /var/lib path
import server  # noqa: E402


class FakeClock:
    def __init__(self, t=1_800_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


class Runs:
    def __init__(self):
        self.calls = []

    def __call__(self, name):
        self.calls.append(name)
        return 0, "killed(TERM) 1 codex\nCHECK: AI processes left: 0\n" if name == "ai-off.sh" else "CHECK: restore done\n"


def make(tmp, clock=None, runs=None):
    return exam_mod.Exam(Path(tmp), runner=runs or Runs(), clock=clock or FakeClock())


class ExamLogic(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.clock, self.runs = FakeClock(), Runs()
        self.e = make(self.tmp, self.clock, self.runs)

    def test_switches_on_at_start_minus_lead_and_sweeps(self):
        self.e.set_schedule((self.clock.t + 3600) * 1000, 30)   # page sends epoch ms
        self.e.tick()
        self.assertFalse(self.e.public()["active"])
        self.assertEqual(self.runs.calls, [])
        self.clock.t += 1800 - 1
        self.e.tick()
        self.assertFalse(self.e.public()["active"])
        self.clock.t += 1
        self.e.tick()
        p = self.e.public()
        self.assertTrue(p["active"])
        self.assertEqual(p["activated_by"], "schedule")
        self.assertEqual(self.runs.calls, ["ai-off.sh"])
        self.assertEqual(p["kali"]["left"], 0)

    def test_resweeps_every_interval_while_on(self):
        self.e.turn_on()
        self.e.tick()
        self.e.tick()
        self.assertEqual(self.runs.calls, ["ai-off.sh"])
        self.clock.t += exam_mod.SWEEP_EVERY_S
        self.e.tick()
        self.assertEqual(self.runs.calls, ["ai-off.sh", "ai-off.sh"])

    def test_off_restores_once_and_disarms_past_schedule(self):
        self.e.set_schedule(self.clock.t - 10, 30)   # start already passed
        self.e.tick()
        self.assertTrue(self.e.public()["active"])
        self.e.turn_off()
        self.e.tick()
        self.e.tick()
        self.assertEqual(self.runs.calls, ["ai-off.sh", "ai-on.sh"])
        p = self.e.public()
        self.assertFalse(p["active"])
        self.assertIsNone(p["start"])     # would otherwise re-activate at once

    def test_off_when_never_on_runs_nothing(self):
        self.e.turn_off()
        self.e.tick()
        self.assertEqual(self.runs.calls, [])

    def test_state_survives_restart(self):
        self.e.turn_on()
        self.e.tick()
        e2 = make(self.tmp, self.clock, self.runs)
        self.assertTrue(e2.public()["active"])
        self.assertEqual(e2.token, self.e.token)
        e2.tick()                       # no immediate re-sweep after restart within the interval
        self.assertEqual(self.runs.calls, ["ai-off.sh"])

    def test_runner_failure_is_reported_not_raised(self):
        def boom(_):
            raise OSError("no bash")
        e = make(tempfile.mkdtemp(), self.clock, boom)
        e.turn_on()
        e.tick()
        k = e.public()["kali"]
        self.assertEqual(k["rc"], -1)
        self.assertIn("no bash", k["log"])

    def test_root_half_requested_and_counted(self):
        root = Path(tempfile.mkdtemp())
        old, exam_mod.ROOT_DIR = exam_mod.ROOT_DIR, root
        try:
            self.e.turn_on()
            self.e.tick()
            self.assertEqual((root / "request").read_text(), "off\n")
            (root / "root.log").write_text("killed(TERM) 9 ollama\nCHECK: AI processes left: 1\n")
            k = self.e.public()["kali"]
            self.assertEqual(k["left"], 1)
            self.assertIn("ollama", k["log"])
            self.e.turn_off()
            self.e.tick()
            self.assertEqual((root / "request").read_text(), "on\n")
        finally:
            exam_mod.ROOT_DIR = old

    def test_bad_lead_rejected(self):
        with self.assertRaises(ValueError):
            self.e.set_schedule(None, 5000)

    def test_host_report_and_staleness(self):
        self.e.host_report({"active": True, "left": 0, "log": "x"})
        self.assertTrue(self.e.public()["host"]["online"])
        self.clock.t += exam_mod.HOST_STALE_S + 1
        self.assertFalse(self.e.public()["host"]["online"])


class Http(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        exam_mod.run_script = Runs()          # never run the real scripts in tests
        cls.servers, cls.stop = server.serve(0, None, state_dir=cls.tmp)
        server.exam.runner = Runs()
        cls.port = cls.servers[0].server_address[1]
        # remote listener on loopback but with the remote handler, to test token rules
        cls.remote = server.ThreadingHTTPServer(("127.0.0.1", 0), server.RemoteHandler)
        threading.Thread(target=cls.remote.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.stop.set()
        for s in cls.servers + [cls.remote]:
            s.shutdown()

    def req(self, path, body=None, headers=None, port=None):
        r = urllib.request.Request(f"http://127.0.0.1:{port or self.port}{path}",
                                   data=None if body is None else json.dumps(body).encode(),
                                   headers=headers or {}, method="GET" if body is None else "POST")
        try:
            with urllib.request.urlopen(r, timeout=5) as resp:
                return resp.status, json.loads(resp.read()), resp.headers
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"{}"), e.headers

    def test_post_needs_bridge_header(self):
        code, _, _ = self.req("/api/exam/on", {})
        self.assertEqual(code, 403)
        self.assertFalse(server.exam.public()["active"])

    def test_cors_only_for_local_origins(self):
        _, _, h = self.req("/api/exam/state", headers={"Origin": "http://localhost:5173"})
        self.assertEqual(h.get("Access-Control-Allow-Origin"), "http://localhost:5173")
        _, _, h = self.req("/api/exam/state", headers={"Origin": "https://evil.example"})
        self.assertIsNone(h.get("Access-Control-Allow-Origin"))

    def test_schedule_on_off_roundtrip(self):
        hdr = {"X-HT-Bridge": "1", "Content-Type": "application/json"}
        code, st, _ = self.req("/api/exam/schedule", {"start": 4_102_444_800_000, "lead_min": 45}, hdr)
        self.assertEqual((code, st["lead_min"], st["start"]), (200, 45, 4_102_444_800.0))
        code, st, _ = self.req("/api/exam/on", {}, hdr)
        self.assertTrue(st["active"])
        code, st, _ = self.req("/api/exam/off", {}, hdr)
        self.assertFalse(st["active"])

    def test_remote_needs_token_and_only_host_routes(self):
        rp = self.remote.server_address[1]
        self.assertEqual(self.req("/api/exam/host", port=rp)[0], 403)
        tok = {"X-HT-Token": server.exam.token}
        code, body, _ = self.req("/api/exam/host", headers=tok, port=rp)
        self.assertEqual(code, 200)
        self.assertNotIn("token", body)
        self.assertEqual(self.req("/api/exam/state", headers=tok, port=rp)[0], 403)
        self.assertEqual(self.req("/api/exam/on", {}, {**tok, "X-HT-Bridge": "1"}, port=rp)[0], 403)
        code, _, _ = self.req("/api/exam/host-report", {"active": True, "left": 2, "log": "l"},
                              {**tok, "Content-Type": "application/json"}, port=rp)
        self.assertEqual(code, 200)
        self.assertEqual(server.exam.public()["host"]["left"], 2)

    def test_host_kit_serves_only_listed_scripts(self):
        rp = self.remote.server_address[1]
        tok = {"X-HT-Token": server.exam.token}
        code, body, _ = self.req("/api/exam/host-kit?name=host-watch.ps1", headers=tok, port=rp)
        self.assertEqual(code, 200)
        self.assertIn("host-report", body["text"])
        self.assertEqual(self.req("/api/exam/host-kit?name=../exam.json", headers=tok, port=rp)[0], 404)
        self.assertEqual(self.req("/api/exam/host-kit?name=ai-off.ps1", port=rp)[0], 403)

    def test_state_never_exposes_token(self):
        _, st, _ = self.req("/api/exam/state")
        self.assertNotIn(server.exam.token, json.dumps(st))


if __name__ == "__main__":
    unittest.main()
