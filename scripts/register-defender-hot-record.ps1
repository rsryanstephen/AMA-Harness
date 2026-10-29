# Registers AMA-Harness-Defender-Hot-Record: an ON-DEMAND, ELEVATED scheduled task that runs a
# 120 s Defender performance recording during a slow spell (scripts/defender-hot-record.ps1).
# <harnessEpicKey>, 2026-10-15. Run ONCE from an elevated PowerShell (Run as administrator):
#
#   powershell -ExecutionPolicy Bypass -File "<repo>\scripts\register-defender-hot-record.ps1" [-MaxRecordings 3]
#   ... -Unregister        # remove the task and the admin-only copies (recordings are kept)
#
# Why a task: New-MpPerformanceRecording needs admin, hooks never have it, and a RunLevel
# Highest task can be started by a limited process (`schtasks /run`) without a UAC prompt.
# No trigger -- hooks/defender-hot-trigger.sh and scripts/console-window-watch.ps1 start it.
#
# An elevated task whose action points at a USER-WRITABLE file is a privilege-escalation
# primitive (any process running as the user edits the file, starts the task, runs as
# administrator) -- so nothing the task executes or reads is user-writable:
#  1. the script and the hidden-launch wrapper are COPIED to %ProgramData%\AMA-Harness\bin with
#     an explicit ACL (SYSTEM/Administrators full, Users read; verified below, registration
#     refuses otherwise). Not Program Files: its space needs quotes in the inner command line,
#     and embedded quotes do not survive the wscript hop -- PowerShell received `-File
#     C:\Program` and exited 0xFFFD0000 (file not found) on the task's first run (2026-10-15);
#     every path in that line must be space-free (asserted below);
#  2. outputs go to %ProgramData%\AMA-Harness\defender-hot with an explicit ACL
#     (SYSTEM/Administrators full, Users read -- ProgramData's default lets Users create files);
#  3. the task is registered through the Schedule.Service COM API with an explicit security
#     descriptor: owner Administrators, SYSTEM/Administrators full, Users read+execute. A
#     non-elevated process -- this user's own included -- can START it but not change what it
#     runs (the owner would otherwise hold WRITE_DAC implicitly); verify from a non-elevated
#     shell: `schtasks /change /tn AMA-Harness-Defender-Hot-Record /tr x` must say Access is denied;
#  4. every executable is an absolute System32 path; the script resets PATH/PSModulePath itself.
# Action routed through run-hidden-generic.vbs like every AMA-Harness-* task
# (check-scheduled-tasks.ps1 flags anything else); Interactive logon so it runs in the user's
# session, where the spell is felt; never-run (0x41303) with no cadence reads as healthy there.
# The script retires the task after -MaxRecordings runs: re-run this to continue (it also
# refreshes the copies after a repo change -- a repo edit alone changes nothing the task runs).
param([switch]$Unregister, [int]$MaxRecordings = 3)
$ErrorActionPreference = 'Stop'
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Error 'Run this from an ELEVATED PowerShell (Run as administrator): registering a RunLevel Highest task needs it.'
  exit 1
}
$task = 'AMA-Harness-Defender-Hot-Record'
$sys = Join-Path $env:windir 'System32'
$bin = Join-Path $env:ProgramData 'AMA-Harness\bin'
$out = Join-Path $env:ProgramData 'AMA-Harness\defender-hot'
$legacy = Join-Path $env:ProgramFiles 'AMA-Harness'   # the first registration's location, see point 1
$svc = New-Object -ComObject 'Schedule.Service'; $svc.Connect(); $root = $svc.GetFolder('\')

if ($Unregister) {
  try { $root.DeleteTask($task, 0) } catch {}
  Remove-Item -LiteralPath $bin -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $legacy -Recurse -Force -ErrorAction SilentlyContinue
  "removed task $task and $bin ($out and its recordings kept)"
  exit 0
}
if ("$sys$bin$out" -match ' ') { Write-Error "a path with a space cannot cross the wscript hop unquoted: $sys / $bin / $out"; exit 1 }

$repo = Split-Path -Parent $PSScriptRoot
$src = @((Join-Path $repo 'scripts\defender-hot-record.ps1'), (Join-Path $repo 'scripts\run-hidden-generic.vbs'))
foreach ($f in $src) { if (-not (Test-Path -LiteralPath $f)) { Write-Error "missing $f"; exit 1 } }

# 1 + 2. admin-only copies of the two files the task executes, and the output dir -- both with
# inheritance off, SYSTEM + Administrators full, Users read (ProgramData's default lets Users
# create files, so the explicit ACL is what makes them admin-only).
foreach ($d in @($bin, $out)) {
  New-Item -ItemType Directory -Force -Path $d | Out-Null
  & "$sys\icacls.exe" $d /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' 'Users:(OI)(CI)RX' | Out-Null
}
foreach ($f in $src) { Copy-Item -LiteralPath $f -Destination $bin -Force }
Remove-Item -LiteralPath $legacy -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $out 'count.txt') -ErrorAction SilentlyContinue
# 3. refuse if any non-admin principal can write either directory
function Assert-AdminOnly([string]$dir) {
  # Write-class bits ONLY: WriteData/CreateFiles, AppendData/CreateDirectories, WriteEA,
  # DeleteSubdirectoriesAndFiles, WriteAttributes, Delete, ChangePermissions, TakeOwnership.
  # Not the enum's Write/Modify/FullControl -- those include the read bits, so a plain
  # ReadAndExecute ACE matched and the first registration attempt refused Program Files.
  $writeMask = 0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000
  $generic = 0x40000000 -bor 0x10000000   # GENERIC_WRITE | GENERIC_ALL, as inherit-only ACEs carry them
  $bad = @((Get-Acl -LiteralPath $dir).Access | Where-Object {
    $_.AccessControlType -eq 'Allow' -and
    $_.IdentityReference.Value -notmatch '^(NT AUTHORITY\\SYSTEM|BUILTIN\\Administrators|NT SERVICE\\TrustedInstaller|CREATOR OWNER)$' -and
    ((([int]$_.FileSystemRights) -band $writeMask) -ne 0 -or (([int]$_.FileSystemRights) -band $generic) -ne 0)
  })
  if ($bad.Count -gt 0) {
    $bad | ForEach-Object { Write-Error ('{0} can write {1} ({2}) -- not registering an elevated task over a user-writable path' -f $_.IdentityReference, $dir, $_.FileSystemRights) }
    exit 1
  }
}
Assert-AdminOnly $bin
Assert-AdminOnly $out

