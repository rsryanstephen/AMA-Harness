# Reaps processes Claude sessions orphan. <harnessEpicKey>. Three kinds, each with its own
# guards; anything else is never touched.
#
# 1. conhost.exe whose creating process is gone -- console hosts orphaned when a hook
#    bash.exe is taskkill'd mid-run. Each holds a console object and 5-30 MB; 45
#    accumulated in one afternoon (session 9149fa95, 2026-09-16).
#    Guards: parent PID absent from the live list AT KILL TIME, re-checked per target (PIDs
#    recycle); CreationDate older than $MinAgeMinutes (a just-spawned conhost briefly reads
#    as parentless). Verified 2026-09-21: killed 7; all mintty, claude CLIs and interactive
#    login shells still alive afterwards.
#
# 2. Dev servers (`ng serve`, `python -m http.server`) whose launch chain is DEAD -- added
#    2026-10-12 after a 3 GB `ng serve` from another session sat on 4210 while the box
#    paged. A Claude background task's wrapper bash dies on TaskStop and the node child lives
#    on (2026-09-14). In-session, dev-server-teardown-reminder.sh kills idle servers it
#    recorded; this is the backstop for ones it never saw, or when no session is running.
#    "Chain dead" = walking up parents hits a missing PID BEFORE reaching a live host the
#    user owns (claude, mintty, Code, WindowsTerminal, explorer, cmd/pwsh windows under
#    those, JetBrains). A server the user started from a terminal or editor always reaches
#    one, so it is never a candidate. Also: older than $ServerMinutes, no ESTABLISHED TCP
#    connection on any port it OR A DESCENDANT listens on (a tab open on it = in use; the npx
#    wrapper owns no socket), no fresh usage marker and no unexpired devserver-hold.sh hold
#    for those ports.
#
# 3. Playwright headless Chromium (path under ms-playwright) whose chain is dead and older
#    than $BrowserMinutes -- a verify script killed mid-run leaves the browser behind.
#    Only the browser root is killed (renderers are its children; //T takes them).
#
# Kills use taskkill //T (whole tree). -DryRun prints candidates and kills nothing.
# Scheduled as AMA-Harness-Orphan-Conhost-Reap (every 15 min, hidden via
# run-hidden-generic.vbs; name kept from when it reaped conhost only).
# Log: harness-state/logs/orphan-conhost-reap.log -- one line per run that killed >0.
param(
  [int]$MinAgeMinutes = 2,
  [int]$ServerMinutes = 20,
  [int]$BrowserMinutes = 15,
  [switch]$DryRun
)

$snap  = Get-CimInstance Win32_Process
$byId  = @{}; foreach ($p in $snap) { $byId[[int]$p.ProcessId] = $p }
$now   = Get-Date

# Hosts that mean "a person or a live Claude session owns this chain".
$hostRe = '^(claude|mintty|Code|WindowsTerminal|explorer|idea64|rider64|devenv|OpenConsole)\.exe$'
function Test-ChainDead([int]$procId) {
  $cur = $byId[$procId]; $n = 0
  while ($cur -and $n -lt 15) {
    if ($cur.Name -match $hostRe) { return $false }
    $parent = $byId[[int]$cur.ParentProcessId]
    if (-not $parent) { return $true }
    # A parent created AFTER the child is a recycled PID, i.e. the real parent is gone.
    if ($parent.CreationDate -gt $cur.CreationDate) { return $true }
    $cur = $parent; $n++
  }
  return $false
}

$results = New-Object System.Collections.Generic.List[string]
$killed = 0; $mb = 0
function Stop-Tree($p, [string]$kind) {
  $script:results.Add(("{0} pid={1} {2}MB {3}" -f $kind, $p.ProcessId, [int]($p.WorkingSetSize/1MB), (("$($p.CommandLine)" -replace '\s+',' ').Substring(0, [Math]::Min(120, "$($p.CommandLine)".Length)))))
  if ($DryRun) { return }
  & taskkill.exe /PID $p.ProcessId /T /F *> $null
  if ($LASTEXITCODE -eq 0) { $script:killed++; $script:mb += $p.WorkingSetSize / 1MB }
}

# 1. conhost
$live   = $snap.ProcessId
$cutoff = $now.AddMinutes(-$MinAgeMinutes)
foreach ($t in $snap | Where-Object { $_.Name -eq 'conhost.exe' -and ($live -notcontains $_.ParentProcessId) -and $_.CreationDate -lt $cutoff }) {
  if (Get-Process -Id $t.ParentProcessId -ErrorAction SilentlyContinue) { continue }
  if ($DryRun) { $results.Add("conhost pid=$($t.ProcessId)"); continue }
  try { Stop-Process -Id $t.ProcessId -Force -ErrorAction Stop; $killed++; $mb += $t.WorkingSetSize / 1MB } catch {}
}

