#!/usr/bin/env bash
# PreToolUse hook (Edit|Write, Bash|PowerShell). PROJ-15342: denies creating a NEW
# entry directly at the ~/.claude TOP LEVEL. That directory accumulated ~90 files that
# didn't belong there -- no policy ever said where hook state or scratch notes should go,
# so every hook author invented its own $HOME/.claude/.<feature>-<state> literal, and every
# session dropped diagnostics in the same flat directory. Worse than untidy: ~/.claude is a
# git repo pushed to a personal GitHub remote, and other sessions had already staged >20 of
# these scratch files for commit before this gate existed.
#
# The rule, and why it's this simple: a path INSIDE any subdirectory of ~/.claude (one or
# more `/` after ".claude/") is always allowed, regardless of which subdirectory -- state
# goes in harness-state/<category>/ via hooks/lib-claude-paths.sh's hstate(), scratch goes
# in scratch/<purpose>/ via hscratch(), and both already guarantee their own parent dirs.
# Only a path with NO further `/` after ".claude/" -- i.e. a NEW direct top-level entry --
# is checked against the allowlist below and denied if absent. This means the check never
# needs to know about every legitimate subdirectory, only the (small, stable) set of things
# that legitimately live AT the top level: Claude Code's own files/dirs, the harness's
# linked files, and the two new umbrella folders themselves.
#
# TWO matchers, deliberately, because most of this clutter was created by shell
# redirection inside hook scripts (`> "$HOME/.claude/.some-state"`), not by the Write
# tool -- an Edit/Write-only gate would miss the majority of real creation sites.
#
# Fails open on anything it cannot parse -- a hook must never be the reason routine work
# stalls; the cost of a miss here is one more file to clean up later, not a broken task.
set -u

# --- allowlist: everything legitimately AT the ~/.claude top level -------------------
# Directories: Claude Code's own (created/managed by the CLI binary itself, never by a
# hook) plus the harness's own junctions/symlinks plus the two new umbrella folders.
allowed_dir() {
  case "$1" in
    projects|plans|tasks|sessions|session-env|shell-snapshots|ide|plugins|debug|\
file-history|backups|cache|image-cache|jobs|telemetry|daemon|chrome|\
skills|hooks|scripts|memory|"Chat files"|"Local Chat Files"|\
harness-state|scratch) return 0 ;;
    *) return 1 ;;
  esac
}
# Files: Claude Code's own config/state, secrets it manages itself, and the harness's own
# linked/merged files (settings.json is MERGED here, never linked, so it's real content at
# the top level by design -- see scripts/install.ps1's header).
allowed_file() {
  case "$1" in
    settings.json|settings.local.json|remote-settings.json|policy-limits.json|\
mcp-needs-auth-cache.json|history.jsonl|.credentials.json|.ama-ui-credentials.json|\
.gitignore|\
CLAUDE.md|AGENTS.md|README.md|harness-gaps.md|harness-config.json|\
harness-config.example.json|.harness-local.json|.harness-local.json.example|\
sessions.txt|sessions.md|session-names.txt) return 0 ;;
    # IT-TICKET-VPN-DNS-bitbucket.md was whitelisted here while it lived flat under
    # ~/.claude; it moved to ~/.claude/IT-Ticket-VPN-DNS/ (2026-08-28, PROJ-15342)
    # and vpn-dns-outage-logger.sh now points there, so the flat name is ordinary clutter
    # again -- deliberately no longer allowed.
    .last-*|daemon*) return 0 ;;
    *) return 1 ;;
  esac
}

deny_reason() {
  jq -cn --arg n "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("Refusing to create a new top-level entry (\"" + $n + "\") directly in ~/.claude -- that flat directory is a git repo pushed to a personal GitHub remote, and every prior top-level scratch/state file that landed there ended up staged for a commit by some session sooner or later (PROJ-15342). Durable hook/harness state belongs under ~/.claude/harness-state/<category>/ -- source hooks/lib-claude-paths.sh and call `hstate <category> <name>` for the path, it creates the parent dir for you. Disposable notes/diagnostics belong under ~/.claude/scratch/<purpose>/ -- `hscratch <purpose> <name>`, same file.")
    }
  }'
}

