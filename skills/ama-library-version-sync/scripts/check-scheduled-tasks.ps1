# Liveness check for every AMA-Harness-* Windows Scheduled Task. Run nightly by
# fleet-health-check.sh's run_check helper (<harnessEpicKey>).
#
# WHY THIS EXISTS. On 2026-09-01 AMA-Harness-VPN-DNS-Probe was found to have never once done
# its job: registered, State=Ready, plausible NextRunTime, and LastTaskResult 0xFFFD0000 on
# every 10-minute tick while doing nothing. AMA-Harness-CheckGates-Reminder had the same bug.
# Cause: the stored Arguments escaped the inner script path as \" -- a bash/C escape -- where
# Windows argv quoting needs a doubled "". wscript got a mangled argument list, the VBS
# wrapper never received a usable command, and the task exited having done nothing.
#
# Nothing anywhere checked for this. A successful registration, State=Ready and a future
# NextRunTime are ALL equally true of a task that has never functioned, and a dead probe is
# indistinguishable from a quiet network -- which is exactly how it survived from
# PROJ-15367, the ticket that shipped that probe as a detector.
#
# OUTPUT CONTRACT (run_check diffs this against the previous run, and fleet-health-check.sh
# pings only on newly-added ^RISK|^FAIL lines):
#   - one line per task, STATUS TOKEN FIRST, no leading whitespace -- the ping grep is
#     '^> *(RISK|FAIL)', so a status token anywhere but first is silently never reported.
#   - NO VOLATILE VALUES. No timestamps, no ages, no raw hour counts. An unchanged fleet must
#     produce a byte-identical file, or every night diffs and results.log fills with churn.
#     Staleness is therefore emitted as a coarse bucket ("overdue>3x"), never a number.
#
# A DELETED task needs no special handling: its line simply vanishes from the snapshot and
# shows up as a `<` delta in results.log. It won't ping (ping is `>`-only). That is accepted
# deliberately rather than adding inventory machinery -- there is no machine-readable list of
# expected tasks anywhere in the repo, only prose in PORTABILITY.md, and hardcoding one here
# would just drift.
#
# -SelfTest: run the classifier against synthetic cases and print PASS/FAIL. Writes nothing,
# touches no live task. This exists because the two failure modes worth most (a malformed
# stored argument, and a launch-failure result class) cannot be exercised against the live
# fleet without deliberately breaking a real task.
param([switch]$SelfTest)

$ErrorActionPreference = 'Continue'

# Floor of the launch-failure range (0xF0000000), typed explicitly and NOT written as a bare
# hex literal. PowerShell parses a hex literal into the smallest signed type it fits, so a
# bare `0xF0000000` becomes Int32 -268435456 -- which makes `1 -ge 0xF0000000` TRUE and
# misfiles every ordinary exit code as a launch failure. Caught in test: both exit-1 tasks
# came back "launch-failed result=0x00000001".
[uint32]$LaunchFailFloor = 4026531840   # 0xF0000000

# Scheduler status codes that are NOT failures -- these describe the task's state, not a run
# result. 0x41303 in particular ("has never run") is the correct, healthy reading for a task
# registered today whose first fire is tomorrow.
# Keys are cast to [uint32] so the lookup can use the normalised code directly. With bare
# hex literals the keys are Int32, forcing a `$rc` at the call site -- which THROWS on
# any code above Int32.MaxValue, i.e. on exactly the 0xFFFD0000 launch failures this script
# exists to catch. Caught by -SelfTest's launch-* cases.
$SchedulerStates = @{
  [uint32]0x00041300 = 'ready-not-yet-run'
  [uint32]0x00041301 = 'currently-running'
  [uint32]0x00041302 = 'disabled'
  [uint32]0x00041303 = 'never-run-yet'
  [uint32]0x00041304 = 'no-more-runs'
  [uint32]0x00041306 = 'terminated'
  [uint32]0x00041325 = 'queued'
  [uint32]0x00041326 = 'disabled-by-trigger'
}

