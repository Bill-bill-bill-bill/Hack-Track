#!/usr/bin/env bash
# ai-off.sh - Kali: stop AI apps for the OSCP exam and keep them from restarting.
# Stops+disables matching systemd units (user and system), comments out matching cron lines,
# hides matching autostart entries, kills tmux panes/sessions hosting AI loops, kills processes.
# Nothing is uninstalled or deleted. State goes to /var/tmp/kjobs/ai-off/last; undo = ai-on.sh.
set -u
S=${AI_OFF_DIR:-/var/tmp/kjobs/ai-off}
# While Exam mode is on ($S/active exists) a re-run adds to the same state dir, so one undo restores everything.
if [ -f "$S/active" ] && [ -d "$(readlink -f "$S/last")" ]; then ST=$(readlink -f "$S/last")
else ST="$S/state-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$ST"; ln -sfn "$ST" "$S/last"; fi
touch "$S/active"
AI='codex|claude|anthropic|lm-?studio|(^|[^a-z0-9])lms([^a-z0-9]|$)|ollama|grok|daybreak|copilot|chatgpt|gemini|notion-app|notion-desktop|/notion( |$)|kjobs-rc|(^|[^a-z])rtq([^a-z]|$)'
KEEP='kwb|workbench|wb-creds|wb-proof|penelope|bloodhound|neo4j|postgres|vmware|ligolo|bill-pivot|ai-off|ai-on|hacktrack-bridge|hack-track|host-watch'
is_ai(){ grep -Eiq -- "$AI" <<<"$1" && ! grep -Eiq -- "$KEEP" <<<"$1"; }
# units: keep-list on the unit name only; processes: keep-list on the first 3 argv words only,
# so a Codex prompt that mentions the workbench is still killed.
unit_ai(){ grep -Eiq -- "$AI" <<<"$1 $2" && ! grep -Eiq -- "$KEEP" <<<"$1"; }
proc_ai(){ grep -Eiq -- "$AI" <<<"${1:0:400}" && ! grep -Eiq -- "$KEEP" <<<"$(awk '{print $1,$2,$3}' <<<"$1")"; }
say(){ printf '%s\n' "$*" | tee -a "$ST/log"; }
SUDO=""; if sudo -n /usr/bin/systemctl --version >/dev/null 2>&1 || { [ -t 0 ] && sudo -v; }; then SUDO=sudo; else say "!! no sudo: system units/root cron skipped"; fi

say "== systemd units =="
touch "$ST/units"
scan_units(){ # $1=user|system
  local sc=(systemctl --user); [ "$1" = system ] && sc=($SUDO systemctl)
  [ "$1" = system ] && [ -z "$SUDO" ] && return
  { "${sc[@]}" list-unit-files --no-legend --type=service,timer,path,socket 2>/dev/null | awk '$2=="enabled"{print $1}'
    "${sc[@]}" list-units --all --no-legend --plain --type=service,timer,path,socket 2>/dev/null | awk '$3!="inactive"{print $1}'
  } | sort -u | while read -r u; do
    [ -z "$u" ] && continue
    info=$("${sc[@]}" show -p ExecStart -p FragmentPath -p Description "$u" 2>/dev/null | tr '\n' ' ')
    if [ "$1" = system ]; then case "$info" in *FragmentPath=/etc/*|*FragmentPath=/usr/local/*|*FragmentPath=/home/*) ;; *) info="";; esac; fi
    unit_ai "$u" "$info" || continue
    fs=$("${sc[@]}" is-enabled "$u" 2>/dev/null); as=$("${sc[@]}" is-active "$u" 2>/dev/null)
    echo "$1 $u ${fs:-unknown} ${as:-unknown}" >>"$ST/units"
    "${sc[@]}" stop "$u" 2>/dev/null; "${sc[@]}" disable "$u" 2>/dev/null
    say "stopped+disabled ($1) $u  [was $fs/$as]"
  done
}
scan_units user; scan_units system

say "== cron =="
cron_one(){ # $1 = "" or sudo
  local c; c=$($1 crontab -l 2>/dev/null) || return
  local new; new=$(while IFS= read -r l; do
      if [[ "$l" != \#* ]] && is_ai "$l"; then printf '#AIOFF# %s\n' "$l"; else printf '%s\n' "$l"; fi; done <<<"$c")
  if [ "$new" != "$c" ]; then
    printf '%s\n' "$c" >"$ST/crontab.${1:-user}.bak"; printf '%s\n' "$new" | $1 crontab -
    grep '^#AIOFF# ' <<<"$new" | while IFS= read -r l; do say "cron (${1:-user}) off: ${l#\#AIOFF# }"; done
  fi
}
cron_one ""; [ -n "$SUDO" ] && cron_one sudo
if [ -n "$SUDO" ]; then for f in /etc/cron.d/*; do [ -f "$f" ] || continue
  if grep -v '^#' "$f" | grep -Eiq -- "$AI" && ! grep -Eiq -- "$KEEP" "$f"; then
    cp -p "$f" "$ST/crond.$(basename "$f").bak"; echo "$f" >>"$ST/crond"
    sudo sed -i -E '/^[^#]/{/'"$(sed 's/\//\\\//g' <<<"$AI")"'/I s/^/#AIOFF# /}' "$f"; say "cron.d off: $f"; fi; done; fi

say "== autostart =="
mkdir -p ~/.config/autostart
for f in ~/.config/autostart/*.desktop; do [ -f "$f" ] || continue
  if is_ai "$(cat "$f")" && ! grep -q '^Hidden=true' "$f"; then
    cp -p "$f" "$ST/autostart.$(basename "$f").bak"; echo "$f" >>"$ST/autostart-user"
    sed -i '0,/^\[Desktop Entry\]/s//[Desktop Entry]\nHidden=true/' "$f"; say "autostart hidden: $f"; fi; done
for f in /etc/xdg/autostart/*.desktop; do [ -f "$f" ] || continue; o=~/.config/autostart/$(basename "$f")
  if is_ai "$(cat "$f")" && [ ! -e "$o" ]; then printf '[Desktop Entry]\nType=Application\nName=%s\nHidden=true\nX-AIOFF=1\n' "$(basename "$f" .desktop)" >"$o"
    echo "$o" >>"$ST/autostart-override"; say "autostart override: $(basename "$f")"; fi; done

# process table + ancestors of this script (never kill our own shell)
declare -A PP; while read -r p pp _; do PP[$p]=$pp; done < <(ps -eo pid=,ppid=)
declare -A SELF; p=$$; while [ -n "$p" ] && [ "$p" != 0 ] && [ "$p" != 1 ]; do SELF[$p]=1; p=${PP[$p]:-}; done
ai_pids(){ ps -eo pid=,args= | while read -r p a; do [ -n "${SELF[$p]:-}" ] && continue; case "$a" in tmux*|*/tmux*) continue;; esac; proc_ai "$a" && echo "$p"; done; }
under(){ local x=$1 t=$2; while [ -n "$x" ] && [ "$x" != 0 ] && [ "$x" != 1 ]; do [ "$x" = "$t" ] && return 0; x=${PP[$x]:-}; done; return 1; }
mapfile -t AIP < <(ai_pids)

