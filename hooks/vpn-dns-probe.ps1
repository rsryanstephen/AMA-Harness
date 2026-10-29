# Proactive VPN DNS probe (PROJ-15367). Scheduled task AMA-Harness-VPN-DNS-Probe
# runs this every 10 minutes via run-hidden-generic.vbs (see PORTABILITY.md's
# scheduled-task section; hidden-launch is gate-enforced by scheduled-task-hidden-gate.sh).
#
# Why this exists: hooks/vpn-dns-outage-logger.sh only scrapes failing TOOL-COMMAND output,
# so a resolver fault that degrades Claude Code's own API calls with no failing tool command
# is invisible to it -- confirmed 2026-08-31/09-01: a multi-hour outage produced zero
# automatic detection until a manual probe. This probe is the machine-wide detector; it
# deliberately does NOT ride any session hook path (on-prompt.sh measured 59-72s under two
# concurrent sessions against a 60s budget; cygwin forks cost up to ~2.3s on this box --
# hence PowerShell-native, zero cygwin processes).
#
# Fault signature (two-sided, like the logger's predicate): the VPN resolver (10.1.0.4)
# fails a known-good public name while the DEFAULT resolver answers it. Both failing =
# general connectivity loss, not this fault -- stay silent. VPN resolver absent from any
# adapter = GP disconnected -- stay silent.
#
# On fault: append a dated line to the digest (hstate notices vpn-dns-probe.txt -- surfaced
# and cleared by on-prompt.sh), remember the fault in a state file, play an audible chime.
# On recovery after a remembered fault: append a recovery line (gives IT-7829 durations for
# free) and clear the state file. Dedupe: at most one fault line per 30 minutes.
#
# -SelfTest: print the verdict, write nothing, play nothing.

param(
  [switch]$SelfTest,
  # Overridable for testing: pretend the default resolver answered/failed.
  [ValidateSet('', 'ok', 'fail')][string]$MockDefault = '',
  # Same, for the public control resolver. Both must be mockable to exercise the predicate:
  # under full tunnel the default resolver IS the VPN one, so $MockDefault alone can no
  # longer express "the resolver is broken but connectivity is fine".
  [ValidateSet('', 'ok', 'fail')][string]$MockPublic = '',
  # And the VPN resolver itself, so the FAULT branch is reachable in a test.
  [ValidateSet('', 'ok', 'fail')][string]$MockVpn = '',
  # Latency arm (2026-09-26): pretend the quick lookup took this long, and pretend the
  # patient retry did or did not succeed. Same reasoning as the mocks above -- a branch that
  # can only run during a real fault is a branch nobody can prove still works.
  [int]$MockVpnMs = -1,
  [ValidateSet('', 'ok', 'fail')][string]$MockPatient = '',
  # Write seam, same purpose as CLAUDE_STATE_DIR on the bash side: a test must be able to
  # exercise the real append without touching the real draft ticket or the real state file.
  [string]$TicketPath = '',
  [string]$StateDirOverride = ''
)

$ErrorActionPreference = 'Stop'
$ProbeName = 'api.anthropic.com'
$VpnResolver = '10.1.0.4'
$StateDir = Join-Path $env:USERPROFILE '.claude\harness-state\notices'
$Digest = Join-Path $StateDir 'vpn-dns-probe.txt'
$FaultState = Join-Path $StateDir '.vpn-dns-probe-fault-since'
# Both owned by vpn-dns-ping-claim.sh (Step 1's <name> DM, Step 3's outward-facing writes),
# cleared here on recovery too -- a real recovery ends the outage, so the NEXT fault must
# re-ping, re-report AND re-surface even if it lands inside the claim's own 6h same-outage
# window. Clear ALL THREE or a claim never re-arms and the next outage goes unreported.
$PingClaim = Join-Path $StateDir '.vpn-dns-user-pinged'
$ReportClaim = Join-Path $StateDir '.vpn-dns-reported'
# Third claim: the CLI mention to the user. Every live session gets this same nudge, so
# without a claim each one narrates the same outage into its own reply and the user is told
# N times about one fault. Cleared on recovery with the other two.
$CliClaim = Join-Path $StateDir '.vpn-dns-cli-surfaced'

