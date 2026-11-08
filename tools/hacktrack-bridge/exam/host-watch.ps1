# host-watch.ps1 - Windows host side of Hack Track Exam mode. A scheduled task runs it every minute.
# It asks hacktrack-bridge on the Kali VM whether Exam mode is on. If it is, it runs ai-off.ps1
# (and again every 5 minutes, which catches restarts). When Exam mode goes off it runs ai-on.ps1.
# It caches the schedule, so if the VM can't be reached it still switches on at start-minus-lead.
# Then it reports back to the page. Config: %USERPROFILE%\ai-off\watch.json {url, token}.
$ErrorActionPreference = 'SilentlyContinue'
$D = "$env:USERPROFILE\ai-off"
$cfg = Get-Content -Raw -Path "$D\watch.json" | ConvertFrom-Json
if (-not $cfg) { return }
$hdr = @{ 'X-HT-Token' = $cfg.token }
$nowS = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$cache = "$D\watch-cache.json"
$remote = $null
try { $remote = Invoke-RestMethod -Uri "$($cfg.url)/api/exam/host" -Headers $hdr -TimeoutSec 8 } catch { }
if ($remote) { $remote | ConvertTo-Json | Set-Content -Path $cache; $s = $remote }
else { $s = Get-Content -Raw -Path $cache | ConvertFrom-Json }

$want = $false
if ($s) {
  $want = [bool]$s.active
  if (-not $want -and -not $remote -and $null -ne $s.switch_at -and $nowS -ge [double]$s.switch_at) { $want = $true }
}
$applied = Test-Path "$D\active"
$lastSweep = (Get-Item -Path "$D\last-sweep.txt").LastWriteTimeUtc
$stale = (-not $lastSweep) -or (([DateTime]::UtcNow - $lastSweep).TotalMinutes -ge 5)
$out = $null
if ($want -and (-not $applied -or $stale)) {
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File "$D\ai-off.ps1" *>&1 | Out-String
  Set-Content -Path "$D\last-sweep.txt" -Value $out
} elseif (-not $want -and $applied -and $remote) {
  # Only restore on an explicit "off" from the bridge, never because the VM is unreachable.
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File "$D\ai-on.ps1" *>&1 | Out-String
  Remove-Item -Path "$D\last-sweep.txt" -Force
}
if ($remote) {
  $log = if ($out) { $out } else { Get-Content -Raw -Path "$D\last-sweep.txt" }
  $left = $null
  if ($log -match 'CHECK: AI processes left: (\d+)') { $left = [int]$Matches[1] }
  $body = @{ active = (Test-Path "$D\active"); left = $left; log = "$log" } | ConvertTo-Json -Compress
  try { Invoke-RestMethod -Method Post -Uri "$($cfg.url)/api/exam/host-report" -Headers $hdr -ContentType 'application/json' -Body $body -TimeoutSec 8 | Out-Null } catch { }
}
