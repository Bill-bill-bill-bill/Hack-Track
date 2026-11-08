"""Exam mode for hacktrack-bridge.

Holds the exam schedule (start time + lead minutes), switches Exam mode on when the lead
window opens (or on demand), runs exam/ai-off.sh on Kali and re-sweeps every few minutes
while it is on, runs exam/ai-on.sh when it is switched off, and records what the Windows
host watcher (exam/host-watch.ps1) last reported. State lives in exam.json so a restart
or reboot keeps the schedule and the on/off latch.

Exam mode never turns itself off: only an explicit "off" restores the AI apps.
"""
from __future__ import annotations

import json
import os
import re
import secrets
import subprocess
import threading
import time
from pathlib import Path
from typing import Callable

SCRIPTS = Path(__file__).resolve().parent / "exam"
# Root half: the bridge writes "off"/"on" here and a root .path unit runs root-run.sh (system units,
# root cron, other users' AI processes). See install-kali.sh. Missing dir = user-level only.
ROOT_DIR = Path(os.environ.get("HT_BRIDGE_ROOT_DIR", "/var/lib/hacktrack-bridge"))
SWEEP_EVERY_S = 120
HOST_STALE_S = 180
LOG_KEEP = 6000
_LEFT_RE = re.compile(r"CHECK: AI processes left: (\d+)")


def default_state_dir() -> Path:
    base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(os.environ.get("HT_BRIDGE_STATE", Path(base) / "hacktrack-bridge"))


def run_script(name: str) -> tuple[int, str]:
    """Run exam/<name> with bash; return (exit code, combined output)."""
    p = subprocess.run(
        ["bash", str(SCRIPTS / name)],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=300,
    )
    return p.returncode, (p.stdout + p.stderr)


def _read(p: Path) -> str:
    try:
        return p.read_text()[-LOG_KEEP:]
    except OSError:
        return ""


def _write(p: Path, text: str) -> None:
    try:
        if p.parent.is_dir():
            p.write_text(text)
    except OSError:
        pass


