#!/usr/bin/env bash
# PreToolUse hook (Bash|PowerShell). Denies a SHELL write to a path that a deny-class
# content gate protects -- because those gates only match Edit|Write and cannot see it.
#
# Auto mode instructs "make file changes with sed, heredocs, or short scripts, rather than
# using the dedicated Read, Edit, or Write tools". Every content gate here is registered
# under `matcher: "Edit|Write"` only. Net effect: an agent edits gate-covered files all
# day and not one of those gates ever runs. Confirmed live 2026-08-31 (<harnessEpicKey>):
# three skills/<amaSupportChannelName>-notices/* files edited via `perl -i`, skill-bloat-gate.sh never
# fired once. 8 of the 9 Edit|Write gates were bypassable this way; claude-dir-clutter-
# gate.sh was the only safe one, because it is dual-registered under both matchers -- the
# precedent this gate follows.
#
# NOT a duplicate of inplace-edit-gate.sh. That one guards ~/.claude paths against SYMLINK
# DESTRUCTION (sed -i renames a temp file over the target, replacing the link); it exits
# on its `*.claude*` prefilter, so repo paths fall straight through, and it never looks at
# redirects. Different trigger, different hazard, both needed.
#
# Only DENY-class gates are represented below. Denying a command because an advisory nudge
# was skipped (skill-model-tiering-gate.sh, jit-pointer-nudge.sh, transcript-scan-bound-
# nudge.sh) would be disproportionate. AGENTS.md is deliberately absent: no Edit|Write
# content gate covers it, so denying there would be NEW restriction, not restored coverage.
set -u

payload="$(cat)"

