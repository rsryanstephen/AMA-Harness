# Console-window watcher. <harnessEpicKey>, 2026-09-15.
#
# WHY. Blank, title-less console windows cascade across the desktop during a hook-timeout
# storm (many sessions, hooks past their timeout, Claude Code firing `taskkill /T /F` per
# tree). Live sampling at moderate load found every routine spawn hidden -- hook bash.exe,
# Bash-tool bash.exe, Claude Code's own taskkill.exe, the PowerShell-tool pwsh.exe all get a
# console with NO window -- so the visible ones only exist mid-storm and were never caught
# with their owner. This logs the owner the next time one appears. Detection-only: reads
# process state, appends one log line per new window, never kills or touches anything.
#
# RUNS as scheduled task AMA-Harness-Console-Window-Watch (at logon, stays resident) via
# scripts/run-hidden-generic.vbs, so the watcher itself never has a window. Steady-state
# cost is one EnumWindows pass every 250ms inside a compiled helper (a first cut used
# Get-Process per second and burned 4.5% of a core -- measured, not acceptable on a box
# that is already the problem; a second cut polled only ConsoleWindowClass every 2s and
# MISSED a live episode at 20:20 the same day, so now every visible top-level window is
# enumerated and filtered by owner process name, class logged). Win32_Process (slow) runs
# only when a NEW visible window is actually seen. on-prompt.sh relays new log lines once.
#
# Log: ~/.claude/harness-state/logs/console-windows.log -- one block per sighting:
#   time  proc[pid]  title='...'  class=...  rect=WxH  console=<classic|headless|none>
#     <- parent chain, 5 levels, with command lines
# plus one "started" line per launch with the count of visible windows seen, proving the
# enumeration works from the task's context. Skipped on purpose: tooltips and anything
# under 100x40; a window whose 5-level ancestry has explorer.exe/mintty.exe and no
# claude/node/wscript above it (a shell the user opened); and any handle already logged.
#
# NEXT TWEAK IF NOISE RECURS (noted 2026-09-18, so whoever hits it does not re-derive it):
# the filter is exclusion-based, so a user shell launched via COM/svchost (Windows
# Terminal `-Embedding`, chain svchost <- services <- wininit) still logs. Flip it to
# INCLUSION -- log only when the chain contains claude/node/wscript -- once the storm's
# spawner has been named at least once; until then inclusion could hide an unknown
# spawner, which is the whole reason this watcher exists.
#
# SECOND JOB (2026-10-12): Defender for Endpoint investigations. SenseIR.exe (MDE automated
# investigation / live response) started at 15:57:39 and every terminal crawled while
# MsMpEng + MsSense held ~2.5 cores. What triggers it is visible only in IT's console, and
# Sysmon's log here rolls over in minutes (21,608 process starts in ~10 min), so there was no
# history to correlate against. Every 20 ticks (~5s) this checks for SenseIR by name -- a
# handle lookup, no WMI -- and appends to harness-state/logs/defender-activity.log:
#   <time> senseir-start pid=N created=<time> parent=<name>  (one CIM query, only when new)
#   <time> senseir-end   pid=N ran=<minutes>
# Separate log on purpose: on-prompt.sh relays console-windows.log lines as console flashes.
# Correlate starts against Group Policy refreshes and our own scheduled tasks
# (orphan-conhost-reap.log, Task Scheduler LastRunTime) -- that is the evidence for IT.
# Process-start latency is NOT sampled from here, on purpose: this task's chain is wscript ->
# hidden powershell, and a shell spawned from it once a minute is the shape EDR flags, so the
# probe could raise the investigations it measures. dispatch.sh samples it on the hooks' own
# node -> bash path instead (proc-start-latency.log, 2026-10-14).
#
# -SelfTest: one tick, prints what WOULD be logged (including the skipped ones, tagged),
# writes nothing, exits 0.
param([switch]$SelfTest)

