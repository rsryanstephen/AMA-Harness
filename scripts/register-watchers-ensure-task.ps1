# <harnessEpicKey>: registers (or re-registers) AMA-Harness-Watchers-Ensure -- runs
# hooks/pr-watch-check.sh hidden via run-hidden.vbs. Idempotent; safe to re-run after moving the repo.
#
# pr-watch-check.sh is the one restart pass for every durable watcher the harness keeps: PR
# merge/review watchers, feedback Production watchers, the reply checker, and every monitor
# registered with scripts/durable-monitor.sh. On-prompt it runs only when a session gets a
# prompt; after a crash, restart or sign-out with no session open nothing ran it, so a
# ticket-status watcher or a log monitor stayed dead until someone typed something (user rule
# 2026-10-22: reminders and monitors must survive a reboot, all handled the same way).
#
# Triggers: at logon, on resume from sleep (same event subscription as AMA-Harness-Env-Wake),
# and every 30 min. The pass is idempotent and cheap (two file reads per marker, forks only to
# restart), so extra fires cost nothing. WakeToRun False: a sleeping PC has nothing to watch.
$ErrorActionPreference = 'Stop'
$taskName = 'AMA-Harness-Watchers-Ensure'
$repo   = (git -C "$HOME/.claude/hooks" rev-parse --show-toplevel)
$vbs    = Join-Path $repo 'scripts/run-hidden.vbs'
$script = (Join-Path $repo 'hooks/pr-watch-check.sh') -replace '\\', '/'
foreach ($f in $vbs, $script) { if (-not (Test-Path $f)) { throw "missing: $f" } }

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`" `"bash '$script'`""

$daily = New-ScheduledTaskTrigger -Daily -At '00:05'
$rep   = New-ScheduledTaskTrigger -Once -At '00:05' `
  -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration (New-TimeSpan -Hours 23 -Minutes 50)
$daily.Repetition = $rep.Repetition
$logon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$resume = New-CimInstance -ClientOnly -CimClass (Get-CimClass -ClassName MSFT_TaskEventTrigger `
  -Namespace Root/Microsoft/Windows/TaskScheduler)
$resume.Enabled = $true
$resume.Subscription = '<QueryList><Query Id="0" Path="System">' +
  "<Select Path=`"System`">*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select>" +
  "<Select Path=`"System`">*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=107]]</Select>" +
  '</Query></QueryList>'

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
$settings.WakeToRun = $false

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $daily, $logon, $resume `
  -Principal $principal -Settings $settings -Force | Out-Null

$t = Get-ScheduledTask -TaskName $taskName
"{0}: {1}; next run {2}" -f $t.TaskName, $t.State, ($t | Get-ScheduledTaskInfo).NextRunTime
"Arguments: " + $t.Actions[0].Arguments