# Cheap raw-payload needle check before any jq fork (precedent: aggregation-secret-gate.sh,
# claude-dir-clutter-gate.sh). Every protected pattern contains one of these substrings.
case "$payload" in
  # `.claude/` is needed for the symlink case below and is NOT implied by the `CLAUDE.md`
  # needles -- a lowercase `.claude/harness-gaps.md` matches none of them. Missing it is
  # exactly why that whole class stayed unguarded after this gate shipped.
  *skills/*|*SKILL.md*|*CLAUDE.md*|*claude.md*|*.claude/*|*standup-notes-*|*/memory/*) : ;;
  *) exit 0 ;;
esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$command" ] || exit 0

# Heredoc bodies are DATA, not commands -- only the region before the first `<<` is
# analysed (same scoping unanalyzable-script-gate.sh and claude-dir-clutter-gate.sh use).
# Without this, a commit message that merely DESCRIBES this hazard self-denies; the first
# version of inplace-edit-gate.sh blocked its own commit exactly that way. Note that
# `cat > skills/x/SKILL.md <<EOF` still trips: the redirect precedes the `<<`.
. "$HOME/.claude/hooks/lib-command-text.sh" 2>/dev/null || command_scan_region() { printf '%s' "$1"; }
head_region="$(command_scan_region "$command")"

# Escape hatch for a genuine bulk migration across many files. Logged, never silent -- an
# escape hatch nobody can audit is just a hole with extra steps.
case "$head_region" in
  *HARNESS_BULK_EDIT=1*)
    # CHECK_GATES_COPY is exported by check-gates.sh when it re-execs its own temp copy,
    # so the suite's escape-hatch fixture doesn't file an audit entry indistinguishable
    # from a real use. Caught by running the suite: the first line this log ever gained
    # was a test fixture's.
    if [ -z "${CHECK_GATES_COPY:-}" ]; then
      . "$HOME/.claude/hooks/lib-claude-paths.sh" 2>/dev/null && \
        printf '%s\t%s\n' "$(date '+%F %T')" "$(printf '%s' "$head_region" | head -c 200 | tr '\n' ' ')" \
          >> "$(hstate notices bulk-edit-uses.txt)" 2>/dev/null
    fi
    exit 0
    ;;
esac

# Which gate protects a given path -- result in $PG, empty when nothing does. Normalised to
# forward slashes and lowercase first, so a Windows-style or shouty path still matches.
# Builtins + a variable, NOT `$(...)` + tr|tr: it runs once per candidate TOKEN, and for an
# in-place edit every token is one -- ~3 forks each put this gate at 20 s (its whole budget)
# under 2026-10-22's load, so it timed out and failed OPEN on the very writes it guards.
protecting_gate() {
  local p="${1//\\//}"
  p="${p,,}"
  PG=""
  case "$p" in
    # native-memory-gate.sh -- checked before the .md patterns, since a memory file is
    # also a .md and this is the more specific owner.
    */.claude/projects/*/memory/*) PG='native-memory-gate.sh'; return ;;
  esac
  case "$p" in
    # symlink-write-gate.sh -- it redirects Edit|Write on ANY ~/.claude path that is really a
    # symlink/junction into the harness repo. A shell write to the same path is far worse
    # than a bypassed content check: `sed -i`, `perl -i` and write-temp-then-`mv` all UNLINK
    # and recreate, so the link is REPLACED BY A REAL FILE and every later write through
    # ~/.claude stops reaching the repo silently. Confirmed twice on 2026-09-01 (09:47 and
    # again 11:06) on ~/.claude/harness-gaps.md: entries appended by other sessions stopped
    # being shared, and repair needed a two-way merge because each copy held work the other
    # lacked. Tested per-path (is this path ACTUALLY a link?) rather than by ~/.claude prefix,
    # so ordinary shell writes into harness-state/ and scratch/ -- which hstate/hscratch
    # produce constantly -- stay allowed. Same resolve-and-compare as symlink-write-gate.sh (readlink -f vs given).
    #
    # ONLY the in-place shapes ($inplace, set by the caller). This is not fussiness: `>`,
    # `>>` and `tee` OPEN THROUGH a symlink -- they truncate or append the real target and
    # leave the link intact -- while `sed -i`/`perl -i` write a temp file and rename over
    # the path, which unlinks it. Denying the redirect shapes here would also contradict
    # CLAUDE.md, which tells every session to append its gap line with
    # `>> ~/.claude/harness-gaps.md`; that append is safe and must stay allowed.
    */.claude/*)
      [ "${inplace:-0}" = "1" ] || return
      local real
      real="$(readlink -f "$1" 2>/dev/null)"
      if [ -n "$real" ] && [ "${real,,}" != "$p" ]; then
        PG='symlink-write-gate.sh'; return
      fi
      ;;
  esac
  case "$p" in
    # standup-empty-section-gate.sh -- its own header documents this exact bypass biting
    # it before ("the run wrote the file by redirect and this gate never fired").
    *standup-notes-*.md) PG='standup-empty-section-gate.sh'; return ;;
    # skill-bloat-gate.sh. Both the absolute and bare-relative spellings -- `skills/x.md`
    # has nothing before `skills/` for a `*/skills/` glob to match, and a relative path is
    # exactly what a repo-root shell command uses.
    */skills/*.md|skills/*.md) PG='skill-bloat-gate.sh'; return ;;
    */claude.md|claude.md)      PG='skill-bloat-gate.sh'; return ;;
  esac
}

# Work one simple command at a time. A write shape in one segment must not condemn a
# protected path merely mentioned in another -- `sed -i 's/a/b/' notes.txt && cat
# skills/x/SKILL.md` writes nothing protected. Splitting on quoted separators can merge
# segments, which loses a deny rather than inventing one (fail-open, deliberate).
segments="$(printf '%s' "$head_region" | sed 's/&&/\n/g; s/||/\n/g; s/[;&|]/\n/g')"