$ErrorActionPreference = 'SilentlyContinue'
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace CW {
  public class Sighting { public IntPtr Hwnd; public int Pid; public string Title; public string Cls; public int W; public int H; }
  public static class Win {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    public static List<Sighting> VisibleWindows() {
      var list = new List<Sighting>();
      EnumWindows((h, l) => {
        if (!IsWindowVisible(h)) return true;
        var cls = new StringBuilder(64); GetClassName(h, cls, 64);
        uint pid; GetWindowThreadProcessId(h, out pid);
        var t = new StringBuilder(512); GetWindowText(h, t, 512);
        RECT r; GetWindowRect(h, out r);
        list.Add(new Sighting { Hwnd = h, Pid = (int)pid, Title = t.ToString(), Cls = cls.ToString(), W = r.R - r.L, H = r.B - r.T });
        return true;
      }, IntPtr.Zero);
      return list;
    }
  }
}
'@

# One instance per session. Stop-ScheduledTask kills wscript.exe and leaves this powershell
# alive (confirmed live: two watchers after one restart), so the task's IgnoreNew cannot
# guarantee it -- a named mutex can.
$mutex = New-Object System.Threading.Mutex($false, 'Local\AMA-Harness-Console-Window-Watch')
if (-not $SelfTest -and -not $mutex.WaitOne(0)) { exit 0 }

$logDir = Join-Path $env:USERPROFILE '.claude\harness-state\logs'
$log = Join-Path $logDir 'console-windows.log'
# Owner process names worth logging. Anything a Claude session or hook can spawn that hosts
# a window: console hosts, shells, the tools they call. Matched on the owning PID's name.
$ownerRe = '^(conhost|OpenConsole|WindowsTerminal|bash|sh|dash|mintty|powershell|pwsh|cmd|taskkill|jq|node|claude|wscript|cscript|perl|python|git|ssh|curl)$'
$seen = @{}
$pidName = @{}
$defLog = Join-Path $logDir 'defender-activity.log'
$irSeen = @{}      # SenseIR pid -> start time (for the end line's duration)
$tick = 0
# THIRD JOB (2026-10-15): start the elevated Defender recording while the engine is hot.
# Every 240 ticks (~60 s) one PDH sample of MsMpEng's CPU; two consecutive minutes above one
# core start scheduled task AMA-Harness-Defender-Hot-Record (scripts/defender-hot-record.ps1).
# Same 30-min cooldown marker as hooks/defender-hot-trigger.sh ("<epoch> <reason>"), which
# fires on slow bash starts -- so the two triggers never double-record. Start-ScheduledTask
# directly, never a bash spawn from this chain (see the latency note above).
$hotLast = Join-Path $logDir '.defender-hot-last'
$hotDay = Join-Path $logDir '.defender-hot-day'     # "<yyyy-MM-dd> <starts today>", shared with the trigger script
$hotLog = Join-Path $logDir 'defender-hot.log'
$engHot = 0
# FOURTH JOB (2026-10-15): one line a minute to harness-state/logs/engine-cpu.log, the timeline
# scripts/proc-start-latency.sh joins with the bash-start and file-probe samples to tell the
# slow-spell explanations apart (scan waits vs CPU vs memory vs process creation):
#   <time> eng=% sense=% total=% queue=N availmb=N diskq=N senseir=0|1 procs=bash:N,... [top=name:%,...]
# eng/sense are % of ONE core, total is % of all 20. One Get-Counter call for the whole set
# (the same sample the trigger reads), process counts from one in-process enumeration, top CPU
# consumers (CPU-seconds since the last minute, as % of a core) only on busy minutes. No spawns.
$cpuLog = Join-Path $logDir 'engine-cpu.log'
$cpuSet = @('\Process(MsMpEng)\% Processor Time', '\Process(MsSense)\% Processor Time', '\Processor(_Total)\% Processor Time',
  '\System\Processor Queue Length', '\Memory\Available MBytes', '\PhysicalDisk(_Total)\Avg. Disk Queue Length')
$cpuPrev = @{}; $cpuPrevAt = $null; $cpuDenied = @{}