# top_level_new_name <path> -> the bare top-level name IF this path is a direct, not-yet-
# allowlisted top-level entry; empty otherwise (already-nested paths always print empty).
top_level_new_name() {
  local p norm rest
  p="$1"
  [ -n "$p" ] || return 0
  norm="$(printf '%s' "$p" | tr '\134' '/')"
  case "$norm" in
    */.claude/*) : ;;
    *) return 0 ;;
  esac
  rest="${norm#*/.claude/}"
  rest="${rest%/}"
  [ -n "$rest" ] || return 0
  case "$rest" in
    */*) return 0 ;;  # nested under some subdirectory -- always fine, not this gate's job
  esac
  if allowed_dir "$rest" || allowed_file "$rest"; then return 0; fi
  printf '%s' "$rest"
}

payload="$(cat)"
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"

case "$tool" in
  Edit|Write)
    file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
    [ -n "$file_path" ] || exit 0
    name="$(top_level_new_name "$file_path")"
    [ -n "$name" ] || exit 0
    deny_reason "$name"
    ;;
  Bash|PowerShell)
    # Cheap raw-payload pre-filter before any jq fork (precedent: aggregation-secret-
    # gate.sh) -- every real hit has ".claude" in the command text somewhere.
    case "$payload" in *.claude*) : ;; *) exit 0 ;; esac
    command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [ -n "$command" ] || exit 0
    # Heredoc bodies are DATA, not commands -- measure only the region before the first
    # `<<` (same scoping unanalyzable-script-gate.sh uses), so a commit message that
    # merely describes this hazard can't self-deny.
    . "$HOME/.claude/hooks/lib-command-text.sh" 2>/dev/null || command_scan_region() { printf '%s' "$1"; }
    head_region="$(command_scan_region "$command")"
    # A write-shaped reference ONLY -- a plain read (cat, grep, ls, jq < file) must never
    # match here, or this gate would deny routine investigation of an existing top-level
    # file. Two shapes, `\K` resets the match start past the operator so the captured
    # candidate is just the path (avoids PCRE's fixed-width lookbehind limit, since `>`
    # and `>>` differ in width):
    #   1. redirect:      `>` or `>>` followed by a path
    #   2. write command: touch/mkdir/mv/cp/tee, then a path later in the same segment
    # grep -oP keeps this to two forks total, not one per candidate token.
    # Path may be quoted ("$HOME/..." or '$HOME/...') -- \K after an optional quote so
    # the quote itself is never part of the captured candidate, and the char class
    # excludes quotes/whitespace/separators so a trailing quote can't leak in either.
    path_pat="[\"']?\K(\\\$HOME|~|[A-Za-z]:|/[a-zA-Z])[^\\s;&|\"']*\\.claude[^\\s;&|\"']*"
    candidates="$(
      { printf '%s' "$head_region" | grep -oP ">{1,2}\s*${path_pat}" 2>/dev/null
        # TWO greps, not one: a single non-greedy `\b(verb)\b[^;&|]*?${path_pat}` stops at the
        # FIRST .claude path after the verb -- for `cp`/`mv` that is the SOURCE, and the
        # DESTINATION was never examined at all. Confirmed real miss (session 1ce24e66,
        # 2026-09-01): `cp $HOME/.claude/settings.json $HOME/.claude/settings.json.bak` was
        # ALLOWED, because top_level_new_name cleared the allowlisted source and the loop
        # never saw the new file being created. So: isolate the segment from the write verb
        # onward, then extract EVERY .claude path in it. Testing all of them can deny on a
        # source that is itself clutter -- a confusing message, never a wrong outcome, and
        # far better than the silent miss in a gate that fails open everywhere else.
        printf '%s' "$head_region" | grep -oP "\b(touch|mkdir|tee)\b[^;&|]*" 2>/dev/null \
          | grep -oP "${path_pat}" 2>/dev/null
        # cp/mv: only the LAST path is a destination. Testing the source too denied the
        # `mv` that was REMOVING a stray top-level file (its source is, by definition, the
        # clutter this gate names) -- the gate blocked its own remediation (2026-09-18).
        printf '%s' "$head_region" | grep -oP "\b(mv|cp)\b[^;&|]*" 2>/dev/null \
          | while IFS= read -r seg; do printf '%s' "$seg" | grep -oP "${path_pat}" 2>/dev/null | tail -1; done
      } | sort -u
    )"
    [ -n "$candidates" ] || exit 0
    while IFS= read -r cand; do
      [ -n "$cand" ] || continue
      # Expand a literal $HOME/~ prefix so top_level_new_name's ".claude/" match works
      # regardless of which spelling was used.
      expanded="${cand/#\$HOME/$HOME}"
      expanded="${expanded/#~/$HOME}"
      name="$(top_level_new_name "$expanded")"
      if [ -n "$name" ]; then
        deny_reason "$name"
        exit 0
      fi
    done <<< "$candidates"
    ;;
  *) exit 0 ;;
esac
