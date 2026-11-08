# ai-on.ps1 - Windows host: undo ai-off.ps1 from its saved state (%USERPROFILE%\ai-off\last.txt).
# Run in an ADMIN PowerShell. Re-enables services/tasks/startup entries exactly as they were.
$ErrorActionPreference = 'SilentlyContinue'
$D  = "$env:USERPROFILE\ai-off"
$ST = Get-Content -Path "$D\last.txt"
if (-not $ST -or -not (Test-Path "$ST\state.json")) { Write-Host "no ai-off state in $D"; return }
Remove-Item -Path "$D\active" -Force
$s = Get-Content -Raw -Path "$ST\state.json" | ConvertFrom-Json
Write-Host "== restoring from $ST =="
foreach ($v in @($s.services)) {
  $mode = switch ($v.start) { 'Auto' { 'Automatic' } 'Manual' { 'Manual' } 'Disabled' { 'Disabled' } default { 'Manual' } }
  Set-Service -Name $v.name -StartupType $mode
  if ($v.delayed) { sc.exe config $v.name start= delayed-auto | Out-Null }
  if ($v.running) { Start-Service -Name $v.name }
  Write-Host "service $($v.name) -> $mode$(if ($v.running) { ', started' })"
}
foreach ($t in @($s.tasks)) { if ($t) { Enable-ScheduledTask -TaskPath $t.path -TaskName $t.name | Out-Null; Write-Host "task enabled $($t.path)$($t.name)" } }
foreach ($a in @($s.approved)) {
  if (-not $a) { continue }
  if ($null -ne $a.prev) { New-ItemProperty -Path $a.key -Name $a.name -PropertyType Binary -Value ([byte[]]$a.prev) -Force | Out-Null }
  else { Remove-ItemProperty -Path $a.key -Name $a.name }
  Write-Host "startup restored: $($a.name)"
}
foreach ($x in @($s.appx)) { if ($x) { Set-ItemProperty -Path $x.key -Name State -Value ([int]$x.prev) -Type DWord; Write-Host "store-app startup restored: $($x.key.Split('\')[-2])" } }
foreach ($p in @($s.policy)) {
  if (-not $p) { continue }
  if ($null -ne $p.prev) { Set-ItemProperty -Path $p.key -Name $p.name -Value ([int]$p.prev) -Type DWord } else { Remove-ItemProperty -Path $p.key -Name $p.name }
  Write-Host "policy restored: $($p.name)"
}
Write-Host 'Apps you start by hand (Claude, Codex, LM Studio, Ollama, Notion) open normally again; startup ones return at next sign-in.'
Write-Host "CHECK: restore done from $(Split-Path -Leaf $ST)"
