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
       sessions.txt, sessions.md (symlinks -- need Developer Mode or an elevated
       shell) from ~/.claude into this repo. sessions.txt/sessions.md are real,
       frequently-rewritten runtime files, not static config -- every script that
       rewrites them writes THROUGH the symlink (see hooks/lib-sessions-lock.sh's
       sessions_write_through), never replaces it, so this is safe to link the same
       way as the static files above. Chat files/, sessions.txt, sessions.md are all
       gitignored (per-machine runtime state) -- unlike every other linked path here,
       a fresh clone won't have them on disk yet, so this script creates them
       (empty dir/files) before linking instead of treating a missing source as a
       broken clone.
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

  if (Test-Path -LiteralPath $dst) {
    $backupName = "$($t.Name).backup-$stamp"
    Rename-Item -LiteralPath $dst -NewName $backupName
    Write-Host "[backup]  $($t.Name) -> $backupName (real content found, not overwritten)" -ForegroundColor Yellow
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
    # loss of whatever personal settings were already there.
    $settingsBackup = "$settingsPath.backup-$stamp"
    Copy-Item -LiteralPath $settingsPath -Destination $settingsBackup
    Write-Host "[backup]  settings.json -> $(Split-Path -Leaf $settingsBackup)" -ForegroundColor Yellow
    [System.IO.File]::WriteAllText($settingsPath, $mergedJson, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "[settings] settings.json merged into existing (personal keys -- model/theme/etc -- never touched)" -ForegroundColor Green
  }
} else {
  $merged = Merge-Settings -Existing @{} -Template $template -ClaudeDirPath $ClaudeDir
  $json = $merged | ConvertTo-Json -Depth 20
  [System.IO.File]::WriteAllText($settingsPath, $json, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "[settings] settings.json created (personal keys -- model/theme/etc -- never touched)" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done. Open Claude Code and run /harness-setup to personalize harness-config.json (org has a 'Claude Harness' Octopus variable set? -> it can fetch the org config for you)." -ForegroundColor Cyan
Write-Host "eMBS calendar reminders (ama-embs-reminders skill) will be offered automatically on first prompt." -ForegroundColor Cyan
Write-Host "/harness-setup also offers a Chrome-by-default opt-in for UI verification (step 5b)." -ForegroundColor Cyan
