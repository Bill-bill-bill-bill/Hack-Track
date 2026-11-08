#!/usr/bin/env bash
# root-run.sh - root half of Exam mode. hacktrack-exam-root.service (started by a .path unit when
# the bridge writes /var/lib/hacktrack-bridge/request) runs it. It only accepts the words
# "off" or "on" and runs the root-owned copies of ai-off.sh / ai-on.sh, which cover system
# units, root cron, /etc/cron.d and AI processes owned by other users. Output: root.log.
set -u
D=/var/lib/hacktrack-bridge
L=/usr/local/lib/hacktrack-bridge
req=$(head -c 8 "$D/request" 2>/dev/null | tr -cd 'a-z')
export AI_OFF_DIR=/var/tmp/kjobs/ai-off-root
case "$req" in
  off) out=$(bash "$L/ai-off.sh" </dev/null 2>&1) ;;
  on)  out=$(bash "$L/ai-on.sh" </dev/null 2>&1) ;;
  *)   exit 0 ;;
esac
{ echo "== root $req $(date -u +%FT%TZ) =="; printf '%s\n' "$out"; } > "$D/root.log.tmp"
mv -f "$D/root.log.tmp" "$D/root.log"; chmod 644 "$D/root.log"
