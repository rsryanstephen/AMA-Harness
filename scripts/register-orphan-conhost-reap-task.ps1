# Registers (or re-registers) AMA-Harness-Orphan-Conhost-Reap: runs
# scripts/reap-orphan-conhost.ps1 every 15 minutes (hourly until 2026-10-12, when it also
# began reaping orphaned dev servers and Playwright browsers), hidden via run-hidden-generic.vbs.
# <harnessEpicKey>. Idempotent -- safe to re-run after moving the repo.
#
# Same shape as the other AMA-Harness-* monitors: wscript.exe Execute (GUI subsystem,
# never allocates a console -- `powershell -WindowStyle Hidden` alone still flashes),
# Limited interactive principal, and the three anti-skip settings AGENTS.md lists
# (DisallowStartIfOnBatteries/StopIfGoingOnBatteries off, StartWhenAvailable on).
# WakeToRun stays False: a detection/cleanup monitor must never wake the machine.
$ErrorActionPreference = 'Stop'
$taskName = 'AMA-Harness-Orphan-Conhost-Reap'
$vbs      = Join-Path $PSScriptRoot 'run-hidden-generic.vbs'
$ps1      = Join-Path $PSScriptRoot 'reap-orphan-conhost.ps1'
foreach ($f in $vbs, $ps1) { if (-not (Test-Path $f)) { throw "missing: $f" } }

# The inner path needs DOUBLED quotes in the STORED Arguments value (""..."") -- it sits
# inside the outer quoted argument to run-hidden-generic.vbs, and a single embedded quote
# ends that argument early (AGENTS.md: stored `\"` = exit-127 launch failure). Four quotes
# in PowerShell source -> two literal quotes stored. Verify with (Get-ScheduledTask).Actions.
$inner  = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """"$ps1"""""
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`" `"$inner`""

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
  -RepetitionInterval (New-TimeSpan -Minutes 15)

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
$settings.WakeToRun = $false

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
  -Principal $principal -Settings $settings -Force | Out-Null

$t = Get-ScheduledTask -TaskName $taskName
"{0}: {1}; next run {2}" -f $t.TaskName, $t.State, ($t | Get-ScheduledTaskInfo).NextRunTime
