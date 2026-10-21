# Records Defender's own performance trace for 120 s DURING a slow spell and writes a report
# plus one summary line. <harnessEpicKey>, 2026-10-15.
#
# RUNS ELEVATED as scheduled task AMA-Harness-Defender-Hot-Record -- on demand, no trigger,
# registered ONCE by the user from an elevated PowerShell (scripts/register-defender-hot-record.ps1,
# which copies THIS file to an admin-only folder: the task executes that copy, never the repo's).
# Started by hooks/defender-hot-trigger.sh (dispatch.sh: one bash-start sample >= 700 ms or two of
# the last three >= 400 ms) and by scripts/console-window-watch.ps1 (MsMpEng above one core two
# minutes running).
#
# WHY: the slow spells (12 Oct: 0.4-1.8 s process starts, every terminal crawling) are not
# steady-state scanning CPU -- quiet recordings showed 1-2% of a core -- and not SenseIR runs as
# a rule (two days of samples, no difference inside vs outside). Only a recording taken WHILE
# the engine is hot says what it is doing, nobody is at the keyboard in the right minute, and
# New-MpPerformanceRecording needs admin that hooks never have. A RunLevel-Highest task can be
# started by a limited process without a UAC prompt.
#
# WHAT EACH RUN ADDS (the question it serves: do per-file scan waits cause the spells?):
#  - window-average CPU of engine, sensor, investigation and the box, processor queue,
#    available memory and disk queue (typeperf, 5 s) -- the recording itself sees scans only;
#  - ms per scan, overall and for the top programs;
#  - whether the dispatcher's per-minute file probe (scratch\hook-run\scnprobe.in) was scanned
#    in the window: its file-read timing means nothing until a run shows it is;
#  - <stamp>.mplog.txt: Defender's own diagnostic log for the window, SANITISED because the
#    output folder grants Users read -- only Defender's event lines (scheduled task launched,
#    engine update, ScanOnUpdate, post-update and other scan start/complete lines), the
#    per-program wait statistics without file paths, and lowfi checks as an image name only
#    (a command line can carry tokens). Proven on 2026-10-15's extract: the 14:41 sweep was the
#    60 s "postsignatureupdatescan" that follows every full signature update.
#
# THREAT MODEL -- this is administrator code that any process running as the user can start:
#  - It runs from an admin-only folder (%ProgramData%\AMA-Harness\bin, explicit ACL), so no user
#    process can change it; the task's own security descriptor lets Users start it but not modify
#    it (registration script).
#  - PATH and PSModulePath are reset to system directories FIRST: the user's
#    Documents\WindowsPowerShell\Modules is first on the default PSModulePath, so a planted module
#    named ConfigDefenderPerformance would otherwise auto-load as administrator; the Defender
#    module resolves wpr.exe through Get-Command (PATH), so -WPRPath pins it too. -NoProfile.
#  - It reads NOTHING user-writable (no marker, no harness-state) and writes only under -OutDir,
#    which registration created admin-only (Users: read); a junction planted in a user-writable
#    output dir would turn the prune below into an arbitrary delete as administrator, so a
#    reparse point is refused and the dir is never created here.
#  - Its own cooldown (newest .etl < 30 min) bounds a start-spam; after -MaxRecordings runs it
#    deletes the task (temporary by design -- re-register to continue).
# Output: <OutDir>\<stamp>.etl + .report.txt + .cpu.csv + .mplog.txt (last 5 recordings kept),
# one line per run in <OutDir>\defender-hot.log, relayed once by on-prompt.sh
# (hooks/defender-hot-check.sh).
# Test seam (non-elevated, no recording): -MpLogTestFile <MPLog-format file> -WindowStart
# <local time> -WindowEnd <local time> -ExtractOut <file> runs only the sanitiser and exits.
param(
  [string]$OutDir = (Join-Path $env:ProgramData 'AMA-Harness\defender-hot'),
  [int]$Seconds = 120,
  [int]$MaxRecordings = 3,
  [string]$MpLogTestFile = '',
  [datetime]$WindowStart = [datetime]::MinValue,
  [datetime]$WindowEnd = [datetime]::MinValue,
  [string]$ExtractOut = ''
)
$sys = Join-Path $env:windir 'System32'
$env:PATH = "$sys;$env:windir;$sys\WindowsPowerShell\v1.0"
$env:PSModulePath = "$sys\WindowsPowerShell\v1.0\Modules"
$ErrorActionPreference = 'Stop'