# 2. dev servers
# A Claude background task's shell can read as parentless while the task is still live, so a
# dead chain alone does not mean unused. A port whose marker (written by
# dev-server-teardown-reminder.sh, mtime = last seen in use) is fresher than $ServerMinutes
# belongs to a server a session is still using -- skip it, same "in use" rule as the hook.
$markerDir = Join-Path $env:USERPROFILE '.claude\harness-state\sessions\.usage-state'
$freshPorts = @(Get-ChildItem -Path $markerDir -Filter 'devserver-*' -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -notmatch '^devserver-(probed|nudged|hold)-' -and $_.Name -match '-(\d+)$' -and $_.LastWriteTime -gt $now.AddMinutes(-$ServerMinutes) } |
  ForEach-Object { [int]($_.Name -replace '^.*-(\d+)$', '$1') })
# devserver-hold-<port> (scripts/devserver-hold.sh) holds a server for the user's sign-off; its
# content is the expiry epoch -- the mtime is only when the hold was set.
$nowEpoch = [DateTimeOffset]::Now.ToUnixTimeSeconds()
$heldPorts = @(Get-ChildItem -Path $markerDir -Filter 'devserver-hold-*' -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '-(\d+)$' -and [long]("0" + ((Get-Content $_.FullName -TotalCount 1) -replace '\D', '')) -gt $nowEpoch } |
  ForEach-Object { [int]($_.Name -replace '^.*-(\d+)$', '$1') })
$tcp = Get-NetTCPConnection -ErrorAction SilentlyContinue
# Listening ports of a process AND its descendants: `npx ng serve` matches $serverRe on the npx
# wrapper, but the ng child owns the socket -- judging the wrapper alone saw no ports, skipped both
# in-use guards and taskkill //T'd a server in active use (2026-10-16, 08:13 and 12:28).
function Get-TreeListenPorts([int]$rootId) {
  $ids = @($rootId); $frontier = @($rootId); $n = 0
  while ($frontier.Count -gt 0 -and $n -lt 10) {
    $frontier = @($snap | Where-Object { $frontier -contains [int]$_.ParentProcessId -and $ids -notcontains [int]$_.ProcessId } | ForEach-Object { [int]$_.ProcessId })
    $ids += $frontier; $n++
  }
  @($tcp | Where-Object { $ids -contains $_.OwningProcess -and $_.State -eq 'Listen' } | ForEach-Object LocalPort | Sort-Object -Unique)
}
$serverRe = '(^|[\\/"\s])ng(\.js|\.cmd)?"?\s+serve(\s|$)|\s-m\s+http\.server(\s|$)'
foreach ($s in $snap | Where-Object { $_.Name -match '^(node|python|python3|py)\.exe$' -and "$($_.CommandLine)" -match $serverRe -and $_.CreationDate -lt $now.AddMinutes(-$ServerMinutes) }) {
  if (-not (Test-ChainDead ([int]$s.ProcessId))) { continue }
  $ports = Get-TreeListenPorts ([int]$s.ProcessId)
  if (@($ports | Where-Object { $freshPorts -contains $_ -or $heldPorts -contains $_ }).Count -gt 0) { continue }
  if ($ports.Count -gt 0 -and ($tcp | Where-Object { $_.State -eq 'Established' -and (($ports -contains $_.LocalPort) -or ($ports -contains $_.RemotePort)) })) { continue }
  Stop-Tree $s 'devserver'
}

# 3. Playwright headless Chromium (browser root only)
foreach ($c in $snap | Where-Object { $_.Name -match '^(chrome|chrome-headless-shell|headless_shell)\.exe$' -and "$($_.ExecutablePath)" -match 'ms-playwright' -and $_.CreationDate -lt $now.AddMinutes(-$BrowserMinutes) }) {
  $parent = $byId[[int]$c.ParentProcessId]
  if ($parent -and "$($parent.ExecutablePath)" -match 'ms-playwright') { continue }   # a renderer, not the root
  if (-not (Test-ChainDead ([int]$c.ProcessId))) { continue }
  Stop-Tree $c 'playwright-chromium'
}

if ($killed -gt 0) {
  $logDir = Join-Path $env:USERPROFILE '.claude\harness-state\logs'
  if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force $logDir | Out-Null }
  $detail = ($results | Where-Object { $_ -notmatch '^conhost' }) -join '; '
  "{0:yyyy-MM-ddTHH:mm:ss} killed={1} mb={2} conhost-total={3}{4}" -f $now, $killed, [int]$mb, @($snap | Where-Object Name -eq 'conhost.exe').Count, $(if ($detail) { " $detail" } else { '' }) |
    Add-Content (Join-Path $logDir 'orphan-conhost-reap.log')
}
if ($DryRun) { "dry-run candidates: {0}" -f $results.Count; $results }
"killed=$killed mb=$([int]$mb)"
