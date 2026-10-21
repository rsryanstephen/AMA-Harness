# PROJ-15653: registers (or re-registers) AMA-Harness-Env-Wake -- runs
# morning-wake.sh hidden via run-hidden.vbs. Idempotent; safe to re-run after moving the repo.
#
# Triggers: daily 07:00 local (this PC is on SAST) repeating every 30 min for 15h, at
# logon, and on resume from sleep (System log: Power-Troubleshooter 1 = Modern Standby/S3
# resume, Kernel-Power 107 = S3 resume). Resume is not a logon, and StartWhenAvailable's
# catch-up lagged: asleep through 07:00 on 2026-10-13, nothing ran until the next repeat.
# morning-wake.sh acts once per weekday inside 07:00-22:00, so extra fires are cheap no-ops.
# WakeToRun stays False: waking a sleeping PC to start envs nobody is at the desk to use
# defeats the point.
$ErrorActionPreference = 'Stop'
$taskName = 'AMA-Harness-Env-Wake'
$repo   = (git -C "$HOME/.claude/hooks" rev-parse --show-toplevel)
$vbs    = Join-Path $repo 'scripts/run-hidden.vbs'
$script = (Join-Path $PSScriptRoot 'morning-wake.sh') -replace '\\', '/'
foreach ($f in $vbs, $script) { if (-not (Test-Path $f)) { throw "missing: $f" } }
if ((Get-TimeZone).BaseUtcOffset -ne [TimeSpan]::FromHours(2)) {
  Write-Warning "PC timezone is not UTC+2 -- the 07:00 trigger fires at local 07:00, not SAST. morning-wake.sh still decides in SAST."
}

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`" `"bash '$script'`""

$daily = New-ScheduledTaskTrigger -Daily -At '07:00'
$rep   = New-ScheduledTaskTrigger -Once -At '07:00' `
  -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration (New-TimeSpan -Hours 15)
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
  -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -MultipleInstances IgnoreNew
$settings.WakeToRun = $false

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $daily, $logon, $resume `
  -Principal $principal -Settings $settings -Force | Out-Null

$t = Get-ScheduledTask -TaskName $taskName
"{0}: {1}; next run {2}" -f $t.TaskName, $t.State, ($t | Get-ScheduledTaskInfo).NextRunTime
"Arguments: " + $t.Actions[0].Arguments
