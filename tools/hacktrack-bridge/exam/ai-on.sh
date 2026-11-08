#!/usr/bin/env bash
# ai-on.sh - Kali: undo ai-off.sh from its saved state (/var/tmp/kjobs/ai-off/last).
set -u
S=${AI_OFF_DIR:-/var/tmp/kjobs/ai-off}; ST=$(readlink -f "$S/last" 2>/dev/null)
[ -d "$ST" ] || { echo "no ai-off state in $S"; exit 1; }
SUDO=""; if sudo -n /usr/bin/systemctl --version >/dev/null 2>&1 || { [ -t 0 ] && sudo -v; }; then SUDO=sudo; fi
rm -f "$S/active"
echo "== restoring from $ST =="
while read -r scope u fs as; do sc=(systemctl --user); [ "$scope" = system ] && sc=($SUDO systemctl)
  [ "$fs" = enabled ] && "${sc[@]}" enable "$u" 2>/dev/null && echo "enabled ($scope) $u"
  [ "$as" = active ] && "${sc[@]}" start "$u" 2>/dev/null && echo "started ($scope) $u"
done < <(cat "$ST/units" 2>/dev/null)
[ -f "$ST/crontab.user.bak" ] && crontab -l | sed 's/^#AIOFF# //' | crontab - && echo "user cron restored"
[ -f "$ST/crontab.sudo.bak" ] && [ -n "$SUDO" ] && sudo crontab -l | sed 's/^#AIOFF# //' | sudo crontab - && echo "root cron restored"
while read -r f; do $SUDO sed -i 's/^#AIOFF# //' "$f" && echo "cron.d restored: $f"; done < <(cat "$ST/crond" 2>/dev/null)
while read -r f; do cp -p "$ST/autostart.$(basename "$f").bak" "$f" && echo "autostart restored: $f"; done < <(cat "$ST/autostart-user" 2>/dev/null)
while read -r f; do grep -q '^X-AIOFF=1' "$f" 2>/dev/null && mv "$f" "$ST/" && echo "autostart override removed: $(basename "$f")"; done < <(cat "$ST/autostart-override" 2>/dev/null)
while IFS=$'\037' read -r sock kind sn cwd cmd; do [ -n "$cmd" ] || cmd=""
  if [ "$kind" = session ] || ! tmux -S "$sock" has-session -t "=$sn" 2>/dev/null; then
    tmux -S "$sock" new-session -d -s "$sn" -c "$cwd" ${cmd:+"$cmd"} 2>/dev/null || tmux -S "$sock" new-window -t "=$sn" -c "$cwd" ${cmd:+"$cmd"}
  else tmux -S "$sock" new-window -t "=$sn" -c "$cwd" ${cmd:+"$cmd"}; fi
  echo "tmux back: $(basename "$sock")/$sn ${cmd:-(empty shell: restart your loop there)}"
done < <(cat "$ST/tmux" 2>/dev/null)
echo "Apps you launch by hand (Claude app, LM Studio, codex, claude remote-control) start normally again."
echo "CHECK: restore done from $(basename "$ST")"
