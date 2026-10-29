# Launches fleet-health-check.sh with no visible console window -- PROJ-15113.
# Confirmed real incident: the scheduled task's default (Interactive logon type) opens
# a visible console in the user's desktop session; the user closed it twice during
# testing, not realizing it was this task, which kills the process mid-run
# (STATUS_CONTROL_C_EXIT). A nightly unattended run has nobody around to do that, but
# hiding the window removes the failure mode entirely instead of relying on that.
#
# This script's OWN internals were always hidden correctly (every child Process.Start
# below already sets CreateNoWindow). The scheduled task's OUTER layer used to launch
# THIS script via `powershell.exe -WindowStyle Hidden -File ...` directly -- that still
# flashed a console for one frame at process creation (confirmed live, <harnessEpicKey>,
# same root cause documented in scripts/run-hidden.vbs's header), most visibly when
# `StartWhenAvailable` caught up a missed 01:47 run while the user was at their desk.
# As of <harnessEpicKey> the task launches this script through
# `scripts/run-hidden-generic.vbs` instead (wscript.exe, GUI-subsystem, no console at
# all) -- this file's own contents are unchanged, only how Task Scheduler reaches it.
# Derive paths from $env:USERPROFILE (always set on Windows) instead of a hardcoded
# username -- portable across whoever's account this scheduled task runs under.
$driveLetter = $env:USERPROFILE.Substring(0, 1).ToLower()
$restOfPath = ($env:USERPROFILE.Substring(2)) -replace '\\', '/'
$posixHome = "/$driveLetter$restOfPath"
$scriptPath = "$posixHome/.claude/skills/ama-library-version-sync/scripts/fleet-health-check.sh"
$libLine = ". '$posixHome/.claude/hooks/lib-harness-repos.sh'; hr_roots app"

# Repos root is no longer a hardcoded literal (PROJ-15143) -- ask the resolver,
# which honors .harness-local.json/derived-location same as every other caller. Loop
# once per resolved app-fleet root rather than assuming exactly one.
$rootsPsi = New-Object System.Diagnostics.ProcessStartInfo
$rootsPsi.FileName = 'C:\Program Files\Git\bin\bash.exe'
$rootsPsi.Arguments = "--login -c ""$libLine"""
$rootsPsi.CreateNoWindow = $true
$rootsPsi.UseShellExecute = $false
$rootsPsi.RedirectStandardOutput = $true
$rootsProc = [System.Diagnostics.Process]::Start($rootsPsi)
$reposRoots = $rootsProc.StandardOutput.ReadToEnd() -split "`n" | Where-Object { $_.Trim() -ne '' }
$rootsProc.WaitForExit()

# PROJ-15342: fleet-health/ moved under harness-state/logs/ -- no bash lib
# available here to mkdir it (this runs standalone via wscript, not through
# hooks/lib-claude-paths.sh), so create the parent explicitly before first use.
$fleetHealthDir = Join-Path $env:USERPROFILE '.claude\harness-state\logs\fleet-health'
if (-not (Test-Path -LiteralPath $fleetHealthDir)) { New-Item -ItemType Directory -Path $fleetHealthDir -Force | Out-Null }
$logPath = Join-Path $fleetHealthDir 'schtask-debug.log'
$allOutput = @()

foreach ($reposRoot in $reposRoots) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'C:\Program Files\Git\bin\bash.exe'
  $psi.Arguments = "--login -c ""bash '$scriptPath' '$($reposRoot.Trim())'"""
  $psi.CreateNoWindow = $true
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  # Redirecting BOTH streams and reading them sequentially with ReadToEnd() deadlocks if
  # one pipe's OS buffer fills while the code is blocked reading the other -- confirmed
  # LIVE, <harnessEpicKey>: a run hung for 8+ minutes at ~0 CPU (classic blocked-on-I/O
  # symptom, not slowness), and MultipleInstances=IgnoreNew meant it silently swallowed
  # every later scheduled/forced run underneath it. Fix: read both streams
  # asynchronously via events (the standard .NET pattern for this exact trap), so
  # neither pipe can back up while the other is being drained.
  $stdoutBuf = New-Object System.Text.StringBuilder
  $stderrBuf = New-Object System.Text.StringBuilder
  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action {
    if ($null -ne $EventArgs.Data) { [void]$Event.MessageData.AppendLine($EventArgs.Data) }
  } -MessageData $stdoutBuf | Out-Null
  Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action {
    if ($null -ne $EventArgs.Data) { [void]$Event.MessageData.AppendLine($EventArgs.Data) }
  } -MessageData $stderrBuf | Out-Null
  [void]$proc.Start()
  $proc.BeginOutputReadLine()
  $proc.BeginErrorReadLine()
  $proc.WaitForExit()
  $stdout = $stdoutBuf.ToString()
  $stderr = $stderrBuf.ToString()
  Get-EventSubscriber | Where-Object { $_.SourceObject -eq $proc } | Unregister-Event
  $allOutput += "root=$reposRoot exit=$($proc.ExitCode)`n$stdout`n$stderr"
}

"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n$($allOutput -join "`n---`n")" | Set-Content -Path $logPath