# SECOND FAULT, added 2026-09-26. Since the full-tunnel switch closed IT-7829, the observed
# failure is the opposite shape: 10.1.0.4 returns the CORRECT record, just too slowly, and a
# client with a shorter timeout than the resolver's retry reports "Could not resolve host".
#
# This probe could not see that, and worse, mislabelled it. Its lookups use -QuickTimeout, so
# a slow-but-correct resolver FAILS the quick lookup, a control answers, and the predicate
# below declared the IT-7829 NXDOMAIN fault -- pointing at the wrong ticket and at a cause
# that has not recurred since 2026-09-04. Telling the two apart needs a second, patient
# lookup: if the name resolves when we simply wait, the resolver is slow, not wrong.
#
# Measured baseline on this host: ~350-400ms per lookup, and one lookup in twelve at 3347ms
# (a lost UDP datagram plus resolver retry). 1500ms sits clear of the baseline and well under
# the retry, so it catches the retry without firing on ordinary jitter.
$SlowMs = 1500
$LatencyState = Join-Path $StateDir '.vpn-dns-latency-last'
# Occurrences are appended to the draft IT ticket itself, so evidence accumulates where it
# will be sent from rather than in a log nobody reads at submission time. $PSScriptRoot is
# the real hooks dir (Task Scheduler invokes the repo path, not the ~/.claude junction), so
# its parent is the harness root -- never a relative '..' through the junction.
$LatencyTicket = Join-Path (Split-Path $PSScriptRoot -Parent) 'IT Tickets\IT-Ticket-VPN-DNS-resolver-latency.md'

if ($TicketPath -ne '') { $LatencyTicket = $TicketPath }
if ($StateDirOverride -ne '') {
  $StateDir = $StateDirOverride
  $Digest = Join-Path $StateDir 'vpn-dns-probe.txt'
  $LatencyState = Join-Path $StateDir '.vpn-dns-latency-last'
  $FaultState = Join-Path $StateDir '.vpn-dns-probe-fault-since'
}

if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force $StateDir | Out-Null }

# GP connected at all? The fault is only meaningful when 10.1.0.4 is an assigned resolver.
$vpnAssigned = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.ServerAddresses -contains $VpnResolver }).Count -gt 0

$vpnOk = $false
switch ($MockVpn) {
  'ok'   { $vpnOk = $true }
  # 'fail' is the seam that makes the FAULT branch testable at all. Without it the fault path
  # can only be exercised during a real outage -- and this probe shipped with a predicate that
  # was broken under full tunnel precisely because nobody could prove FAULT still fired.
  'fail' { $vpnOk = $false }
  default {
    if ($vpnAssigned) {
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      try { Resolve-DnsName $ProbeName -Server $VpnResolver -ErrorAction Stop -QuickTimeout | Out-Null; $vpnOk = $true } catch { $vpnOk = $false }
      $sw.Stop()
      $vpnMs = $sw.ElapsedMilliseconds
    }
  }
}

# How long the quick lookup took, and -- when it failed -- whether patience alone fixes it.
# $MockVpnMs lets a test drive the latency branch without a slow resolver, the same way
# $MockVpn exists so the NXDOMAIN branch is reachable outside a real outage.
if ($MockVpnMs -ge 0) { $vpnMs = $MockVpnMs }
if ($null -eq $vpnMs) { $vpnMs = 0 }

# The discriminator between the two faults. Only asked when the quick lookup failed, so it
# costs nothing on a healthy tick.
$vpnPatientOk = $false
if ($vpnAssigned -and -not $vpnOk -and $MockVpn -eq '' -and $MockVpnMs -lt 0) {
  try { Resolve-DnsName $ProbeName -Server $VpnResolver -ErrorAction Stop | Out-Null; $vpnPatientOk = $true } catch { $vpnPatientOk = $false }
} elseif ($MockPatient -ne '') {
  $vpnPatientOk = ($MockPatient -eq 'ok')
}

$defaultOk = $false
switch ($MockDefault) {
  'ok'   { $defaultOk = $true }
  'fail' { $defaultOk = $false }
  default {
    try { Resolve-DnsName $ProbeName -ErrorAction Stop -QuickTimeout | Out-Null; $defaultOk = $true } catch { $defaultOk = $false }
  }
}