function Get-TaskFindings {
  # The whole classifier, kept free of Get-ScheduledTask so -SelfTest can drive it. Returns
  # the finished output lines for one task.
  param(
    [string]$Name,
    [string]$Execute,
    [string]$Arguments,
    $ResultCode,                 # $null when task info is unreadable
    $LastRun,                    # datetime or $null -- deliberately UNTYPED, see below
    $Cadence,                    # timespan or $null -- ditto
    $ManualOk                    # datetime or $null: mtime of notices/.task-ok-<Name>, stamped by a
                                 # runner on a SUCCESSFUL forced/manual run. A manual run never
                                 # updates LastTaskResult, so without this a fixed weekly task
                                 # stays RISK for six days (2026-09-02).
  )
  # $LastRun/$Cadence are untyped on purpose. Declared as [Nullable[datetime]] /
  # [Nullable[timespan]] they silently arrive $null when splatted, so the staleness check
  # never fired and a stale task reported OK. Caught by -SelfTest's stale-subdaily case.
  $out = New-Object System.Collections.Generic.List[string]

  # --- 1. Stored-argument syntax -------------------------------------------------------
  # The exact 2026-09-01 bug, caught at rest. This is deliberately checked HERE and not in
  # scheduled-task-hidden-gate.sh: at registration time a `\"` in the command text may be
  # legitimate bash escaping for a literal quote, so a gate-side reject would false-positive.
  # By the time it is STORED, escaping has resolved and a backslash-quote is unambiguously
  # wrong -- Windows wants a doubled "" inside a quoted argument.
  if ($Arguments -like '*\"*') { $out.Add("FAIL $Name args-malformed-backslash-quote") }

  # --- 2. Hidden-launch wrapper, verified at rest --------------------------------------
  # scheduled-task-hidden-gate.sh enforces this at registration but documents its own limit:
  # an action built across two separate tool calls is invisible to it. Checking the stored
  # action closes that hole. A direct bash.exe/powershell.exe Execute pops a focus-stealing
  # console (<harnessEpicKey>).
  if ($Execute -and $Execute -notmatch 'wscript(\.exe)?$' -and $Arguments -notmatch 'run-hidden(-generic)?\.vbs') {
    $out.Add("RISK $Name not-routed-through-hidden-wrapper")
  }

  # --- 3. Result-code class ------------------------------------------------------------
  $stateNote = 'result=0'
  if ($null -eq $ResultCode) {
    $out.Add("RISK $Name task-info-unreadable")
  } else {
    # Normalise to unsigned. LastTaskResult reaches us as EITHER representation of the same
    # 32-bit code depending on the source -- Get-ScheduledTaskInfo gave 4294770688 for the
    # code `cmd` reported as -196608 -- and a bare [uint32] cast THROWS on the negative form.
    $raw = [int64]$ResultCode
    if ($raw -lt 0) { $raw += 4294967296 }
    $rc = [uint32]$raw
    if ($rc -eq 0) {
      # healthy
    } elseif ($SchedulerStates.ContainsKey($rc)) {
      $stateNote = $SchedulerStates[$rc]
    } elseif ($rc -ge $LaunchFailFloor -or $rc -eq 127) {
      # The launch itself failed: wscript/WSH could not run the payload at all. THIS is the
      # class that was invisible for weeks -- the payload never ran, so it logged nothing.
      $out.Add(("FAIL $Name launch-failed result=0x{0:X8}" -f $rc))
    } else {
      # The payload ran and exited non-zero. Both unattended-ping scripts use exit 0 for
      # every benign "nothing to do" path and exit 1 only for real failures, so this is a
      # genuine finding -- but a lower grade, because it means the plumbing works.
      if ($null -ne $ManualOk -and $null -ne $LastRun -and $ManualOk -gt $LastRun) {
        $stateNote = 'manual-run-cleared'
      } else {
        $out.Add(("RISK $Name script-exit={0}" -f $rc))
      }
    }

    # --- 4. Staleness -----------------------------------------------------------------
    # Bucketed, never numeric -- see the OUTPUT CONTRACT note above. Skipped for a task that
    # has never run: "never run" is check 3's business, and there is no age to measure.
    if ($null -ne $Cadence -and $null -ne $LastRun -and $LastRun.Year -gt 2000) {
      $age = (Get-Date) - $LastRun
      # Sub-daily tasks get a looser multiple: a laptop that slept through two ticks is
      # normal, three consecutive misses is not.
      $mult = if ($Cadence.TotalHours -lt 24) { 3 } else { 2 }
      if ($age.TotalSeconds -gt ($Cadence.TotalSeconds * $mult)) {
        $out.Add("FAIL $Name stale overdue>${mult}x-cadence")
      }
    }
  }

  if ($out.Count -eq 0) { $out.Add("OK $Name $stateNote") }
  return $out
}

function Get-Cadence {
  # Returns the task's expected period as a TimeSpan, or $null if it can't be determined.
  param($Task)
  foreach ($t in $Task.Triggers) {
    if ($t.Repetition -and $t.Repetition.Interval) {
      try { return [System.Xml.XmlConvert]::ToTimeSpan($t.Repetition.Interval) } catch {}
    }
  }
  foreach ($t in $Task.Triggers) {
    switch -Wildcard ($t.CimClass.CimClassName) {
      '*DailyTrigger'  { $d = if ($t.DaysInterval)  { $t.DaysInterval }  else { 1 }; return (New-TimeSpan -Days $d) }
      '*WeeklyTrigger' { $w = if ($t.WeeksInterval) { $t.WeeksInterval } else { 1 }; return (New-TimeSpan -Days (7 * $w)) }
    }
  }
  return $null
}