function Get-MinuteSample {
  $v = @{ eng = -1; sense = -1; total = -1; queue = -1; availmb = -1; diskq = -1 }
  try {
    foreach ($c in (Get-Counter $cpuSet -SampleInterval 1 -MaxSamples 1 -ErrorAction SilentlyContinue).CounterSamples) {
      $p = $c.Path
      $k = if ($p -match 'process\(msmpeng\)') { 'eng' } elseif ($p -match 'process\(mssense\)') { 'sense' } elseif ($p -match 'processor\(_total\)') { 'total' } elseif ($p -match 'processor queue length') { 'queue' } elseif ($p -match 'available mbytes') { 'availmb' } elseif ($p -match 'disk queue length') { 'diskq' } else { $null }
      if ($k) { $v[$k] = $c.CookedValue }
    }
  } catch {}
  $counts = @{}; $now = Get-Date; $cpuNow = @{}; $busy = ($v.total -ge 50 -or $v.eng -ge 100)
  foreach ($pr in [System.Diagnostics.Process]::GetProcesses()) {
    $n = $pr.ProcessName; $counts[$n] = 1 + [int]$counts[$n]
    # Never open a handle to lsass (an ASR rule here blocks and logs lsass access) or the
    # Defender processes, whose CPU the counters already give; denied ones are remembered.
    if ($n -match '^(lsass|MsMpEng|MsSense|SenseIR|SenseNdr|SenseCncProxy|Idle|System|Registry|Secure System|smss|csrss|wininit|services)$') { continue }
    if ($cpuDenied.ContainsKey("$($pr.Id)")) { continue }
    try { $cpuNow["$($pr.Id)"] = @($n, $pr.TotalProcessorTime.TotalSeconds) } catch { $cpuDenied["$($pr.Id)"] = 1 }
  }
  $top = ''
  if ($busy -and $cpuPrevAt) {
    $secs = ($now - $cpuPrevAt).TotalSeconds; $byName = @{}
    foreach ($id in $cpuNow.Keys) { if ($cpuPrev.ContainsKey($id)) { $d = $cpuNow[$id][1] - $cpuPrev[$id][1]; if ($d -gt 0) { $byName[$cpuNow[$id][0]] = $d + [double]$byName[$cpuNow[$id][0]] } } }
    $top = ' top=' + (($byName.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 4 | ForEach-Object { '{0}:{1:N0}%' -f $_.Key, (100 * $_.Value / $secs) }) -join ',')
  }
  $script:cpuPrev = $cpuNow; $script:cpuPrevAt = $now
  $procs = (@('bash', 'node', 'dotnet', 'testhost', 'VBCSCompiler', 'claude') | ForEach-Object { '{0}:{1}' -f $_, [int]$counts[$_] }) -join ','
  $inv = [Globalization.CultureInfo]::InvariantCulture
  $line = [string]::Format($inv, '{0:yyyy-MM-ddTHH:mm:ss} eng={1:F0} sense={2:F0} total={3:F0} queue={4:F0} availmb={5:F0} diskq={6:F1} senseir={7} procs={8}{9}',
    $now, $v.eng, $v.sense, $v.total, $v.queue, $v.availmb, $v.diskq, [int]([bool]$counts['SenseIR']), $procs, $top)
  return @{ line = $line; eng = $v.eng }
}

function Watch-EngineCpu {
  $pct = -1
  try {
    $m = Get-MinuteSample
    $pct = [math]::Round($m.eng)
    if (-not $SelfTest) {
      $f = Get-Item -LiteralPath $cpuLog -ErrorAction SilentlyContinue
      if ($f -and $f.Length -gt 5MB) { Move-Item -Force -LiteralPath $cpuLog -Destination "$cpuLog.1" }
      Add-Content -LiteralPath $cpuLog -Value $m.line -Encoding UTF8
    } else { Write-Output "[engine-cpu] $($m.line)" }
  } catch { return }
  if ($SelfTest -or $pct -lt 0) { return }
  if ($pct -gt 100) { $script:engHot++ } else { $script:engHot = 0; return }
  if ($script:engHot -lt 2) { return }
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $last = [long]0
  if (Test-Path $hotLast) { $f = ("$(Get-Content $hotLast -First 1)" -split ' ')[0]; [long]::TryParse($f, [ref]$last) | Out-Null }
  if (($now - $last) -lt 1800) { return }
  # Same daily cap as the trigger script (2 starts a day, failed ones included).
  $today = Get-Date -Format 'yyyy-MM-dd'; $dn = 0
  if (Test-Path $hotDay) { $d = ("$(Get-Content $hotDay -First 1)" -split ' '); if ($d[0] -eq $today -and $d.Count -gt 1) { [int]::TryParse($d[1], [ref]$dn) | Out-Null } }
  if ($dn -ge 2) { return }
  $reason = "msmpeng=$pct%"
  Set-Content -Path $hotLast -Value "$now $reason"
  Set-Content -Path $hotDay -Value "$today $($dn + 1)"
  try { Start-ScheduledTask -TaskName 'AMA-Harness-Defender-Hot-Record' -ErrorAction Stop; $msg = 'started' }
  catch { $msg = 'FAILED to start (task registered? run scripts/register-defender-hot-record.ps1 from an elevated PowerShell)' }
  Add-Content -Path $hotLog -Value ("{0:yyyy-MM-ddTHH:mm:ss} hot-record {1} reason={2}" -f (Get-Date), $msg, $reason) -Encoding UTF8
}