say "== tmux =="
touch "$ST/tmux"
for sock in /tmp/tmux-"$(id -u)"/*; do [ -S "$sock" ] || continue
  tmux -S "$sock" list-panes -a -F '#{session_name}|@|#{pane_id}|@|#{pane_pid}|@|#{pane_current_path}|@|#{pane_start_command}' 2>/dev/null |
  awk -F'[|]@[|]' -v OFS='\037' '{c=$5; sub(/^"/,"",c); sub(/"$/,"",c); print $1,$2,$3,$4,c}' |
  while IFS=$'\037' read -r sn pid ppid cwd cmd; do
    grep -Eiq -- "$KEEP" <<<"$sn" && continue
    hit=""; is_ai "$sn" && hit=session
    if [ -z "$hit" ]; then is_ai "$cmd" && hit=pane; for a in "${AIP[@]}"; do under "$a" "$ppid" && hit=pane; done; fi
    [ -n "${SELF[$ppid]:-}" ] && { say "skip tmux pane $sn $pid (this shell runs in it)"; continue; }
    [ -z "$hit" ] && continue
    printf '%s\037%s\037%s\037%s\037%s\n' "$sock" "$hit" "$sn" "$cwd" "$cmd" >>"$ST/tmux"
    if [ "$hit" = session ]; then tmux -S "$sock" kill-session -t "=$sn" 2>/dev/null && say "tmux session killed: $(basename "$sock")/$sn  cmd: $cmd"
    else tmux -S "$sock" kill-pane -t "$pid" 2>/dev/null && say "tmux pane killed: $(basename "$sock")/$sn $pid  cmd: $cmd"; fi
  done; done
sort -u "$ST/tmux" -o "$ST/tmux"

say "== processes =="
for r in 1 2 3; do
  mapfile -t AIP < <(ai_pids); [ ${#AIP[@]} -eq 0 ] && break
  for p in "${AIP[@]}"; do a=$(ps -o args= -p "$p" 2>/dev/null) || continue
    [ "$r" -lt 3 ] && sig=TERM || sig=KILL
    kill -s $sig "$p" 2>/dev/null || $SUDO kill -s $sig "$p" 2>/dev/null; say "killed($sig) $p ${a:0:140}"; done
  sleep 2; done
sleep 3; mapfile -t AIP < <(ai_pids)
for p in "${!SELF[@]}"; do a=$(ps -o args= -p "$p" 2>/dev/null); proc_ai "$a" && say "!! this shell runs under an AI process ($p ${a:0:80}): close that window yourself"; done
say ""; say "Notion AI in Firefox can't be scripted off: just don't open it. Workbench (Home/Serve/penelope/wb-creds-sync) left running."
say "state: $ST   undo: bash $S/ai-on.sh"
[ ${#AIP[@]} -gt 0 ] && ps -o pid=,args= -p "$(IFS=,; echo "${AIP[*]}")" | sed 's/^/left: /' | tee -a "$ST/log"
say "CHECK: AI processes left: ${#AIP[@]}"