class Exam:
    def __init__(self, state_dir: Path | None = None,
                 runner: Callable[[str], tuple[int, str]] = run_script,
                 clock: Callable[[], float] = time.time):
        self.dir = Path(state_dir or default_state_dir())
        self.dir.mkdir(parents=True, exist_ok=True)
        self.path = self.dir / "exam.json"
        self.runner = runner
        self.clock = clock
        self.lock = threading.RLock()
        self.busy = False
        self.wake = threading.Event()   # set by commands so the ticker acts at once
        self.s = {
            "start": None,          # exam start, epoch seconds
            "lead_min": 30,
            "active": False,
            "activated_at": None,
            "activated_by": None,   # "schedule" | "manual"
            "kali": {"last_run": None, "action": None, "left": None, "rc": None, "log": ""},
            "host": {"last_seen": None, "active": None, "left": None, "log": ""},
            "restore_pending": False,
            "token": secrets.token_urlsafe(18),
        }
        if self.path.exists():
            try:
                saved = json.loads(self.path.read_text())
                for k in ("kali", "host"):
                    self.s[k].update(saved.pop(k, {}) or {})
                self.s.update(saved)
            except (ValueError, OSError):
                pass
        self._save()

    # ---- persistence ----
    def _save(self) -> None:
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.s, indent=1))
        os.chmod(tmp, 0o600)
        tmp.replace(self.path)

    @property
    def token(self) -> str:
        return self.s["token"]

    # ---- views ----
    def public(self) -> dict:
        with self.lock:
            now = self.clock()
            start, lead = self.s["start"], self.s["lead_min"]
            switch_at = start - lead * 60 if start is not None else None
            kali = dict(self.s["kali"])
            root_log = _read(ROOT_DIR / "root.log")
            if root_log:
                rm = _LEFT_RE.findall(root_log)
                if rm and kali["left"] is not None:
                    kali["left"] += int(rm[-1])
                kali["log"] = (kali["log"] + "\n" + root_log)[-LOG_KEEP:]
            host = dict(self.s["host"])
            host["online"] = bool(host["last_seen"] and now - host["last_seen"] < HOST_STALE_S)
            return {
                "now": now,
                "start": start,
                "lead_min": lead,
                "switch_at": switch_at,
                "active": self.s["active"],
                "activated_at": self.s["activated_at"],
                "activated_by": self.s["activated_by"],
                "busy": self.busy,
                "restore_pending": self.s["restore_pending"],
                "kali": kali,
                "host": host,
            }

    def host_view(self) -> dict:
        """What the Windows watcher needs, including the schedule so it can act if the VM is down."""
        v = self.public()
        return {k: v[k] for k in ("now", "start", "lead_min", "switch_at", "active")}

    # ---- commands ----
    def set_schedule(self, start: float | None, lead_min: int | float | None) -> dict:
        if start is not None:
            start = float(start)
            if start > 1e11:            # accept epoch ms from the page
                start /= 1000.0
        lead = 30 if lead_min is None else int(lead_min)
        if not 0 <= lead <= 24 * 60:
            raise ValueError("lead_min must be 0..1440")
        with self.lock:
            self.s["start"], self.s["lead_min"] = start, lead
            self._save()
        self.wake.set()
        return self.public()

    def turn_on(self, by: str = "manual") -> dict:
        with self.lock:
            if not self.s["active"]:
                self.s.update(active=True, activated_at=self.clock(), activated_by=by)
                self.s["kali"]["last_run"] = None      # force an immediate sweep
                self._save()
        self.wake.set()
        return self.public()

    def turn_off(self) -> dict:
        with self.lock:
            was = self.s["active"]
            # Disarm the schedule too, otherwise a start time in the past would switch it straight back on.
            self.s.update(active=False, activated_at=None, activated_by=None, start=None,
                          restore_pending=bool(was or self.s["restore_pending"]))
            self._save()
        self.wake.set()
        return self.public()

    def host_report(self, data: dict) -> dict:
        with self.lock:
            h = self.s["host"]
            h["last_seen"] = self.clock()
            h["active"] = bool(data.get("active"))
            left = data.get("left")
            h["left"] = int(left) if isinstance(left, (int, float)) else None
            h["log"] = str(data.get("log", ""))[-LOG_KEEP:]
            self._save()
        return {"ok": True, "active": self.s["active"]}

    # ---- scheduler ----
    def due(self) -> bool:
        s = self.s
        return (not s["active"] and s["start"] is not None
                and self.clock() >= s["start"] - s["lead_min"] * 60)

    def loop(self, stop: threading.Event, every_s: float = 5.0) -> None:
        while not stop.is_set():
            self.wake.wait(every_s)
            self.wake.clear()
            try:
                self.tick()
            except Exception as e:  # noqa: BLE001 - never let the ticker die
                with self.lock:
                    self.s["kali"]["log"] = f"ticker error: {e}"

    def tick(self) -> None:
        """One scheduler step; the bridge calls it every few seconds and whenever wake is set."""
        with self.lock:
            restore = self.s["restore_pending"] and not self.s["active"]
        if restore:
            self._run("ai-on.sh", "restore")
            with self.lock:           # one attempt; the panel shows rc + log if it failed
                self.s["restore_pending"] = False
                self._save()
            return
        with self.lock:
            if self.due():
                self.s.update(active=True, activated_at=self.clock(), activated_by="schedule")
                self.s["kali"]["last_run"] = None
                self._save()
            need = self.s["active"] and (
                self.s["kali"]["last_run"] is None
                or self.clock() - self.s["kali"]["last_run"] >= SWEEP_EVERY_S)
        if need:
            self._run("ai-off.sh", "sweep")

    def _run(self, script: str, action: str) -> None:
        with self.lock:
            if self.busy:
                return
            self.busy = True
        try:
            _write(ROOT_DIR / "request", "off\n" if script == "ai-off.sh" else "on\n")
            try:
                rc, out = self.runner(script)
            except Exception as e:  # noqa: BLE001 - report any runner failure in the panel
                rc, out = -1, f"{type(e).__name__}: {e}"
            m = _LEFT_RE.findall(out)
            with self.lock:
                k = self.s["kali"]
                k.update(last_run=self.clock(), action=action, rc=rc,
                         left=int(m[-1]) if m else None, log=out[-LOG_KEEP:])
                self._save()
        finally:
            with self.lock:
                self.busy = False