function Watch-SenseIR {
  $now = Get-Date
  $live = @{}
  foreach ($p in [System.Diagnostics.Process]::GetProcessesByName('SenseIR')) { $live["$($p.Id)"] = 1 }
  foreach ($id in @($live.Keys)) {
    if ($irSeen.ContainsKey($id)) { continue }
    $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$id"
    $created = if ($ci) { $ci.CreationDate } else { $now }
    $parent = if ($ci) { (Get-CimInstance Win32_Process -Filter "ProcessId=$($ci.ParentProcessId)").Name } else { '' }
    $irSeen[$id] = $created
    $lines = @("{0:yyyy-MM-ddTHH:mm:ss} senseir-start pid={1} created={2:HH:mm:ss} parent={3}" -f $now, $id, $created, $(if ($parent) { $parent } else { '(gone)' }))
    # What started in the 3 minutes before it -- still-alive processes only, so partial, but
    # task launches (wscript), PowerShell, schtasks and taskkill are what an alert would key on.
    $from = $created.AddMinutes(-3)
    Get-CimInstance Win32_Process | Where-Object {
      $_.CreationDate -ge $from -and $_.CreationDate -le $created -and
      $_.Name -match '^(powershell|pwsh|wscript|cscript|schtasks|taskkill|reg|sc|msiexec|cmd|node|python|gpupdate|svchost)\.exe$'
    } | Sort-Object CreationDate | Select-Object -First 15 | ForEach-Object {
      $cl = "$($_.CommandLine)" -replace '\s+', ' '; if ($cl.Length -gt 160) { $cl = $cl.Substring(0, 160) + '...' }
      $lines += ("    preceded-by {0:HH:mm:ss} {1}[{2}] {3}" -f $_.CreationDate, $_.Name, $_.ProcessId, $cl)
    }
    foreach ($l in $lines) { Write-DefenderLine $l }
  }
  foreach ($id in @($irSeen.Keys)) {
    if ($live.ContainsKey($id)) { continue }
    Write-DefenderLine ("{0:yyyy-MM-ddTHH:mm:ss} senseir-end pid={1} ran={2:N1}min" -f $now, $id, ($now - $irSeen[$id]).TotalMinutes)
    $irSeen.Remove($id)
  }
}

function Write-DefenderLine([string]$line) {
  if ($SelfTest) { Write-Output "[defender-activity] $line"; return }
  if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force $logDir | Out-Null }
  Add-Content -Path $defLog -Value $line -Encoding UTF8
}

function Get-Chain($pid0, $byId) {
  $out = New-Object System.Collections.Generic.List[string]
  $cur = $byId["$pid0"]; $n = 0
  while ($cur -and $n -lt 5) {
    $cur = $byId["$($cur.ParentProcessId)"]; $n++
    if (-not $cur) { $out.Add('    <- (parent gone)'); break }
    $cl = ("$($cur.CommandLine)" -replace '\s+', ' ')
    if ($cl.Length -gt 200) { $cl = $cl.Substring(0, 200) + '...' }
    $out.Add(("    <- {0}[{1}] {2}" -f $cur.Name, $cur.ProcessId, $cl))
  }
  return $out
}

function Write-Sighting([string[]]$lines) {
  if ($SelfTest) { $lines | ForEach-Object { Write-Output $_ }; return }
  if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force $logDir | Out-Null }
  $f = Get-Item $log
  if ($f -and $f.Length -gt 1MB) { Move-Item -Force $log "$log.1" }
  Add-Content -Path $log -Value ($lines -join "`n") -Encoding UTF8
}