if ($SelfTest) {
  $now = Get-Date
  $cases = @(
    @{ n='healthy';        want='OK T result=0';
       a=@{ Name='T'; Execute='wscript.exe'; Arguments='"x\run-hidden.vbs" "cmd"'; ResultCode=0; LastRun=$now; Cadence=(New-TimeSpan -Minutes 10) } }
    @{ n='never-run-yet';  want='OK T never-run-yet';
       a=@{ Name='T'; Execute='wscript.exe'; Arguments='"x\run-hidden.vbs" "cmd"'; ResultCode=0x00041303; LastRun=$null; Cadence=(New-TimeSpan -Days 1) } }
    # The 2026-09-01 bug itself.
    @{ n='malformed-args'; want='FAIL T args-malformed-backslash-quote';
       a=@{ Name='T'; Execute='wscript.exe'; Arguments='"x\run-hidden-generic.vbs" "powershell.exe -File \"C:\p.ps1\""'; ResultCode=0; LastRun=$now; Cadence=$null } }
    # The invisible class: payload never ran. Both representations of the SAME code are
    # tested -- `0xFFFD0000` written as a bare hex literal is Int32 -196608 (the same
    # signedness trap as $LaunchFailFloor), and Get-ScheduledTaskInfo hands back the
    # unsigned 4294770688. A bare [uint32] cast throws on the first.
    @{ n='launch-signed';   want='FAIL T launch-failed result=0xFFFD0000';
       a=@{ Name='T'; Execute='wscript.exe'; Arguments='"x\run-hidden.vbs" "cmd"'; ResultCode=0xFFFD0000; LastRun=$now; Cadence=$null } }
    @{ n='launch-unsigned'; want='FAIL T launch-failed result=0xFFFD0000';
       a=@{ Name='T'; Execute='wscript.exe'; Arguments='"x\run-hidden.vbs" "cmd"'; ResultCode=4294770688; LastRun=$now; Cadence=$null } }
    @{ n='exit-127';       want='FAIL T launch-failed result=0x0000007F';
       a=@{ Name='T'; Execute='wscript.exe'; Arguments='"x\run-hidden.vbs" "cmd"'; ResultCode=127; LastRun=$now; Cadence=$null } }
    # An ordinary non-zero exit must NOT be mistaken for a launch failure -- the signedness
    # trap above made exactly this mistake.
    @{ n='script-exit-1';  want='RISK T script-exit=1';
       a=@{ Name='T'; Execute='wscript.exe'; Arguments='"x\run-hidden.vbs" "cmd"'; ResultCode=1; LastRun=$now; Cadence=$null } }
    # A later successful manual run clears the stale exit code; an OLDER stamp does not.
    @{ n='manual-cleared'; want='OK T manual-run-cleared';
       a=@{ Name='T'; Execute='wscript.exe'; Arguments='"x\run-hidden.vbs" "cmd"'; ResultCode=1; LastRun=$now.AddHours(-2); Cadence=$null; ManualOk=$now } }
    @{ n='manual-stale';   want='RISK T script-exit=1';
       a=@{ Name='T'; Execute='wscript.exe'; Arguments='"x\run-hidden.vbs" "cmd"'; ResultCode=1; LastRun=$now; Cadence=$null; ManualOk=$now.AddDays(-3) } }
    @{ n='stale-subdaily'; want='FAIL T stale overdue>3x-cadence';
       a=@{ Name='T'; Execute='wscript.exe'; Arguments='"x\run-hidden.vbs" "cmd"'; ResultCode=0; LastRun=$now.AddHours(-1); Cadence=(New-TimeSpan -Minutes 10) } }
    @{ n='fresh-subdaily'; want='OK T result=0';
       a=@{ Name='T'; Execute='wscript.exe'; Arguments='"x\run-hidden.vbs" "cmd"'; ResultCode=0; LastRun=$now.AddMinutes(-12); Cadence=(New-TimeSpan -Minutes 10) } }
    # 28h since a WEEKLY run is healthy -- guards against a flat threshold.
    @{ n='weekly-fresh';   want='OK T result=0';
       a=@{ Name='T'; Execute='wscript.exe'; Arguments='"x\run-hidden.vbs" "cmd"'; ResultCode=0; LastRun=$now.AddHours(-28); Cadence=(New-TimeSpan -Days 7) } }
    @{ n='bare-exe';       want='RISK T not-routed-through-hidden-wrapper';
       a=@{ Name='T'; Execute='powershell.exe'; Arguments='-File C:\p.ps1'; ResultCode=0; LastRun=$now; Cadence=$null } }
    @{ n='info-unreadable'; want='RISK T task-info-unreadable';
       a=@{ Name='T'; Execute='wscript.exe'; Arguments='"x\run-hidden.vbs" "cmd"'; ResultCode=$null; LastRun=$null; Cadence=$null } }
  )
  $pass = 0; $fail = 0
  foreach ($c in $cases) {
    # Splatting needs @<variable>; `Get-TaskFindings @($c.a)[0]` is an ARRAY subexpression,
    # which binds the whole hashtable positionally to -Name and yields nonsense.
    $splat = $c.a
    $got = (Get-TaskFindings @splat | Select-Object -First 1)
    if ($got -eq $c.want) { $pass++; Write-Output ("PASS {0,-16} {1}" -f $c.n, $got) }
    else { $fail++; Write-Output ("FAIL {0,-16} want='{1}' got='{2}'" -f $c.n, $c.want, $got) }
  }
  Write-Output "-- selftest: $pass passed, $fail failed"
  exit $(if ($fail -gt 0) { 1 } else { 0 })
}

