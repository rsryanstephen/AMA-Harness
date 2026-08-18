# Launches fleet-health-check.sh with no visible console window -- PROJ-15113.
# Confirmed real incident: the scheduled task's default (Interactive logon type) opens
# a visible console in the user's desktop session; the user closed it twice during
# testing, not realizing it was this task, which kills the process mid-run
# (STATUS_CONTROL_C_EXIT). A nightly unattended run has nobody around to do that, but
# hiding the window removes the failure mode entirely instead of relying on that.
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

$logPath = Join-Path $env:USERPROFILE '.claude\fleet-health\schtask-debug.log'
$allOutput = @()

foreach ($reposRoot in $reposRoots) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'C:\Program Files\Git\bin\bash.exe'
  $psi.Arguments = "--login -c ""bash '$scriptPath' '$($reposRoot.Trim())'"""
  $psi.CreateNoWindow = $true
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()
  $allOutput += "root=$reposRoot exit=$($proc.ExitCode)`n$stdout`n$stderr"
}

"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n$($allOutput -join "`n---`n")" | Set-Content -Path $logPath
