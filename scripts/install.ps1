#Requires -Version 7.0
<#
  Bootstraps a fresh (or already-migrated) ~/.claude to use THIS cloned harness repo.
  Safe to re-run: already-correct links are left alone, an existing settings.json is
  merged (never replaced), and any real pre-existing file at a link target is backed up
  (timestamped) before being replaced -- nothing is ever silently clobbered.

  Two jobs:
    1. Link skills/, hooks/, memory/, Chat files/ (directory junctions -- no admin
       needed) and CLAUDE.md, harness-config.json, README.md, AGENTS.md,
       harness-config.example.json, .harness-local.json.example, harness-gaps.md,
       sessions.txt, sessions.md, session-names.txt (symlinks -- need Developer Mode
       or an elevated shell) from ~/.claude into this repo. sessions.txt/sessions.md
       are real, frequently-rewritten runtime files, not static config -- every
       script that rewrites them writes THROUGH the symlink (see
       hooks/lib-sessions-lock.sh's sessions_write_through), never replaces it, so
       this is safe to link the same way as the static files above.
       session-names.txt is a plain append-only log (superseded session names, see
       rename-topic.sh), no lock needed. Chat files/, sessions.txt, sessions.md,
       session-names.txt are all gitignored (per-machine runtime state) -- unlike
       every other linked path here, a fresh clone won't have them on disk yet, so
       this script creates them (empty dir/files) before linking instead of treating
       a missing source as a broken clone.
    2. Merge settings.template.json (this repo's shareable hooks/permissions) into the
       adopter's REAL ~/.claude/settings.json. This file can't be a symlink like the
       other four -- it must hold both shared content (hooks wiring, permission rules)
       and per-adopter personal content (model/theme/additionalDirectories/etc) in the
       SAME physical file, since Claude Code has no separate "personal, applies-to-every-
       session" settings layer to split them into (confirmed against the actual settings
       docs -- the only project-local override file is scoped to one repo, not global).

  Usage: pwsh -File scripts\install.ps1
  Param -ClaudeDir exists for testing against a throwaway directory; omit it for real use.
#>
param(
  [string]$ClaudeDir = (Join-Path $env:USERPROFILE '.claude')
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path -LiteralPath $ClaudeDir)) {
  New-Item -ItemType Directory -Path $ClaudeDir | Out-Null
  Write-Host "[create]  $ClaudeDir" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Job 0: harness-state/ + scratch/ layout (PROJ-15342) -- idempotent, so a
# fresh clone's first hook run never writes into a directory that doesn't exist yet
# (every write in this harness fails soft, so a missing parent silently drops the
# write instead of erroring). hooks/lib-claude-paths.sh's hstate()/hscratch() also
# mkdir -p their own target on the bash side; this covers the case nothing else does
# -- a PowerShell writer (e.g. run-fleet-health-hidden.ps1) with no bash lib to call.
# ---------------------------------------------------------------------------

$stateSubdirs = 'notices', 'standup', 'sessions', 'tickets', 'harness', 'settings-backups', 'logs'
foreach ($d in $stateSubdirs) {
  $p = Join-Path (Join-Path $ClaudeDir 'harness-state') $d
  if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}
$scratchSubdirs = 'standup', 'graylog', 'notes'
foreach ($d in $scratchSubdirs) {
  $p = Join-Path (Join-Path $ClaudeDir 'scratch') $d
  if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

# ---------------------------------------------------------------------------
# Job 1: link skills/hooks/CLAUDE.md/harness-config.json
# ---------------------------------------------------------------------------

function Test-AlreadyLinked {
  param([string]$LinkPath, [string]$WantTarget)
  $item = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
  if (-not $item -or -not $item.LinkType) { return $false }
  $cur = $item.Target
  if ($cur -is [array]) { $cur = $cur[0] }        # defensive: some hosts report an array
  if (-not $cur) { return $false }
  $cur = $cur -replace '^\\\?\?\\', ''            # defensive: strip an NT \??\ prefix if present
  return ($cur.TrimEnd('\') -ieq $WantTarget.TrimEnd('\'))
}

$targets = @(
  @{ Name = 'skills';              Type = 'Junction' }
  @{ Name = 'hooks';                Type = 'Junction' }
  # Linked for the same reason as hooks: README.md and several skills hand out
  # `~/.claude/scripts/<name>.sh` commands to copy-paste, and without this junction every
  # one of them failed with "No such file or directory" (found 2026-09-01, session e3d7edc2 --
  # 3 occurrences in README alone). `scripts` is allow-listed in claude-dir-clutter-gate.sh's
  # allowed_dir; the two must stay in step or that gate denies its own installer's target.
  @{ Name = 'scripts';              Type = 'Junction' }
  @{ Name = 'memory';               Type = 'Junction' }
  @{ Name = 'Chat files';           Type = 'Junction';     CreateIfMissing = $true }
  @{ Name = 'CLAUDE.md';            Type = 'SymbolicLink' }
  @{ Name = 'harness-config.json';  Type = 'SymbolicLink' }
  @{ Name = 'README.md';            Type = 'SymbolicLink' }
  @{ Name = 'AGENTS.md';            Type = 'SymbolicLink' }
  @{ Name = 'harness-config.example.json'; Type = 'SymbolicLink' }
  @{ Name = '.harness-local.json.example'; Type = 'SymbolicLink' }
  @{ Name = 'harness-gaps.md';      Type = 'SymbolicLink' }
  @{ Name = 'sessions.txt';         Type = 'SymbolicLink'; CreateIfMissing = $true }
  @{ Name = 'sessions.md';          Type = 'SymbolicLink'; CreateIfMissing = $true }
  @{ Name = 'session-names.txt';    Type = 'SymbolicLink'; CreateIfMissing = $true }
)

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($t in $targets) {
  $src = Join-Path $repoRoot $t.Name
  $dst = Join-Path $ClaudeDir $t.Name

  if (-not (Test-Path -LiteralPath $src)) {
    # Chat files/, sessions.txt, sessions.md are gitignored (per-machine runtime
    # state, not shared repo content -- see .gitignore's own comment) -- a fresh
    # clone genuinely won't have them on disk, unlike every other entry here, which
    # IS committed and must already exist. Create rather than throw for exactly
    # these; anything else missing really is a broken/incomplete clone.
    if ($t.Name -eq 'harness-config.json') {
      # Untracked (real values live in the org's "Claude Harness" Octopus library
      # variable set) -- a fresh clone won't have it. Seed from the example so every
      # hook's jq read sees valid JSON, then /harness-setup fetches or fills values.
      Copy-Item -LiteralPath (Join-Path $repoRoot 'harness-config.example.json') -Destination $src
      Write-Host "[create]  $($t.Name) (seeded from harness-config.example.json -- run /harness-setup)" -ForegroundColor Green
    } elseif ($t.CreateIfMissing) {
      if ($t.Type -eq 'Junction') {
        New-Item -ItemType Directory -Path $src | Out-Null
      } else {
        New-Item -ItemType File -Path $src | Out-Null
      }
      Write-Host "[create]  $($t.Name) (gitignored runtime state, didn't exist yet)" -ForegroundColor Green
    } else {
      throw "Source missing in repo, can't link: $src"
    }
  }

  if (Test-AlreadyLinked -LinkPath $dst -WantTarget $src) {
    Write-Host "[ok]      $($t.Name) already linked to this repo" -ForegroundColor DarkGray
    continue
  }

  if ($t.Name -eq 'harness-config.json' -and (Test-Path -LiteralPath $dst)) {
    # The live config is Octopus-synced, NOT git-synced -- the repo's checked-out copy is
    # routinely STALE. Backup-and-replace here silently downgraded the live config twice
    # (2026-08: dropped a concurrent session's azure block + ama.uiTesterName). A real file
    # whose content differs from the repo copy is newer until proven otherwise: refuse to
    # replace it, tell the user to reconcile via octopus-config-sync.sh first.
    $dstItem = Get-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
    if ($dstItem -and -not $dstItem.LinkType) {
      $same = $false
      try { $same = ((Get-FileHash -LiteralPath $dst).Hash -eq (Get-FileHash -LiteralPath $src).Hash) } catch {}
      if (-not $same) {
        Write-Host "[skip]    harness-config.json: real file at $dst differs from the repo copy -- NOT replaced (Octopus-synced config is usually newer than git). Reconcile first: bash scripts/octopus-config-sync.sh fetch (or push if the live file is the truth), then re-run this installer." -ForegroundColor Yellow
        continue
      }
    }
  }

  if (Test-Path -LiteralPath $dst) {
    # PROJ-15342: this backup used to land as a new top-level ~/.claude file
    # (e.g. README.md.backup-20260729-210900) -- exactly the clutter this harness now
    # gates against. Route it into harness-state/settings-backups/ instead.
    $backupName = "$($t.Name).backup-$stamp"
    $backupDir = Join-Path $ClaudeDir 'harness-state\settings-backups'
    if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
    Move-Item -LiteralPath $dst -Destination (Join-Path $backupDir $backupName)
    Write-Host "[backup]  $($t.Name) -> harness-state/settings-backups/$backupName (real content found, not overwritten)" -ForegroundColor Yellow
  }

  if ($t.Type -eq 'Junction') {
    New-Item -ItemType Junction -Path $dst -Value $src | Out-Null
    Write-Host "[link]    junction  $($t.Name)" -ForegroundColor Green
  } else {
    try {
      New-Item -ItemType SymbolicLink -Path $dst -Value $src -ErrorAction Stop | Out-Null
      Write-Host "[link]    symlink   $($t.Name)" -ForegroundColor Green
    } catch {
      Write-Host ""
      Write-Host "SYMLINK FAILED for $($t.Name) -- this needs Developer Mode or an elevated shell." -ForegroundColor Red
      Write-Host "Enable: Settings > Privacy & security > For developers > Developer Mode = On" -ForegroundColor Red
      Write-Host "Then re-run this exact command -- already-linked paths above will be skipped." -ForegroundColor Red
      throw
    }
  }
}

# ---------------------------------------------------------------------------
# Job 2: merge settings.template.json into the real ~/.claude/settings.json
# ---------------------------------------------------------------------------

function Merge-StringArray {
  param([object[]]$ExistingList, [object[]]$NewList)
  $seen = [System.Collections.Generic.HashSet[string]]::new()
  $merged = [System.Collections.Generic.List[string]]::new()
  foreach ($item in @($ExistingList)) { if ($item -and $seen.Add($item)) { $merged.Add($item) } }
  foreach ($item in @($NewList)) { if ($item -and $seen.Add($item)) { $merged.Add($item) } }
  return , $merged.ToArray()
}

function Merge-HooksSection {
  param([hashtable]$ExistingHooks, [hashtable]$TemplateHooks)
  if (-not $ExistingHooks) { $ExistingHooks = @{} }
  foreach ($eventName in $TemplateHooks.Keys) {
    $templateGroups = @($TemplateHooks[$eventName])
    if (-not $ExistingHooks.ContainsKey($eventName)) {
      $ExistingHooks[$eventName] = $templateGroups
      continue
    }
    $existingGroups = @($ExistingHooks[$eventName])
    $merged = [System.Collections.Generic.List[object]]::new()
    foreach ($g in $existingGroups) { $merged.Add($g) }
    foreach ($tg in $templateGroups) {
      # Match by `matcher`, not whole-group JSON equality -- confirmed real bug:
      # adding a second hook to an ALREADY-registered matcher (e.g. a new gate
      # alongside an existing one on the same createJiraIssue matcher) changed that
      # group's JSON, so the old exact-equality check never found it and appended a
      # duplicate top-level group instead of updating the existing one in place.
      $matcher = $tg['matcher']
      $matchIdx = -1
      for ($i = 0; $i -lt $merged.Count; $i++) {
        if ($merged[$i]['matcher'] -eq $matcher) { $matchIdx = $i; break }
      }
      if ($matchIdx -eq -1) {
        $merged.Add($tg)
        continue
      }
      # Same matcher already present -- union its hooks array, matched by `command`
      # (not whole-hook-object equality) so a hook whose statusMessage/timeout text
      # changed gets REPLACED in place instead of appended as a near-duplicate.
      $existingGroup = $merged[$matchIdx]
      $existingHooksList = [System.Collections.Generic.List[object]]::new()
      foreach ($h in @($existingGroup['hooks'])) { $existingHooksList.Add($h) }
      foreach ($h in @($tg['hooks'])) {
        $cmd = $h['command']
        $hookIdx = -1
        for ($j = 0; $j -lt $existingHooksList.Count; $j++) {
          if ($existingHooksList[$j]['command'] -eq $cmd) { $hookIdx = $j; break }
        }
        if ($hookIdx -eq -1) { $existingHooksList.Add($h) } else { $existingHooksList[$hookIdx] = $h }
      }
      $existingGroup['hooks'] = $existingHooksList.ToArray()
      $merged[$matchIdx] = $existingGroup
    }
    $ExistingHooks[$eventName] = $merged.ToArray()
  }
  return $ExistingHooks
}

function Merge-Settings {
  param([hashtable]$Existing, [hashtable]$Template, [string]$ClaudeDirPath)
  if (-not $Existing) { $Existing = @{} }

  if (-not $Existing.ContainsKey('$schema')) { $Existing['$schema'] = $Template['$schema'] }

  if (-not $Existing.ContainsKey('env')) { $Existing['env'] = @{} }
  foreach ($k in $Template['env'].Keys) {
    if (-not $Existing['env'].ContainsKey($k)) { $Existing['env'][$k] = $Template['env'][$k] }
  }

  if (-not $Existing.ContainsKey('permissions')) { $Existing['permissions'] = @{} }
  $existingPerms = $Existing['permissions']
  foreach ($listName in @('allow', 'deny')) {
    # NOTE: `$x = if (...) { A } else { B }` is a real PowerShell trap -- a single-element
    # array returned from either branch crosses the if/else pipeline boundary and silently
    # unwraps to a scalar (confirmed empirically while testing this script: a 1-element
    # additionalDirectories array became a bare string on a second run). Assign INSIDE each
    # branch instead of capturing the if/else block's own output, which sidesteps it.
    $existingList = @()
    if ($existingPerms.ContainsKey($listName)) { $existingList = $existingPerms[$listName] }
    $existingPerms[$listName] = Merge-StringArray -ExistingList $existingList -NewList $Template['permissions'][$listName]
  }
  # additionalDirectories is genuinely per-adopter (this file is real, not shared) --
  # just make sure THIS adopter's own ~/.claude is in there, never touch other entries.
  $existingDirs = @()
  if ($existingPerms.ContainsKey('additionalDirectories')) { $existingDirs = @($existingPerms['additionalDirectories']) }
  if ($existingDirs -notcontains $ClaudeDirPath) { $existingDirs = @($existingDirs) + @($ClaudeDirPath) }
  $existingPerms['additionalDirectories'] = @($existingDirs)

  if (-not $Existing.ContainsKey('hooks')) { $Existing['hooks'] = @{} }
  $Existing['hooks'] = Merge-HooksSection -ExistingHooks $Existing['hooks'] -TemplateHooks $Template['hooks']

  # statusLine was in the template from the start but never merged here -- an adopter with
  # a PRE-EXISTING settings.json silently never got the harness statusline (only a
  # first-time adopter, whose file is created from the template wholesale, ever saw it).
  # Set only when absent: an adopter who wrote their own statusline keeps it.
  if ($Template.ContainsKey('statusLine') -and -not $Existing.ContainsKey('statusLine')) {
    $Existing['statusLine'] = $Template['statusLine']
  }

  # autoMode.environment tells the auto-mode classifier which infrastructure is ours, so
  # routine AMA operations aren't read as external. Union like allow/deny -- an adopter's
  # own entries (their own bastion, their own bucket) survive a re-run. Keep "$defaults"
  # in the array or the built-in environment rules are DISCARDED wholesale.
  if ($Template.ContainsKey('autoMode')) {
    if (-not $Existing.ContainsKey('autoMode')) { $Existing['autoMode'] = @{} }
    foreach ($listName in @('environment', 'allow', 'soft_deny', 'hard_deny')) {
      if (-not $Template['autoMode'].ContainsKey($listName)) { continue }
      $existingList = @()
      if ($Existing['autoMode'].ContainsKey($listName)) { $existingList = $Existing['autoMode'][$listName] }
      $Existing['autoMode'][$listName] = Merge-StringArray -ExistingList $existingList -NewList $Template['autoMode'][$listName]
    }
  }

  return $Existing
}

$templatePath = Join-Path $repoRoot 'settings.template.json'
$settingsPath = Join-Path $ClaudeDir 'settings.json'
$template = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json -AsHashtable

if (Test-Path -LiteralPath $settingsPath) {
  $existing = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable
  # Snapshot BEFORE merging -- confirmed real bug: Merge-Settings mutates $Existing's
  # nested hashtables in place (PowerShell hashtables are reference types), so capturing
  # this snapshot AFTER the call compared $existing against itself post-mutation, always
  # equal, meaning a real settings.json change (e.g. a newly added hook) silently never
  # got written. Must serialize before the mutating call, not after.
  $existingJson = $existing | ConvertTo-Json -Depth 20
  $merged = Merge-Settings -Existing $existing -Template $template -ClaudeDirPath $ClaudeDir
  # Compare against the SAME existing hashtable re-serialized the same way, not the raw
  # file text -- a prior run of this script writes in this exact format, so on a true
  # no-op re-run these two are byte-identical and nothing gets touched. Only the first
  # merge of a hand-written settings.json will look "different" purely from reformatting.
  $mergedJson = $merged | ConvertTo-Json -Depth 20
  if ($existingJson -eq $mergedJson) {
    Write-Host "[ok]      settings.json already up to date" -ForegroundColor DarkGray
  } else {
    # Real, live, load-bearing file about to be overwritten in place (it's merged, never
    # replaced by a link) -- back it up first so a merge bug can't mean an unrecoverable
    # loss of whatever personal settings were already there. PROJ-15342: routed
    # into harness-state/settings-backups/, not the ~/.claude top level.
    $settingsBackupDir = Join-Path $ClaudeDir 'harness-state\settings-backups'
    if (-not (Test-Path -LiteralPath $settingsBackupDir)) { New-Item -ItemType Directory -Path $settingsBackupDir -Force | Out-Null }
    $settingsBackup = Join-Path $settingsBackupDir "settings.json.backup-$stamp"
    Copy-Item -LiteralPath $settingsPath -Destination $settingsBackup
    Write-Host "[backup]  settings.json -> harness-state/settings-backups/$(Split-Path -Leaf $settingsBackup)" -ForegroundColor Yellow
    [System.IO.File]::WriteAllText($settingsPath, $mergedJson, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "[settings] settings.json merged into existing (personal keys -- model/theme/etc -- never touched)" -ForegroundColor Green
  }
} else {
  $merged = Merge-Settings -Existing @{} -Template $template -ClaudeDirPath $ClaudeDir
  $json = $merged | ConvertTo-Json -Depth 20
  [System.IO.File]::WriteAllText($settingsPath, $json, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "[settings] settings.json created (personal keys -- model/theme/etc -- never touched)" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Job 3: add config blocks/keys that harness-config.example.json has and the live
# harness-config.json lacks (a block added to the example after this machine was set up).
# ---------------------------------------------------------------------------
# The live config is untracked and personal, so install never replaces it -- but an existing
# install otherwise never learns about a NEW block. Only ADDS: every existing value, array and
# key is left exactly as is; new keys arrive as the example's placeholders. The user is then
# pointed at `/harness-setup <block>` to fill them. Never pushes to Octopus.

function Add-MissingConfigKeys {
  param($Live, $Example, [string]$Prefix, [System.Collections.Generic.List[string]]$Added)
  foreach ($p in $Example.PSObject.Properties) {
    $path = if ($Prefix) { "$Prefix.$($p.Name)" } else { $p.Name }
    $has = $Live.PSObject.Properties[$p.Name]
    if (-not $has) {
      $Live | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
      $Added.Add($path)
    } elseif ($p.Value -is [pscustomobject] -and $has.Value -is [pscustomobject]) {
      # A free-form map (its example keys are placeholders like "first.recipient@example.com",
      # e.g. releaseNotes.greetingNames) holds the user's OWN keys -- descending would inject the
      # placeholder key into their real map. Leave it whole.
      if (@($p.Value.PSObject.Properties.Name | Where-Object { $_ -match '[<@ ]|example' }).Count -gt 0) { continue }
      Add-MissingConfigKeys -Live $has.Value -Example $p.Value -Prefix $path -Added $Added
    }
  }
}

$liveConfigPath = Join-Path $ClaudeDir 'harness-config.json'
$exampleConfigPath = Join-Path $repoRoot 'harness-config.example.json'
$addedConfigKeys = [System.Collections.Generic.List[string]]::new()
if ((Test-Path -LiteralPath $liveConfigPath) -and (Test-Path -LiteralPath $exampleConfigPath)) {
  $liveCfg = Get-Content -LiteralPath $liveConfigPath -Raw | ConvertFrom-Json
  $exampleCfg = Get-Content -LiteralPath $exampleConfigPath -Raw | ConvertFrom-Json
  Add-MissingConfigKeys -Live $liveCfg -Example $exampleCfg -Prefix '' -Added $addedConfigKeys
  if ($addedConfigKeys.Count -eq 0) {
    Write-Host "[ok]      harness-config.json has every key in harness-config.example.json" -ForegroundColor DarkGray
  } else {
    $cfgJson = $liveCfg | ConvertTo-Json -Depth 20
    $null = $cfgJson | ConvertFrom-Json   # must round-trip before it replaces the live file
    $cfgBackupDir = Join-Path $ClaudeDir 'harness-state\settings-backups'
    if (-not (Test-Path -LiteralPath $cfgBackupDir)) { New-Item -ItemType Directory -Path $cfgBackupDir -Force | Out-Null }
    $cfgBackup = Join-Path $cfgBackupDir "harness-config.json.backup-$stamp"
    Copy-Item -LiteralPath $liveConfigPath -Destination $cfgBackup
    Write-Host "[backup]  harness-config.json -> harness-state/settings-backups/$(Split-Path -Leaf $cfgBackup)" -ForegroundColor Yellow
    [System.IO.File]::WriteAllText($liveConfigPath, $cfgJson, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "[config]  added $($addedConfigKeys.Count) new key(s) from harness-config.example.json (existing values untouched):" -ForegroundColor Green
    foreach ($k in $addedConfigKeys) { Write-Host "            $k" -ForegroundColor Green }
  }
}
$newConfigBlocks = @($addedConfigKeys | ForEach-Object { ($_ -split '\.')[0] } | Select-Object -Unique)

Write-Host ""
if ($newConfigBlocks.Count -gt 0) {
  Write-Host "NEW CONFIG TO FILL IN: $($newConfigBlocks -join ', ')  -- they hold placeholders until you set them. Open Claude Code and run:  /harness-setup $($newConfigBlocks -join ' ')" -ForegroundColor Yellow
  Write-Host ""
}
Write-Host "Done. Open Claude Code and run /harness-setup to personalize harness-config.json (org has a 'Claude Harness' Octopus variable set? -> it can fetch the org config for you)." -ForegroundColor Cyan
Write-Host "<one entry per line; this element only declares the type> calendar reminders (ama-embs-reminders skill) will be offered automatically on first prompt." -ForegroundColor Cyan
Write-Host "/harness-setup also offers a Chrome-by-default opt-in for UI verification (step 5b)." -ForegroundColor Cyan
