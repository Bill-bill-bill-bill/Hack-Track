# hacktrack-bridge

A local companion service for the Hack Track page on Kali. The page is a static browser app, so anything that has to touch the machine goes through this service on `127.0.0.1:8790`. It is stdlib Python with no dependencies.

## Exam mode (AI lockdown)

- Panel: top of the Exam Simulator page (`/exam`). Set the real exam start and a lead time (default 30 min). Exam mode switches on at start minus lead, or right away with **Exam mode on now**. It stays on until you press **AI back on**.
- Kali, user side: the bridge runs `exam/ai-off.sh` and re-sweeps every 2 minutes. That stops and disables AI units, comments out AI cron lines, hides autostart entries, kills tmux loops (kjobs-rc, lanes) and processes: Codex, Claude app/Code/Remote Control, LM Studio, Ollama, Notion desktop, grokbot, Daybreak, Copilot. Nothing is uninstalled. Undo is `exam/ai-on.sh`, from saved state.
- Kali, root side: `hacktrack-exam-root.path` runs `root-run.sh` (the same scripts, as root) when the bridge writes `off`/`on` to `/var/lib/hacktrack-bridge/request`. That covers system units like `ollama.service`, root cron and other users' processes.
- Windows host: the scheduled task `HackTrack Exam Watch` runs `exam/host-watch.ps1` every minute. It asks the bridge, then runs `ai-off.ps1`/`ai-on.ps1`, which kill processes, disable services and tasks, turn off Run/Startup/Store startup entries and set the Copilot-off policy. It caches the schedule, so it switches on even if the VM is unreachable. It only restores on an explicit off.
- The keep-list includes Hack Track, the bridge, penelope, ligolo, BloodHound and VMware.

## Install

On Kali, run `bash tools/hacktrack-bridge/install-kali.sh`. It prints the one-block paste for the Windows host (an admin PowerShell).

## API

| Route | Who | Notes |
|---|---|---|
| `GET /api/health` | loopback | |
| `GET /api/exam/state` | loopback | |
| `POST /api/exam/schedule` `{start: epoch ms or null, lead_min}` | loopback + `X-HT-Bridge: 1` | |
| `POST /api/exam/on`, `POST /api/exam/off` | loopback + `X-HT-Bridge: 1` | |
| `GET /api/exam/host`, `POST /api/exam/host-report`, `GET /api/exam/host-kit?name=` | host-only IP + `X-HT-Token` | Windows watcher |

CORS is allowed only for localhost, 127.0.0.1 and Tauri origins. Other features (the workspace panes) add their routes to `ROUTES` in `server.py`.

Tests: `python3 -m unittest -v tools/hacktrack-bridge/test_bridge.py`
