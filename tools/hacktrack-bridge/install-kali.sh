#!/usr/bin/env bash
# install-kali.sh - install hacktrack-bridge on Kali (safe to re-run). Run as your normal user;
# it asks for sudo once.
# - user service hacktrack-bridge.service: 127.0.0.1:8790, plus the VM's default-route IP so the
#   Windows host watcher can reach it (token-protected, host routes only)
# - root half: root-owned copies of the exam scripts in /usr/local/lib/hacktrack-bridge, and a
#   .path unit that runs root-run.sh when the bridge writes "off"/"on" to
#   /var/lib/hacktrack-bridge/request. That covers system units like ollama.service and root cron.
#   It can run only those two fixed actions; no general sudo rights are added.
# - linger on, so the schedule fires even before you log in
# - prints the one-block paste for the Windows host
set -euo pipefail
SRC=$(cd "$(dirname "$0")" && pwd)
DST=~/.local/share/hacktrack-bridge
PORT=8790
U=$(id -un)
mkdir -p "$DST" ~/.config/systemd/user
cp -a "$SRC"/. "$DST"/
chmod +x "$DST"/exam/*.sh

IFACE=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
HOST_IP=$(ip -4 -o addr show dev "${IFACE:-eth0}" 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4; exit}')

cat > ~/.config/systemd/user/hacktrack-bridge.service <<EOF
[Unit]
Description=Hack Track bridge (exam mode, workspace)
After=network-online.target

[Service]
Environment=HT_BRIDGE_PORT=$PORT
Environment=HT_BRIDGE_HOST_IP=$HOST_IP
ExecStart=/usr/bin/python3 $DST/server.py
Restart=always
RestartSec=3
Nice=10

[Install]
WantedBy=default.target
EOF

# root half
sudo install -d -m 755 -o root -g root /usr/local/lib/hacktrack-bridge
sudo install -m 755 -o root -g root "$SRC"/exam/ai-off.sh "$SRC"/exam/ai-on.sh "$SRC"/exam/root-run.sh /usr/local/lib/hacktrack-bridge/
sudo install -d -m 2770 -o root -g "$(id -gn)" /var/lib/hacktrack-bridge
sudo tee /etc/systemd/system/hacktrack-exam-root.service >/dev/null <<'EOF'
[Unit]
Description=Hack Track exam mode: root half (system units, root cron)

[Service]
Type=oneshot
ExecStart=/usr/local/lib/hacktrack-bridge/root-run.sh
EOF
sudo tee /etc/systemd/system/hacktrack-exam-root.path >/dev/null <<'EOF'
[Unit]
Description=Run the Hack Track exam root half when the bridge asks

[Path]
PathChanged=/var/lib/hacktrack-bridge/request

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now hacktrack-exam-root.path >/dev/null 2>&1
sudo loginctl enable-linger "$U"

systemctl --user daemon-reload
systemctl --user enable hacktrack-bridge.service >/dev/null 2>&1
systemctl --user restart hacktrack-bridge.service
sleep 2
TOKEN=$(python3 "$DST/server.py" --print-token)

echo "installed: $DST + hacktrack-bridge.service (user), hacktrack-exam-root.path (root half), linger on"
echo "listening: 127.0.0.1:$PORT and ${HOST_IP:-<none>}:$PORT (host watcher)"
cat <<EOF

==== WINDOWS HOST: paste this whole block into an ADMIN PowerShell ====
\$D="\$env:USERPROFILE\\ai-off"; New-Item -ItemType Directory -Force \$D | Out-Null
\$u='http://$HOST_IP:$PORT'; \$h=@{'X-HT-Token'='$TOKEN'}
@{url=\$u; token='$TOKEN'} | ConvertTo-Json | Set-Content "\$D\\watch.json"
foreach (\$n in 'ai-off.ps1','ai-on.ps1','host-watch.ps1') { Set-Content -Encoding UTF8 "\$D\\\$n" (Invoke-RestMethod "\$u/api/exam/host-kit?name=\$n" -Headers \$h).text }
\$a=New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File \`"\$D\\host-watch.ps1\`""
\$t1=New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1); \$t2=New-ScheduledTaskTrigger -AtLogOn
\$p=New-ScheduledTaskPrincipal -UserId "\$env:USERDOMAIN\\\$env:USERNAME" -LogonType Interactive -RunLevel Highest
\$s=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'HackTrack Exam Watch' -Action \$a -Trigger \$t1,\$t2 -Principal \$p -Settings \$s -Force | Out-Null
Start-ScheduledTask -TaskName 'HackTrack Exam Watch'; Start-Sleep 20
"CHECK: watcher task " + (Get-ScheduledTask 'HackTrack Exam Watch').State + " - the Exam panel should now show 'Windows host: AI apps normal'"
==== end ====
EOF
curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null && echo "CHECK: hacktrack-bridge is up on 127.0.0.1:$PORT"
