# Registers a one-shot Windows Scheduled Task whose action is already routed through
# run-hidden.vbs -- for bash callers that need to create a task dynamically (currently
# only hooks/statusline.sh's schedule_resume()). <harnessEpicKey>.
#
# Exists specifically to replace hand-built `schtasks.exe /create ... /tr "bash
# \"$HOME/...\""` string construction in bash, which is exactly the nested-double-quote
# shape AGENTS.md documents as having collapsed a different task's Execute value down
# to exit 127 (bash eats the backslashes when a quoted Execute string is itself
# re-quoted). Every value here arrives as its own separate process argument -- built
# once, entirely inside PowerShell -- so there is no bash-side quote nesting at all.
#
# Deliberately narrow: one-shot only (no recurring-trigger support), because the only
# caller needs exactly that. Does not touch, and is not a fix for, the separately-known
# schtasks.exe /query bug (MSYS mangles single-slash flags) -- the caller's own dedup
# check stays exactly as it is; this script only replaces how the ACTION gets built once
# the caller has already decided to create the task.
param(
  [Parameter(Mandatory = $true)]
  [string]$TaskName,

  # Anything [datetime]::Parse can read, e.g. "2026/08/22 03:15".
  [Parameter(Mandatory = $true)]
  [string]$At,

  # The bash command line to run hidden, e.g. "bash /c/Users/.../resume-rate-limited.sh".
  # Must not contain a literal double-quote character (see run-hidden.vbs's own header)
  # -- none of this harness's real commands ever need one.
  [Parameter(Mandatory = $true)]
  [string]$Command,

  # Wake a sleeping machine at $At instead of waiting for it to be touched. Off by
  # default -- this script's only caller (schedule_resume()) fires within minutes, when
  # the machine is almost always already awake; a monitor/notes task waking the PC is a
  # deliberate per-task choice, not this script's default.
  [switch]$WakeToRun
)

$runHiddenVbs = Join-Path $PSScriptRoot 'run-hidden.vbs'
$atTime = [datetime]::Parse($At)

# Execute=wscript.exe, not powershell.exe -- confirmed live that `powershell.exe
# -WindowStyle Hidden` alone still flashes a console for one frame (it's a
# console-subsystem exe; the flag only hides the window AFTER the OS already created
# it). wscript.exe is GUI-subsystem and never allocates a console, so there is nothing
# to flash. See run-hidden.vbs's header for the full mechanism.
$action = New-ScheduledTaskAction -Execute 'wscript.exe' `
  -Argument "`"$runHiddenVbs`" `"$Command`""
$trigger = New-ScheduledTaskTrigger -Once -At $atTime
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

# <harnessEpicKey>: Register-ScheduledTask with NO -Settings reverts to Windows defaults
# -- DisallowStartIfOnBatteries=True, StartWhenAvailable=False among them. That is
# exactly the silently-skipped-fire shape that caused a missed 2026-08-25 09:30 run
# (confirmed live). Every task this script creates gets the same anti-skip set the
# hand-registered Ping tasks carry, not whatever Windows defaults to.
$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
  -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 15) `
  -ExecutionTimeLimit (New-TimeSpan -Hours 72) -MultipleInstances IgnoreNew
$settings.WakeToRun = [bool]$WakeToRun

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