# Startup proof: the enumeration sees the desktop from this context. Windows already open
# at launch are recorded as seen, not logged -- only NEW ones are evidence.
$initial = [CW.Win]::VisibleWindows()
$initial | ForEach-Object { $seen["$($_.Hwnd)"] = 1 }
Write-Sighting @(("{0} started pid={1} visible-windows-at-start={2}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $PID, $initial.Count))

do {
  $new = @([CW.Win]::VisibleWindows() | Where-Object { -not $seen.ContainsKey("$($_.Hwnd)") })
  foreach ($s in $new) { $seen["$($s.Hwnd)"] = 1 }
  # Cheap owner-name filter before any WMI: Process.GetProcessById is a handle open, no scan.
  $hits = @($new | Where-Object {
    $pn = $pidName["$($_.Pid)"]
    if (-not $pn) { $pn = ([System.Diagnostics.Process]::GetProcessById($_.Pid)).ProcessName; if ($pn) { $pidName["$($_.Pid)"] = $pn } }
    $pn -and ($pn -match $ownerRe)
  })
  if ($hits.Count -gt 0) {
    $all = Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, CommandLine
    $byId = $all | Group-Object ProcessId -AsHashTable -AsString
    $conByClient = @{}
    $all | Where-Object Name -eq 'conhost.exe' | ForEach-Object { $conByClient["$($_.ParentProcessId)"] = $_ }
    foreach ($s in $hits) {
      # Not a console: tooltips (class MicrosoftWindowsTooltip, ~35x19) from a taskbar hover
      # over a Git Bash window were logged as sightings and relayed as "Claude-spawned"
      # (2026-09-18). Anything under 100x40 cannot be a terminal either.
      # Chrome_WidgetWin_1 is a Chromium/Electron GUI window and can never be a console.
      # $ownerRe matches the bare name 'claude', so the Claude DESKTOP app (Claude.exe under
      # WindowsApps) was logged and relayed as a Claude-spawned console flash (2026-09-21, from
      # opening a .pptx). Its chain is OpenWith.exe <- svchost, so neither the explorer/mintty
      # skip nor the size floor caught it.
      if ($s.Cls -eq 'MicrosoftWindowsTooltip' -or $s.Cls -eq 'Chrome_WidgetWin_1' -or $s.W -lt 100 -or $s.H -lt 40) { continue }
      $me = $byId["$($s.Pid)"]
      $chain = Get-Chain $s.Pid $byId
      # A user-launched shell: explorer.exe/mintty anywhere in the ancestry and no claude/node/
      # wscript above it (mintty <- git-bash <- explorer, logged 2026-09-18). The direct-parent
      # test alone let that through one level down.
      $chainTxt = ($chain -join ' ')
      $skip = ($chainTxt -match '<- (explorer|mintty)\.exe\[' -and $chainTxt -notmatch '<- (claude|node|wscript)(\.exe)?\[')
      if ($skip -and -not $SelfTest) { continue }
      $con = if ($me -and $me.Name -eq 'conhost.exe') { $me } else { $conByClient["$($s.Pid)"] }
      $kind = if (-not $con) { 'none' } elseif ("$($con.CommandLine)" -match 'headless') { 'headless' } else { 'classic' }
      $cl = ("$($me.CommandLine)" -replace '\s+', ' ')
      if ($cl.Length -gt 200) { $cl = $cl.Substring(0, 200) + '...' }
      $name = if ($me) { $me.Name } else { $pidName["$($s.Pid)"] + '.exe (gone)' }
      $tag = if ($skip) { ' [user-shell, skipped]' } else { '' }
      $head = "{0} {1}[{2}] title='{3}' class={4} rect={5}x{6} console={7}{8} cmd={9}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $name, $s.Pid, $s.Title, $s.Cls, $s.W, $s.H, $kind, $tag, $cl
      Write-Sighting (@($head) + $chain)
    }
  }
  $tick++
  if ($SelfTest -or ($tick % 20) -eq 0) { Watch-SenseIR }
  if ($SelfTest -or ($tick % 240) -eq 0) { Watch-EngineCpu }
  if ($SelfTest) { Write-Output ("selftest ok: {0} visible window(s) enumerated at start, {1} new owned by a watched process this tick; SenseIR running now: {2}" -f $initial.Count, $hits.Count, $irSeen.Count); exit 0 }
  Start-Sleep -Milliseconds 250
} while ($true)