function Get-Leaf([string]$p) { $p = $p.Trim(); $i = $p.LastIndexOf('\'); if ($i -ge 0) { $p.Substring($i + 1) } else { $p } }

# Sanitised MPLog extract for [From, To] (local times; MPLog stamps are UTC, 23 chars + space).
# Returns the kept lines and writes them to $OutFile. Also appends the most recent per-program
# statistics block written before To, which covers the period leading up to the window.
function Save-MpLogExtract([string[]]$Files, [datetime]$From, [datetime]$To, [string]$OutFile) {
  $fU = $From.ToUniversalTime(); $tU = $To.ToUniversalTime()
  $fs = $fU.ToString('yyyy-MM-ddTHH:mm:ss'); $ts = $tU.ToString('yyyy-MM-ddTHH:mm:ss')
  $mins = New-Object System.Collections.Generic.List[string]
  for ($m = $fU.AddSeconds(-$fU.Second); $m -le $tU; $m = $m.AddMinutes(1)) { $mins.Add([regex]::Escape($m.ToString('yyyy-MM-ddTHH:mm'))) }
  $pat = '^(' + ($mins -join '|') + ')'
  $keep = New-Object System.Collections.Generic.List[string]
  $conv = {
    param([string]$line)
    if ($line.Length -lt 25) { return $null }
    $st = $line.Substring(0, 23); $rest = $line.Substring(24)
    if ($rest -match '^ProcessImageName: ([^,]+), Pid: \d+, TotalTime: (\d+), Count: (\d+),.*EstimatedImpact: (\d+)%') {
      return ('{0} stats {1} TotalTime={2}ms Count={3} Impact={4}%' -f $st, $Matches[1], $Matches[2], $Matches[3], $Matches[4])
    }
    if ($rest -match 'command line reported as lowfi: ([^(]+)\(') { return ('{0} lowfi-command {1}' -f $st, (Get-Leaf $Matches[1])) }
    if ($rest -match 'Engine VFZ lofi/sample/expensive: (.+?)\.? status=') { return ('{0} lowfi-file {1}' -f $st, (Get-Leaf $Matches[1])) }
    if ($rest -match '^(Task\(|\[Engine\] New active engine|\[Update\] Performing ScanOnUpdate)') { return ('{0} {1}' -f $st, $rest) }
    if ($rest -match '^UpdateEngine start') { return ('{0} UpdateEngine start' -f $st) }
    if ($rest -notmatch '\\' -and $rest -match '(?i)\bscan\b.*\b(started|completed|cancelled|stopped|aborted)\b') { return ('{0} {1}' -f $st, $rest) }
    return $null
  }
  foreach ($hit in @(Select-String -LiteralPath $Files -Pattern $pat)) {
    $s19 = $hit.Line.Substring(0, [Math]::Min(19, $hit.Line.Length))
    if ($s19 -lt $fs -or $s19 -gt $ts) { continue }
    $k = & $conv $hit.Line; if ($k) { $keep.Add($k) }
  }
  # The latest statistics block written at or before the window end (blocks share one stamp).
  $blocks = @(Select-String -LiteralPath $Files -SimpleMatch 'ProcessImageName:' | Where-Object { $_.Line.Substring(0, 19) -le $ts })
  if ($blocks.Count -gt 0) {
    $last = ($blocks | ForEach-Object { $_.Line.Substring(0, 19) } | Sort-Object | Select-Object -Last 1)
    if ($last -lt $fs) {
      $keep.Add("--- latest per-program statistics before the window, written $last UTC (cumulative since Defender's previous write)")
      foreach ($b in ($blocks | Where-Object { $_.Line.StartsWith($last) })) { $k = & $conv $b.Line; if ($k) { $keep.Add($k) } }
    }
  }
  $keep | Set-Content -LiteralPath $OutFile -Encoding UTF8
  return $keep
}

if ($MpLogTestFile) {
  $k = Save-MpLogExtract @($MpLogTestFile) $WindowStart $WindowEnd $ExtractOut
  'extract: {0} line(s) -> {1}' -f @($k).Count, $ExtractOut
  exit 0
}

Import-Module "$sys\WindowsPowerShell\v1.0\Modules\ConfigDefenderPerformance\ConfigDefenderPerformance.psd1"
$task = 'AMA-Harness-Defender-Hot-Record'
if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) { exit 1 }
if ((Get-Item -LiteralPath $OutDir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { exit 1 }
$log = Join-Path $OutDir 'defender-hot.log'
$stamp = Get-Date -Format 'yyyy-MM-ddTHH-mm-ss'
$newest = Get-ChildItem -LiteralPath $OutDir -Filter '*.etl' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($newest -and (((Get-Date) - $newest.LastWriteTime).TotalMinutes -lt 30)) { exit 0 }
$lock = Join-Path $OutDir '.recording'
if ((Test-Path -LiteralPath $lock) -and (((Get-Date) - (Get-Item -LiteralPath $lock).LastWriteTime).TotalMinutes -lt 10)) { exit 0 }
Set-Content -LiteralPath $lock -Value $stamp

function Pct($samples, $name) {
  $s = @($samples | Where-Object { $_.Path -like "*($name)*" }) | Select-Object -First 1
  if ($s) { [math]::Round($s.CookedValue) } else { -1 }
}

try {
  $began = Get-Date
  # Context first: what the engine, the sensor and the whole box are doing as the recording starts.
  $c = $null
  try { $c = (Get-Counter '\Process(MsMpEng)\% Processor Time', '\Process(MsSense)\% Processor Time', '\Processor(_Total)\% Processor Time' -SampleInterval 2 -MaxSamples 1).CounterSamples } catch {}
  $eng = Pct $c 'msmpeng'; $sense = Pct $c 'mssense'; $total = Pct $c '_total'
  $ir = @([System.Diagnostics.Process]::GetProcessesByName('SenseIR')).Count
  $etl = Join-Path $OutDir "$stamp.etl"
  # CPU over the WHOLE window: the recording itemises antivirus SCANS only -- engine time outside
  # scans and the sensor are invisible to it -- so typeperf samples alongside every 5 s and the
  # summary carries the averages. System32 exe, fixed arguments, admin-only output; shares this
  # process's hidden console (-NoNewWindow).
  $csv = Join-Path $OutDir "$stamp.cpu.csv"
  $tp = $null
  try {
    $tp = Start-Process -FilePath "$sys\typeperf.exe" -NoNewWindow -PassThru -ArgumentList @(
      '"\Process(MsMpEng)\% Processor Time"', '"\Process(MsSense)\% Processor Time"',
      '"\Process(SenseIR)\% Processor Time"', '"\Processor(_Total)\% Processor Time"',
      '"\System\Processor Queue Length"', '"\Memory\Available MBytes"', '"\PhysicalDisk(_Total)\Avg. Disk Queue Length"',
      '-si', '5', '-sc', [string][math]::Ceiling($Seconds / 5), '-f', 'CSV', '-y', '-o', "`"$csv`"")
  } catch { $tp = $null }
  New-MpPerformanceRecording -RecordTo $etl -Seconds $Seconds -WPRPath "$sys\wpr.exe" | Out-Null
  $ended = Get-Date
  $avg = 'n/a'
  try {
    if ($tp) { $tp.WaitForExit(30000) | Out-Null }
    $rows = @(Import-Csv -LiteralPath $csv)
    $cols = @($rows[0].PSObject.Properties.Name | Where-Object { $_ -notlike '(PDH-CSV*' })
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $avg = @(foreach ($col in $cols) {
      $vals = @(foreach ($row in $rows) { $t = "$($row.$col)" -replace ',', '.'; $d = 0.0; if ([double]::TryParse($t, [Globalization.NumberStyles]::Float, $inv, [ref]$d)) { $d } })
      $name = if ($col -match 'Processor Queue Length') { 'queue' } elseif ($col -match 'Available MBytes') { 'availMB' } elseif ($col -match 'Disk Queue Length') { 'diskQ' } elseif ($col -match 'Process\(([^)]+)\)') { $Matches[1] } elseif ($col -match '_Total') { 'total' } else { $col }
      $unit = if ($name -in 'queue', 'availMB', 'diskQ') { '' } else { '%' }
      if ($vals.Count -gt 0) { '{0} {1:N0}{2}' -f $name, (($vals | Measure-Object -Average).Average), $unit } else { '{0} n/a' -f $name }
    }) -join ' '
  } catch { $avg = 'n/a' }
  $r = Get-MpPerformanceReport -Path $etl -TopScans 20 -TopProcesses 15 -TopFiles 15 -TopExtensions 10
  $report = Join-Path $OutDir "$stamp.report.txt"
  $r | Out-String -Width 170 | Set-Content -LiteralPath $report
  # TotalDuration is a TimeSpan. Every scan carries an extension (possibly empty), so the
  # extensions table sums to the whole scan time and count; the processes table is only the top N.
  $scanMs = 0; $scanN = 0
  foreach ($e in @($r.TopExtensions)) { $scanMs += $e.TotalDuration.TotalMilliseconds; $scanN += $e.Count }
  # An EMPTY ProcessPath = scans no program asked for: the engine's own work (on-demand items,
  # process and driver scans, signature-triggered memory scans). Split-Path throws on it.
  $top = @($r.TopProcesses | Select-Object -First 3 | ForEach-Object {
    $p = "$($_.ProcessPath)"; $n = if ($p) { Get-Leaf $p } else { "(engine's own)" }
    '{0} {1:N0}ms/{2} ({3:N1} ms each)' -f $n, $_.TotalDuration.TotalMilliseconds, $_.Count, ($_.TotalDuration.TotalMilliseconds / [Math]::Max(1, $_.Count))
  }) -join ', '
  # Was the dispatcher's file probe scanned in this window? (8.3-safe name: same in both forms.)
  $probe = 'probe not seen'
  try {
    $pf = @((Get-MpPerformanceReport -Path $etl -TopFiles 5000).TopFiles | Where-Object { "$($_.Path)" -like '*\hook-run\scnprobe.in' })
    if ($pf.Count -gt 0) { $probe = 'probe scanned {0}x, {1:N1} ms' -f ($pf | Measure-Object -Property Count -Sum).Sum, (($pf | ForEach-Object { $_.TotalDuration.TotalMilliseconds }) | Measure-Object -Sum).Sum }
  } catch { $probe = 'probe check failed' }
  # Defender's own diagnostic log for the window, sanitised (header). From 5 min before the
  # recording, since the trigger fires after the spell began.
  $mplog = 'mplog n/a'
  try {
    $mpf = @(Get-ChildItem -LiteralPath 'C:\ProgramData\Microsoft\Windows Defender\Support' -Filter 'MPLog-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 2 | ForEach-Object { $_.FullName })
    $mpOut = Join-Path $OutDir "$stamp.mplog.txt"
    $kept = @(Save-MpLogExtract $mpf $began.AddMinutes(-5) $ended.AddMinutes(1) $mpOut)
    $post = if (@($kept | Where-Object { $_ -match 'postsignatureupdatescan\) started' }).Count -gt 0) { 'post-update scan in window' } else { 'no post-update scan' }
    $mplog = 'mplog {0} line(s), {1}' -f $kept.Count, $post
  } catch { $mplog = 'mplog extract failed: ' + $_.Exception.Message }
  $line = '{0} recorded {1}s: scans {2:N0} ms over {3} = {4:N1} ms each, {5:N1}% of a core; at start MsMpEng {6}% MsSense {7}% total {8}% SenseIR={9}; window avg: {10}; top: {11}; {12}; {13}; report {14}' -f `
    (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $Seconds, $scanMs, $scanN, ($scanMs / [Math]::Max(1, $scanN)), ($scanMs / ($Seconds * 10)), $eng, $sense, $total, $ir, $avg, $top, $probe, $mplog, $report
  Add-Content -LiteralPath $log -Value $line -Encoding UTF8
  # Temporary by design: after $MaxRecordings the task removes itself.
  $countFile = Join-Path $OutDir 'count.txt'
  $n = 0
  if (Test-Path -LiteralPath $countFile) { [int]::TryParse("$(Get-Content -LiteralPath $countFile -First 1)", [ref]$n) | Out-Null }
  $n++
  Set-Content -LiteralPath $countFile -Value $n
  if ($n -ge $MaxRecordings) {
    & "$sys\schtasks.exe" /delete /tn $task /f | Out-Null
    Add-Content -LiteralPath $log -Value ('{0} task {1} retired after {2} recording(s) -- re-register with scripts/register-defender-hot-record.ps1 (elevated) to continue' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $task, $n) -Encoding UTF8
  }
} catch {
  Add-Content -LiteralPath $log -Value ('{0} FAILED: {1}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $_.Exception.Message) -Encoding UTF8
} finally {
  Remove-Item -LiteralPath $lock -ErrorAction SilentlyContinue
  Get-ChildItem -LiteralPath $OutDir -Filter '*.etl' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip 5 | ForEach-Object { Remove-Item -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
}