while IFS= read -r seg; do
  [ -n "$seg" ] || continue

  # Write shape 1: an in-place stream edit. Flag must be a real TOKEN -- whitespace, `-`,
  # optional bundled letters, then `i`. Lifted from inplace-edit-gate.sh:44-46, whose
  # header explains why a bare `-i` match fails BOTH ways: it denied `sed -n '1,25p'
  # .../jira-edit-issue.sh` (the -i is inside "edit-issue") and MISSED `perl -pi -e`.
  # Segment-local, so `sed` need not be at the head of the whole command.
  inplace=0
  printf '%s' "$seg" \
    | grep -qE '(^|[[:space:]])(sed|perl)[[:space:]]+([^[:space:]]*[[:space:]])*?(-[A-Za-z0-9]*i([[:space:]]|$|\.|[A-Za-z0-9_-])|--in-place)' \
    && inplace=1

  # Write shape 2: a redirect or tee. `\K` resets the match start past the operator so the
  # captured candidate is just the path (avoids PCRE's fixed-width lookbehind limit, since
  # `>` and `>>` differ in width) -- same construction as claude-dir-clutter-gate.sh:120.
  # Unlike that gate the path pattern is NOT anchored on a literal, because a relative
  # repo path is the common case here; classification is left to protecting_gate.
  path_pat="[\"']?\K[^[:space:]\"'<>]*[^[:space:]\"'<>=]"
  if [ "$inplace" = "1" ]; then
    # Every path-looking token in the segment -- a plain read in the SAME segment as an
    # in-place edit is vanishingly rare, and protecting_gate rejects non-matches anyway.
    candidates="$(printf '%s' "$seg" | grep -oE "[^[:space:]\"'<>]+" 2>/dev/null)"
  else
    candidates="$(
      { printf '%s' "$seg" | grep -oP ">{1,2}\s*${path_pat}" 2>/dev/null
        printf '%s' "$seg" | grep -oP "\btee\b(\s+-[A-Za-z]+)*\s+${path_pat}" 2>/dev/null
      } | sort -u
    )"
  fi
  # Write shape 3: an interpreter writing the file from CODE. Auto mode reaches for
  # `python - <<'PY' ... open('skills/x/SKILL.md','w')` as readily as sed, and a SKILL.md
  # prose rewrite went through exactly that with skill-bloat-gate.sh never running
  # (2026-09-22, session 0338a6ba). The code usually sits in a heredoc BODY, outside
  # $head_region, so for an interpreter segment the candidates come from the WHOLE command
  # -- provided a write verb appears somewhere in it. A python READ of a skill in the same
  # command as an unrelated write is denied too; that false positive is cheap by design.
  if printf '%s' "$seg" | grep -qE '(^|[[:space:]])(python3?|node|perl|ruby|pwsh|powershell)(\.exe)?([[:space:]]|$)' \
     && printf '%s' "$command" | grep -qE "open\([^)]*['\"][wa]|writeFile|write_text|write_bytes|Set-Content|Out-File"; then
    candidates="$(printf '%s' "$command" | grep -oE "[^[:space:]\"'<>(),;]+" 2>/dev/null)"
  fi
  [ -n "$candidates" ] || continue

  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    # Expand a literal $HOME/~ prefix so the .claude memory pattern matches whichever
    # spelling was used (claude-dir-clutter-gate.sh:129-132).
    expanded="${cand/#\$HOME/$HOME}"
    expanded="${expanded/#\~/$HOME}"
    protecting_gate "$expanded"; gate="$PG"
    [ -n "$gate" ] || continue

    jq -cn --arg path "$cand" --arg gate "$gate" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: ("Shell write to " + $path + ", which is covered by " + $gate + " -- and that gate only matches Edit|Write, so an in-place edit or redirect bypasses it silently. This is not a ban on shell edits generally; it is that THIS path has a content rule nobody would check. Use the Edit or Write tool so the gate runs. Genuine bulk migration across many files: prefix the command with HARNESS_BULK_EDIT=1 (logged to harness-state/notices/bulk-edit-uses.txt) and say why in the commit message. Background: <harnessEpicKey>, and the in-place symlink hazard in the bash-command-correctness skill.")
      }
    }'
    exit 0
  done <<< "$candidates"
done <<< "$segments"

exit 0
