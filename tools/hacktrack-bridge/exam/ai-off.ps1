# ai-off.ps1 - Windows host: stop AI apps for the OSCP exam and keep them from restarting.
# Kills processes, stops+disables matching services, disables matching scheduled tasks, marks
# matching Run-key / Startup-folder / Store-app startup entries as disabled (same flags Task Manager
# uses) and sets the Windows Copilot off policy. Nothing is uninstalled or deleted.
# State: %USERPROFILE%\ai-off\last.txt -> state dir. Undo: ai-on.ps1. Run in an ADMIN PowerShell.
$ErrorActionPreference = 'SilentlyContinue'
$D  = "$env:USERPROFILE\ai-off"
New-Item -ItemType Directory -Force -Path $D | Out-Null
# While Exam mode is on ("$D\active" exists) a re-run adds to the same state, so one undo restores everything.
$prevST = if (Test-Path "$D\last.txt") { Get-Content -Path "$D\last.txt" } else { $null }
$merge = (Test-Path "$D\active") -and $prevST -and (Test-Path "$prevST\state.json")
if ($merge) { $ST = $prevST } else {
  $ST = Join-Path $D ('state-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
  New-Item -ItemType Directory -Force -Path $ST | Out-Null
  Set-Content -Path "$D\last.txt" -Value $ST
}
Set-Content -Path "$D\active" -Value (Get-Date).ToUniversalTime().ToString('o')
$AI   = 'codex|claude|anthropic|lm.?studio|lmstudio|ollama|grok|daybreak|copilot|chatgpt|openai|gemini|cursor|windsurf|notion'
$KEEP = 'vmware|vmx|penelope|ai-off|ai-on|host-watch|hacktrack|\\Intel\\'
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$state = [ordered]@{ services=@(); tasks=@(); approved=@(); appx=@(); policy=@() }
if ($merge) {
  $old = Get-Content -Raw -Path "$ST\state.json" | ConvertFrom-Json
  foreach ($k in @('services','tasks','approved','appx','policy')) { $state[$k] = @($old.$k | Where-Object { $_ }) }
}
function Say($m) { Write-Host $m; Add-Content -Path "$ST\log.txt" -Value $m }
function Save { $state | ConvertTo-Json -Depth 6 | Set-Content -Path "$ST\state.json" }
if (-not $admin) { Say '!! not admin: services and machine-wide entries are skipped. Re-run in an admin PowerShell.' }

Say '== services =='
foreach ($s in Get-CimInstance Win32_Service) {
  $txt = "$($s.Name) $($s.DisplayName) $($s.PathName)"
  if ($txt -notmatch $AI -or $txt -match $KEEP) { continue }
  if ($s.StartMode -eq 'Disabled' -and $s.State -ne 'Running') { continue }
  $state.services += [ordered]@{ name=$s.Name; start=$s.StartMode; delayed=[bool]$s.DelayedAutoStart; running=($s.State -eq 'Running') }
  Stop-Service -Name $s.Name -Force; Set-Service -Name $s.Name -StartupType Disabled
  Say "stopped+disabled service $($s.Name) [was $($s.StartMode)/$($s.State)]"
}
Save

Say '== scheduled tasks =='
foreach ($t in Get-ScheduledTask) {
  if ($t.State -eq 'Disabled') { continue }
  $acts = ($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' '
  $txt = "$($t.TaskPath)$($t.TaskName) $acts"
  if ($txt -notmatch $AI -or $txt -match $KEEP) { continue }
  Stop-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName
  if (Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName) {
    $state.tasks += [ordered]@{ path=$t.TaskPath; name=$t.TaskName }
    Say "disabled task $($t.TaskPath)$($t.TaskName)"
  } else { Say "!! could not disable task $($t.TaskPath)$($t.TaskName) (needs admin?)" }
}
Save

Say '== startup entries =='
$off = [byte[]](3,0,0,0,0,0,0,0,0,0,0,0)
$SA  = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
function Disable-Startup($hive, $sub, $name, $what) {
  $k = "${hive}:\$SA\$sub"
  if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
  $prev = (Get-ItemProperty -Path $k -Name $name).$name
  if ($prev -and $prev[0] -eq 3) { return }
  New-ItemProperty -Path $k -Name $name -PropertyType Binary -Value $off -Force | Out-Null
  if ((Get-ItemProperty -Path $k -Name $name).$name[0] -eq 3) {
    $state.approved += [ordered]@{ key=$k; name=$name; prev=$(if ($prev) { [int[]]$prev } else { $null }) }
    Say "startup off: $name  ($what)"
  } else { Say "!! could not disable startup $name ($k)" }
}
$runs = @(
  @('HKCU','Software\Microsoft\Windows\CurrentVersion\Run','Run'),
  @('HKLM','Software\Microsoft\Windows\CurrentVersion\Run','Run'),
  @('HKLM','Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run','Run32'))
foreach ($r in $runs) {
  $p = Get-ItemProperty -Path "$($r[0]):\$($r[1])"; if (-not $p) { continue }
  foreach ($prop in $p.PSObject.Properties) {
    if ($prop.Name -like 'PS*') { continue }
    $txt = "$($prop.Name) $($prop.Value)"
    if ($txt -match $AI -and $txt -notmatch $KEEP) { Disable-Startup $r[0] $r[2] $prop.Name "$($r[0]) Run: $($prop.Value)" }
  }
}
$wsh = New-Object -ComObject WScript.Shell
foreach ($sf in @(@('HKCU',[Environment]::GetFolderPath('Startup')), @('HKLM',[Environment]::GetFolderPath('CommonStartup')))) {
  foreach ($f in Get-ChildItem -Path $sf[1] -File) {
    $tgt = if ($f.Extension -eq '.lnk') { $wsh.CreateShortcut($f.FullName).TargetPath } else { '' }
    $txt = "$($f.Name) $tgt"
    if ($txt -match $AI -and $txt -notmatch $KEEP) { Disable-Startup $sf[0] 'StartupFolder' $f.Name "Startup folder: $tgt" }
  }
}
$AX = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
foreach ($pkg in Get-ChildItem -Path $AX) {
  if ($pkg.PSChildName -notmatch $AI) { continue }
  foreach ($tk in Get-ChildItem -Path $pkg.PSPath) {
    $v = (Get-ItemProperty -Path $tk.PSPath -Name State).State
    if ($null -eq $v -or $v -notin 2,5) { continue }
    Set-ItemProperty -Path $tk.PSPath -Name State -Value 1 -Type DWord
    $state.appx += [ordered]@{ key=$tk.PSPath; prev=$v }
    Say "store-app startup off: $($pkg.PSChildName)\$($tk.PSChildName)"
  }
}
$pk = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot'
$prevPol = (Get-ItemProperty -Path $pk -Name TurnOffWindowsCopilot).TurnOffWindowsCopilot
if ($prevPol -ne 1) {
  New-Item -Path $pk -Force | Out-Null
  New-ItemProperty -Path $pk -Name TurnOffWindowsCopilot -PropertyType DWord -Value 1 -Force | Out-Null
  $state.policy += [ordered]@{ key=$pk; name='TurnOffWindowsCopilot'; prev=$prevPol }
  Say 'policy: Windows Copilot turned off (HKCU)'
}
Save

Say '== processes =='
$all = Get-CimInstance Win32_Process
$self = @{}; $p = $PID
while ($p -and -not $self.ContainsKey([int]$p)) { $self[[int]$p] = 1; $p = ($all | Where-Object ProcessId -eq $p).ParentProcessId }
function Get-AIProcs {
  Get-CimInstance Win32_Process | Where-Object {
    $id = "$($_.Name) $($_.ExecutablePath)"
    (-not $self.ContainsKey([int]$_.ProcessId)) -and $id -notmatch $KEEP -and (
      ("$id $($_.CommandLine)" -match $AI) -or ($_.Name -eq 'ssh.exe' -and $_.CommandLine -match '9876'))
  }
}
for ($i = 0; $i -lt 3; $i++) {
  $procs = @(Get-AIProcs); if ($procs.Count -eq 0) { break }
  foreach ($x in $procs) { Stop-Process -Id $x.ProcessId -Force; Say "killed $($x.ProcessId) $($x.Name)  $($x.ExecutablePath)" }
  Start-Sleep -Seconds 2
}
Start-Sleep -Seconds 3
$left = @(Get-AIProcs)
foreach ($k in $self.Keys) { $q = $all | Where-Object ProcessId -eq $k; if ("$($q.Name) $($q.CommandLine)" -match $AI -and "$($q.Name)" -notmatch $KEEP) { Say "!! this PowerShell runs under $($q.Name) ($k): close that app yourself" } }
Save
Say ''
Say 'Not scriptable: Notion AI inside the browser (just do not open it). Claude Code trigger trig_01BcBEwXanY1VvZmErhAFcbb: pause it at claude.ai/code.'
Say "state: $ST   undo: powershell -ExecutionPolicy Bypass -File $D\ai-on.ps1"
foreach ($x in $left) { Say "left: $($x.ProcessId) $($x.Name) $($x.ExecutablePath)" }
Say "CHECK: AI processes left: $($left.Count)"