# One-shot AMA-ResumeAtReset-<epoch> tasks (statusline.sh's schedule_resume). resume-rate-
# limited.sh deletes them only when it FIRES; a fire that never happened leaves them forever
# -- 7 were found registered on 2026-09-25 with epochs from August. Sweep any whose epoch is
# more than a day past. Output is a stable count-free token so an unchanged fleet stays
# byte-identical (OUTPUT CONTRACT above); the swept names go to stderr, which run_check
# captures into the snapshot only as the one line below.
try {
  $nowEpoch = [int64][double]::Parse((Get-Date -UFormat %s))
  $stale = @(Get-ScheduledTask -TaskName 'AMA-ResumeAtReset-*' -ErrorAction Stop |
    Where-Object { $_.TaskName -match 'AMA-ResumeAtReset-(\d+)$' -and ([int64]$Matches[1]) -lt ($nowEpoch - 86400) })
  foreach ($t in $stale) {
    try { Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false -ErrorAction Stop } catch {}
  }
  if ($stale.Count -gt 0) { Write-Output "OK resume-tasks swept-stale-one-shots" } else { Write-Output "OK resume-tasks none-stale" }
} catch {
  # Same token as the healthy branch above: "none registered" and "none stale" are the same
  # healthy state, and two spellings would flip in the nightly diff.
  Write-Output "OK resume-tasks none-stale"
}

$tasks = $null
try {
  $tasks = @(Get-ScheduledTask -TaskName 'AMA-Harness-*' -ErrorAction Stop)
} catch {
  # Can't enumerate at all -- that itself is worth reporting, and is stable text so it
  # pings once rather than every night.
  Write-Output "FAIL scheduled-task-inventory cannot-enumerate"
  exit 0
}

if ($tasks.Count -eq 0) {
  Write-Output "FAIL scheduled-task-inventory no-AMA-Harness-tasks-registered"
  exit 0
}

foreach ($task in ($tasks | Sort-Object TaskName)) {
  $info = $null
  try { $info = $task | Get-ScheduledTaskInfo -ErrorAction Stop } catch {}

  $lastRun = $null
  if ($info -and $info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $lastRun = $info.LastRunTime }

  # Runner-stamped success marker (hstate notices .task-ok-<TaskName>); absent for most tasks.
  $manualOk = $null
  $stamp = Join-Path $env:USERPROFILE (".claude\harness-state\notices\.task-ok-" + $task.TaskName)
  if (Test-Path -LiteralPath $stamp) { $manualOk = (Get-Item -LiteralPath $stamp).LastWriteTime }

  Get-TaskFindings `
    -ManualOk   $manualOk `
    -Name       $task.TaskName `
    -Execute    $(if ($task.Actions -and $task.Actions[0].Execute)   { [string]$task.Actions[0].Execute }   else { '' }) `
    -Arguments  $(if ($task.Actions -and $task.Actions[0].Arguments) { [string]$task.Actions[0].Arguments } else { '' }) `
    -ResultCode $(if ($info) { $info.LastTaskResult } else { $null }) `
    -LastRun    $lastRun `
    -Cadence    (Get-Cadence -Task $task) |
    ForEach-Object { Write-Output $_ }
}

exit 0