# CONTROL RESOLVER (added 2026-09-04). The original predicate used $defaultOk alone as the
# "is it just this resolver?" control, which silently stopped working the moment <name> moved
# this host from split tunnel to FULL tunnel (10:44 that day, as an IT-7829 workaround).
#
# Under full tunnel the PANGP adapter's interface metric is 1 vs Wi-Fi's 35, so 10.1.0.4 IS
# the default resolver -- measured: an unqualified query answers from Azure-DC.<tenant domain>
# (10.1.0.4). $vpnOk and $defaultOk therefore test the SAME server, the two-sided predicate
# collapses to one side, and a real fault makes BOTH false -- which the code reads as
# "general connectivity loss, not this fault" and stays SILENT. Confirmed by -SelfTest:
# vpnAssigned=True vpnOk=True defaultOk=False => "general-connectivity (not this fault)".
# So the probe went blind to the exact fault it exists to detect, with no error and no log.
#
# Fix: an explicit public resolver as a second control. 8.8.8.8 is reachable under full
# tunnel (measured: google.com resolves through it), so "10.1.0.4 fails but a public resolver
# answers" is a valid fault signature in BOTH tunnel modes. Either control answering is
# enough to prove connectivity is intact and the fault is resolver-specific.
$PublicResolver = '8.8.8.8'
$publicOk = $false
switch ($MockPublic) {
  'ok'   { $publicOk = $true }
  'fail' { $publicOk = $false }
  default {
    try { Resolve-DnsName $ProbeName -Server $PublicResolver -ErrorAction Stop -QuickTimeout | Out-Null; $publicOk = $true } catch { $publicOk = $false }
  }
}
$controlOk = $defaultOk -or $publicOk

$now = Get-Date
$stamp = $now.ToString('yyyy-MM-dd HH:mm')

# IT-7829, narrowed 2026-09-26: the resolver must be genuinely unable to answer -- failing
# the quick lookup AND the patient one. Without that second term a merely slow resolver was
# reported as this fault, which is the wrong ticket and a cause that has not recurred since
# the full-tunnel switch.
$fault = $vpnAssigned -and (-not $vpnOk) -and (-not $vpnPatientOk) -and $controlOk

# The new fault: correct answers, too slow to be useful. Either shape counts -- a lookup that
# succeeded but crawled, or one that needed the patient retry to succeed at all (which is
# exactly what a client with a short timeout experiences as "Could not resolve host").
$latencyFault = $vpnAssigned -and (($vpnOk -and $vpnMs -ge $SlowMs) -or ((-not $vpnOk) -and $vpnPatientOk))