# 4. the task, with an explicit security descriptor (see header, point 3)
$def = $svc.NewTask(0)
$def.RegistrationInfo.Description = 'AMA harness: 120 s Defender performance recording during a slow spell, started on demand by the harness. Code in an admin-only folder, outputs admin-owned; see PORTABILITY.md.'
$def.Principal.UserId = "$env:USERDOMAIN\$env:USERNAME"
$def.Principal.LogonType = 3      # TASK_LOGON_INTERACTIVE_TOKEN
$def.Principal.RunLevel = 1       # TASK_RUNLEVEL_HIGHEST
$s = $def.Settings
$s.DisallowStartIfOnBatteries = $false; $s.StopIfGoingOnBatteries = $false; $s.StartWhenAvailable = $true
$s.MultipleInstances = 2          # TASK_INSTANCES_IGNORE_NEW
$s.ExecutionTimeLimit = 'PT15M'; $s.AllowDemandStart = $true; $s.Enabled = $true
$a = $def.Actions.Create(0)       # TASK_ACTION_EXEC
$a.Path = "$sys\wscript.exe"
# No quotes inside the inner command line (point 1): every path in it is space-free.
$a.Arguments = "`"$bin\run-hidden-generic.vbs`" `"$sys\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File $bin\defender-hot-record.ps1 -OutDir $out -MaxRecordings $MaxRecordings`""
$sddl = 'O:BAG:SYD:(A;;FA;;;SY)(A;;FA;;;BA)(A;;FRFX;;;BU)'
$root.RegisterTaskDefinition($task, $def, 6, $null, $null, 3, $sddl) | Out-Null   # 6 = create or update

$t = $root.GetTask($task)
'registered {0}: RunLevel=Highest LogonType=Interactive State={1}' -f $task, $t.State
'security descriptor: ' + $t.GetSecurityDescriptor(7)
'runs: ' + $a.Path + ' ' + $a.Arguments
'retires itself after {0} recording(s); recordings + log: {1}' -f $MaxRecordings, $out
'verify from a NON-elevated shell: `schtasks /change /tn {0} /tr x` must say Access is denied; `schtasks /run /tn {0}` starts a recording (log line after ~2.5 min).' -f $task