# ---------------------------------------------------------------------------------------
# SECOND, INDEPENDENT CHECK: did PanGPS (the GlobalProtect service) just crash?
#
# Why it lives in this script and not its own task: same ticket (IT-7829), same 10-minute
# cadence, and reusing this task avoids a second scheduled-task registration. It shares
# NOTHING with the DNS predicate above -- either can fire without the other.
#
# What problem this actually solves. PanGPS crashed 2026-08-27 23:32:35 (ntdll.dll,
# 0xc0000005). By the time anyone looked, WER had uploaded and PURGED the ReportQueue entry
# that held memory.hdmp, and no LocalDumps policy existed, so the dump was gone for good --
# the user asked (2026-09-01) to make sure it gets collected next time.
#
# This CANNOT collect the dump itself: this task runs RunLevel=Limited, and WER's report
# directories are ACL'd to SYSTEM/Administrators. What it CAN do is make the window usable.
# Last time the queue entry survived from 23:32 until upload finished 07:14 the NEXT
# MORNING -- ~7.7 hours. A 10-minute-latency alarm inside a 7.7-hour window is the
# difference between a manual elevated copy succeeding and the artifact being gone.
#
# So: capture everything readable unelevated NOW (the event records, which are the part
# that survives nothing), attempt the WER copy and record honestly whether it worked, then
# shout -- digest line + chime -- with the elevated command to run.
#
# The real fix is still one elevated one-time HKLM write (LocalDumps\PanGPS.exe); see
# ~/Documents/IT-7829-PanGPS-crash/RECOVER-DUMP.md. This is the belt to that braces, and it
# is what we get to have without admin rights.
function Invoke-PanGPSCrashCheck {
  param([switch]$DryRun)

  # Whole body guarded: a fault here must never take down the DNS probe above, which is
  # this task's primary job.
  try {
    $SeenState = Join-Path $StateDir '.pangps-last-crash-record'
    $Archive   = Join-Path $env:USERPROFILE 'Documents\IT-7829-PanGPS-crash'

    # Application 1000 is the crash itself; 1001 is WER's report (carries the queue path).
    # System 7031 is SCM noticing -- it lagged 35 min last time, so it is NOT the trigger.
    $events = @(Get-WinEvent -FilterHashtable @{ LogName='Application'; Id=1000,1001 } -MaxEvents 400 -ErrorAction SilentlyContinue |
      Where-Object { $_.Message -match 'PanGP' })

    if ($events.Count -eq 0) { if ($DryRun) { return 'no PanGP crash records in the last 400 Application 1000/1001 events' }; return }

    # Trigger on the newest record of EITHER id, so a late-arriving 1001 still wakes this.
    $newest = ($events | Sort-Object TimeCreated -Descending)[0]
    $mark   = "$($newest.RecordId)"
    $seen   = if (Test-Path $SeenState) { (Get-Content $SeenState -ErrorAction SilentlyContinue | Select-Object -First 1) } else { '' }

    # ...but LABEL it with the newest Event 1000 (the actual fault). WER's 1001 records can
    # trail the crash by hours -- 2026-08-27's crash was 23:32:35 while its last 1001 landed
    # 07:14:31 the next morning, and labelling from $newest reported that upload time as the
    # crash time. Wrong by 7h44m, on the one field every correlation depends on.
    $crash1000  = @($events | Where-Object Id -eq 1000 | Sort-Object TimeCreated -Descending) | Select-Object -First 1
    $faultLabel = if ($crash1000) { $crash1000.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss') }
                  else { "unknown (no Event 1000 retained; newest WER record $($newest.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')))" }

    if ($DryRun) {
      return "newest PanGP record: RecordId=$mark at $($newest.TimeCreated); crash time (Event 1000): $faultLabel; already handled=$($seen -eq $mark)"
    }
    if ($seen -eq $mark) { return }   # already collected this one

    # --- new crash: collect ------------------------------------------------------------
    # Folder named for the FAULT time too, for the same reason as $faultLabel.
    $dirStamp = if ($crash1000) { $crash1000.TimeCreated.ToString('yyyy-MM-dd_HHmmss') } else { $newest.TimeCreated.ToString('yyyy-MM-dd_HHmmss') }
    $stampDir = Join-Path $Archive ('crashes\' + $dirStamp)
    New-Item -ItemType Directory -Force $stampDir | Out-Null

    # 1. The event records. Always readable unelevated, and the only part guaranteed to
    #    survive -- so it is captured first, before anything that can fail.
    $events | Sort-Object TimeCreated | ForEach-Object {
      "TimeCreated : $($_.TimeCreated)`nLog         : $($_.LogName)`nEventId     : $($_.Id)`nRecordId    : $($_.RecordId)`n`n$($_.Message)`n`n$('-'*78)`n"
    } | Set-Content -Path (Join-Path $stampDir 'Application-1000-1001-PanGP.txt') -Encoding UTF8

    Get-WinEvent -FilterHashtable @{ LogName='System'; Id=7031 } -MaxEvents 60 -ErrorAction SilentlyContinue |
      Where-Object { $_.Message -match 'PanGPS' } |
      ForEach-Object { "$($_.TimeCreated)  Id=$($_.Id)  RecordId=$($_.RecordId)`n$($_.Message)`n" } |
      Set-Content -Path (Join-Path $stampDir 'System-7031-PanGPS.txt') -Encoding UTF8

    # 2. Attempt the WER artifacts. Expected to fail at RunLevel=Limited -- the point is to
    #    RECORD which, so the log never again implies an artifact exists when it does not
    #    (that exact false positive happened 2026-09-01: Test-Path returns False for
    #    "denied" identically to "absent", so errors must be surfaced, never suppressed).
    $log = @("PanGPS crash collection $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') as $env:USERNAME (RunLevel=Limited)")
    $copied = 0
    foreach ($root in 'C:\ProgramData\Microsoft\Windows\WER\ReportQueue',
                      'C:\ProgramData\Microsoft\Windows\WER\ReportArchive') {
      $log += "-- $root"
      try {
        foreach ($d in @(Get-ChildItem $root -Directory -Force -ErrorAction Stop | Where-Object { $_.Name -match 'PanGP' })) {
          $log += "   report dir: $($d.Name)"
          try {
            foreach ($f in [System.IO.Directory]::GetFiles($d.FullName)) {
              Copy-Item $f -Destination $stampDir -Force -ErrorAction Stop
              $log += "     COPIED $([System.IO.Path]::GetFileName($f))"
              $copied++
            }
          } catch { $log += "     CONTENTS DENIED (needs elevation): $($_.Exception.Message)" }
        }
      } catch { $log += "   ROOT DENIED: $($_.Exception.Message)" }
    }
    # 2b. LocalDumps -- the real fix, armed elevated by the user 2026-09-01. WER writes a
    #     SEPARATE full dump here that nothing purges (bar its own DumpCount rotation), so
    #     unlike the ReportQueue copy it is still there hours later. Confirmed the ACL lets
    #     THIS unelevated task read it: BUILTIN\Users ReadAndExecute + Authenticated Users
    #     Modify on C:\CrashDumps.
    #
    #     Recorded, NOT copied, on purpose: a DumpType=2 full dump of a VPN client is large
    #     and contains credentials/tunnel state. Duplicating it into ~/Documents would double
    #     hundreds of MB of sensitive data for no gain when the original is already durable
    #     and readable in place. The digest carries the path instead.
    $dumpFound = @()
    $dumpFolder = ''
    try {
      $ldKey = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\PanGPS.exe'
      if (Test-Path $ldKey) {
        $dumpFolder = [Environment]::ExpandEnvironmentVariables([string](Get-ItemProperty $ldKey -ErrorAction Stop).DumpFolder)
      }
    } catch {}
    if ($dumpFolder -and (Test-Path $dumpFolder)) {
      $log += "-- LocalDumps folder $dumpFolder"
      try {
        foreach ($f in @(Get-ChildItem $dumpFolder -File -Filter 'PanGPS*' -ErrorAction Stop | Sort-Object LastWriteTime -Descending)) {
          $mb = [math]::Round($f.Length / 1MB, 1)
          $log += ("   DUMP {0}  {1} MB  {2}" -f $f.Name, $mb, $f.LastWriteTime)
          $dumpFound += ("{0} ({1} MB)" -f $f.FullName, $mb)
        }
        if ($dumpFound.Count -eq 0) { $log += "   no PanGPS* dump present yet" }
      } catch { $log += "   LISTING DENIED: $($_.Exception.Message)" }
    } else {
      $log += "-- LocalDumps NOT armed for PanGPS.exe (no DumpFolder) -- see ~/Documents/IT-7829-PanGPS-crash/RECOVER-DUMP.md"
    }

    $log += "files copied: $copied"
    $log | Set-Content -Path (Join-Path $stampDir '_wer-retrieval-attempt.log') -Encoding UTF8

    # 3. Shout. Three cases, in descending order of how much is already in hand -- the alert
    #    must never tell the reader to arm LocalDumps when it is already armed (it was, by the
    #    user, 2026-09-01), nor imply a dump exists when it does not.
    $dumpNote =
      if ($dumpFound.Count -gt 0) {
        "FULL DUMP already captured by LocalDumps and readable in place: $($dumpFound -join '; ') -- attach that to IT-7829 for Palo Alto (it is a full dump of a VPN client: credentials/tunnel state, so hand it over via the ticket attachment, never an external file-share)"
      } elseif ($copied -gt 0) {
        "$copied WER file(s) copied; no LocalDumps dump present"
      } else {
        'no dump found yet -- LocalDumps may not have flushed; re-check the LocalDumps folder, and the WER ReportQueue copy is purged after upload'
      }

    # Single-quoted so nothing in the recipe is expanded or needs escaping: the `$_` and the
    # `\*` are meant to reach the user's elevated shell verbatim. (Writing this inline in a
    # double-quoted string is what broke the parser on the first attempt -- `\"` is a
    # bash-ism, not PowerShell, and `$_` would have expanded to nothing here.)
    $grabCmd = 'Get-ChildItem ''C:\ProgramData\Microsoft\Windows\WER\ReportQueue'' -Directory | Where-Object Name -match ''PanGP'' | ForEach-Object { Copy-Item (Join-Path $_.FullName ''*'') -Destination ''<DEST>'' -Force }'
    $grabCmd = $grabCmd.Replace('<DEST>', $stampDir)

    # MUST stay ONE physical line. The DNS branch below dedupes with
    # `Get-Content $Digest -Tail 1` + a `^yyyy-MM-dd HH:mm` match; a multi-line entry leaves
    # a non-timestamped last line, the match fails, $recent stays $false and the 30-minute
    # FAULT throttle silently degrades to one line every tick. Caught in test, 2026-09-01.
    $msg = "$stamp PanGPS CRASHED $faultLabel (GlobalProtect service, IT-7829). " +
           "Event records saved to $stampDir; $dumpNote. " +
           "Run ELEVATED before WER uploads and purges it:  $grabCmd  " +
           "-- then post the crash signature to IT-7829 per Skill(ama-vpn-dns-outage) Step 3, and arm " +
           "LocalDumps (see ~/Documents/IT-7829-PanGPS-crash/RECOVER-DUMP.md) so this stops being manual."
    Add-Content -Path $Digest -Value $msg
    Play-Chime

    Set-Content -Path $SeenState -Value $mark -NoNewline
    return "collected crash RecordId=$mark"
  } catch {
    # Never let this sink the DNS probe. Leave a breadcrumb and move on.
    try { Add-Content -Path $Digest -Value "$stamp NOTE: PanGPS crash-check in vpn-dns-probe.ps1 errored ($($_.Exception.Message)) -- DNS probe result above is unaffected." } catch {}
  }
}

if ($SelfTest) {
  "vpnAssigned=$vpnAssigned vpnOk=$vpnOk vpnMs=$vpnMs vpnPatientOk=$vpnPatientOk defaultOk=$defaultOk publicOk=$publicOk => " + ($(if ($fault) { 'FAULT (IT-7829, NXDOMAIN)' } elseif ($latencyFault) { 'LATENCY-FAULT (resolver slow, new ticket)' } elseif (-not $vpnAssigned) { 'no-vpn' } elseif (-not $controlOk) { 'general-connectivity (not this fault)' } else { 'healthy' }))
  "latency-ticket: $LatencyTicket (present=" + (Test-Path $LatencyTicket) + ")"
  "pangps-crash-check: " + (Invoke-PanGPSCrashCheck -DryRun)
  exit 0
}

function Play-Chime {
  # Direct SoundPlayer, not notify-sound.sh -- that script is a Claude Code session hook
  # (reads a hook JSON payload, suppresses on headless/background context); this runs from
  # Task Scheduler with no session. Stock chime is fine unamplified for an alert.
  try {
    $wav = 'C:\Windows\Media\Windows Notify Calendar.wav'
    if (Test-Path $wav) { (New-Object System.Media.SoundPlayer($wav)).PlaySync() }
  } catch {}
}

function Add-LatencyOccurrence {
  # Appends one numbered Occurrence to the draft IT ticket, so evidence piles up in the
  # document that will actually be submitted rather than in a log nobody re-reads. Throttled
  # to one per 6h: the probe ticks every 10 minutes, and a sustained slow period would
  # otherwise write 36 near-identical entries a day and bury the distinct ones.
  param([long]$Ms, [bool]$NeededRetry)

  if (-not (Test-Path $LatencyTicket)) { return 'ticket absent -- digest only' }

  if (Test-Path $LatencyState) {
    $prev = Get-Content $LatencyState -Tail 1 -ErrorAction SilentlyContinue
    if ($prev -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2})') {
      try {
        if ((New-TimeSpan -Start ([datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm', $null)) -End $now).TotalHours -lt 6) {
          return 'throttled (<6h since last)'
        }
      } catch {}
    }
  }

  # Number the entry from what is already in the file, so entries stay ordered and a
  # hand-written one (like the first) is counted too.
  $existing = @(Select-String -Path $LatencyTicket -Pattern '^### \d+ ' -ErrorAction SilentlyContinue).Count
  $n = $existing + 1

  # Built as plain variables, never as $(if ...) inside the array literal below: a
  # subexpression there lands as its OWN array element and the rendered line breaks in half
  # ("quick lookup: 3347ms," then "succeeded" on the next line). Caught in test.
  if ($NeededRetry) {
    $shape = 'The quick lookup failed and a patient retry succeeded -- the shape a client with a short timeout reports as "Could not resolve host".'
    $quickText = "failed after ${Ms}ms"
    $retryText = 'succeeded (resolver is slow, not wrong)'
  } else {
    $shape = "The lookup succeeded but took ${Ms}ms against a ~350-400ms baseline."
    $quickText = "succeeded in ${Ms}ms"
    $retryText = 'not needed'
  }

  $entry = @(
    '',
    "### $n -- $stamp (local), detected by hooks/vpn-dns-probe.ps1",
    '',
    $shape,
    '',
    "    probe name:        $ProbeName",
    "    resolver:          $VpnResolver",
    "    quick lookup:      $quickText",
    "    patient retry:     $retryText",
    "    control resolvers: default=$defaultOk public($PublicResolver)=$publicOk",
    '',
    'Recorded automatically; no human was watching at the time.'
  ) -join "`r`n"

  Add-Content -Path $LatencyTicket -Value $entry
  Set-Content -Path $LatencyState -Value $stamp -NoNewline
  return "appended occurrence $n"
}

if ($latencyFault -and -not $fault) {
  $neededRetry = (-not $vpnOk)
  $wrote = Add-LatencyOccurrence -Ms $vpnMs -NeededRetry $neededRetry
  if ($neededRetry) {
    $what = "$VpnResolver failed a quick lookup of $ProbeName but answered it correctly on a patient retry"
  } else {
    $what = "$VpnResolver answered $ProbeName correctly but slowly (${vpnMs}ms, threshold ${SlowMs}ms)"
  }
  Add-Content -Path $Digest -Value "$stamp LATENCY: $what -- this is the post-full-tunnel resolver-latency fault, NOT IT-7829. Evidence appended to IT Tickets/IT-Ticket-VPN-DNS-resolver-latency.md ($wrote). That ticket is a DRAFT held until there are several occurrences -- do not send it, and do not ping <name> for this."
}

if ($fault) {
  $recent = $false
  if (Test-Path $Digest) {
    $last = Get-Content $Digest -Tail 1 -ErrorAction SilentlyContinue
    if ($last -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2})') {
      try { $recent = ((New-TimeSpan -Start ([datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm', $null)) -End $now).TotalMinutes -lt 30) } catch {}
    }
  }
  if (-not (Test-Path $FaultState)) { Set-Content -Path $FaultState -Value $stamp -NoNewline }
  if (-not $recent) {
    # Wording kept in step with reality on two counts that were both stale by 2026-09-04:
    # the ping goes to BARRY again (standing instruction reverted the ping-the-user version),
    # and "self-heals in minutes" is false -- one measured window ran ~24h50m and was ended by
    # <name>'s full-tunnel switch, not by healing. Also "the default resolver answers" no longer
    # describes the control: under full tunnel the default resolver IS 10.1.0.4.
    Add-Content -Path $Digest -Value "$stamp FAULT: $ProbeName NXDOMAIN via $VpnResolver while a control resolver (default or $PublicResolver) answers -- the IT-7829 VPN DNS fault is live. Invoke Skill(ama-vpn-dns-outage) now (pings BARRY per the skill, deduped across sessions, then live capture). Capture NOW -- episodes have run minutes to ~25h, so do not wait for it to clear."
    Play-Chime
  }
} elseif ($vpnOk -and (Test-Path $FaultState)) {
  $since = Get-Content $FaultState -ErrorAction SilentlyContinue
  Add-Content -Path $Digest -Value "$stamp RECOVERED: $VpnResolver resolving again (fault first seen $since) -- update the open IT-Ticket-VPN-DNS Example entry with this recovery time/duration."
  Remove-Item $FaultState -Force -ErrorAction SilentlyContinue
  Remove-Item $PingClaim -Force -ErrorAction SilentlyContinue
  Remove-Item $ReportClaim -Force -ErrorAction SilentlyContinue
  Remove-Item $CliClaim -Force -ErrorAction SilentlyContinue
}

# Second check, run on every tick regardless of what the DNS branch above decided -- a
# PanGPS crash is independent of whether the resolver is currently faulting. Its whole body
# is try/catch'd internally, so it cannot affect this script's exit code.
Invoke-PanGPSCrashCheck | Out-Null

exit 0