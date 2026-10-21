#!/usr/bin/env bash
# PostToolUse hook (Bash/PowerShell), warn-only. After a `git commit` in an AMA_APP repo, reads
# the REAL commit (not the command text) and nudges on two bug-class signals:
#
# A. A SHARED COMPONENT GAINS ASSUMPTIONS ABOUT INPUT IT DOES NOT OWN. A file at a convergence
#    point (SQL_EMITTING_PATHS, a published library project, an Angular shared/core file) adds
#    text parsing of a value (Split/IndexOf/LastIndexOf/Regex/Replace/Substring/Join) or changes
#    an interface. -> checklist: every PRODUCER of the input sampled for real, every CONSUMER of
#    the output run for real, fixtures from real producers.
# B. THE COMMIT MESSAGE IS A POSTMORTEM ("was not caught because", "root cause") -- a lesson
#    written where no future session reads it. -> record it in the harness.
#
# Why (PROJ-15416 -> 15808, 2026-09-26..10-15). SingleLoanMaskBuilder parsed the measure
# list fed to it by fourteen builder families -- its commit even names "the fourteen families" --
# assuming each entry is one `<expr> AS <alias>`. None was sampled. Five follow-up defects, every
# one an unchecked assumption about input or output the mask did not own: an inner CAST's AS
# (c26fcee3), a guessed alias for the "# Loans" exemption (same), sort-key columns swept into the
# list (da198cdd), a table alias that only exists inside a CTE (1dcc48c6), comma-joined trend and
# pivot entries (0dd5527f, prod 42601). c26fcee3 wrote the lesson down on 09-27 ("fixtures used
# the same wrong alias... validation ran hand-written SQL") in a commit body; nothing read it for
# 18 days, and PROJ-15819 finally switched the mask off in production. learned-lesson-check.sh
# reads reply text only -- signal B covers commit bodies.
#
# Dedupe: A once per TICKET (amend loops / multi-commit tickets must not train the reader to skip
# it), B per commit sha; ledger `hstate tickets shared-input-nudged`; firings logged to
# `hstate logs shared-input-nudge.log`. Seams: SHARED_INPUT_NUDGE_REV
# (rev to read, default HEAD), CLAUDE_STATE_DIR. Fails open everywhere. Detail + the protocol:
# skills/ama-debugging-notes/SHARED-CHOKEPOINT-CHANGES.md.
set -u

IFS= read -r -d '' payload || true
case "$payload" in
  *commit*) : ;;
  *) exit 0 ;;
esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null | tr -d '\r')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null | tr -d '\r')"
[ -n "$command" ] || exit 0
printf '%s' "$command" | grep -qP '(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?commit\b' || exit 0

. "$HOME/.claude/hooks/lib-git-target.sh" 2>/dev/null || exit 0
git_target_unresolved "$command" commit && exit 0   # never read a guessed repo's HEAD
target_dir="$(git_target_dir "$command" "$cwd" commit)"
[ -n "$target_dir" ] || exit 0
git -C "$target_dir" remote get-url origin 2>/dev/null | grep -q 'ama-claude-harness' && exit 0

rev="${SHARED_INPUT_NUDGE_REV:-HEAD}"
sha="$(git -C "$target_dir" rev-parse --short "$rev" 2>/dev/null)"
[ -n "$sha" ] || exit 0
subject="$(git -C "$target_dir" log -1 --format=%s "$rev" 2>/dev/null)"
body="$(git -C "$target_dir" log -1 --format=%b "$rev" 2>/dev/null)"
ticket="$(printf '%s' "$subject" | grep -oP '^[A-Z]+-\d+' | head -1)"
[ -n "$ticket" ] || ticket="$sha"

. "$HOME/.claude/hooks/lib-claude-paths.sh" 2>/dev/null || exit 0
ledger="$(hstate tickets shared-input-nudged)"
touch "$ledger" 2>/dev/null || exit 0
. "$HOME/.claude/hooks/lib-sql-emitting-paths.sh" 2>/dev/null || SQL_EMITTING_PATHS='^$'

pipeline_publishes=0
grep -qsE 'dotnet (pack|nuget push)|package\.sh|package_develop_branch\.sh' "$target_dir/bitbucket-pipelines.yml" && pipeline_publishes=1

# is_shared <path>: a convergence point other code feeds or consumes.
is_shared() {
  local p="$1" proj
  printf '%s' "$p" | grep -qiP "$SQL_EMITTING_PATHS" && return 0
  printf '%s' "$p" | grep -qE '(^|/)src/app/(shared|core)/' && return 0
  if [ "$pipeline_publishes" = 1 ]; then
    proj="${p%%/*}"
    grep -qsE '<(VersionPrefix|Version|PackageId)>' "$target_dir/$proj/$proj.csproj" && return 0
  fi
  return 1
}

TEXT_OPS='\.Split\(|\.split\(|LastIndexOf\(|lastIndexOf\(|\.IndexOf\(|\.indexOf\(|Regex|\.Substring\(|\.substring\(|\.Replace\(|\.replace\(|string\.Join\(|\.join\('

hits=""; ops=""
files="$(git -C "$target_dir" show --format= --name-only "$rev" -- '*.cs' '*.ts' 2>/dev/null \
  | grep -viE '(Tests?/|\.Tests?\.|Tests?\.cs$|\.spec\.ts$|/test/|Mock)')"
# Once per TICKET, not per file: replayed over 60 search commits it fired on 16 (nearly all real
# shared-builder risk), and a nudge that repeats on every commit of a ticket gets skimmed.
grep -qxF "ticket|$ticket" "$ledger" && files=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  is_shared "$f" || continue
  # Comment and logging lines carry text ops that parse nothing (7432f37f: a log message fix fired).
  added="$(git -C "$target_dir" show --format= --unified=0 "$rev" -- "$f" 2>/dev/null | grep -E '^\+[^+]' \
    | grep -vE '^\+\s*(//|/?\*)|[Ll]og(ger)?\.|\.Log(Information|Warning|Error|Debug|Trace|Critical)\(|console\.(log|warn|error)')"
  why=""
  o="$(printf '%s\n' "$added" | grep -oE "$TEXT_OPS" | sort -u | tr '\n' ' ')"
  [ -n "$o" ] && { why="parses text"; ops="$ops$o"; }
  case "${f##*/}" in I[A-Z]*.cs) why="${why:+$why, }interface" ;; esac
  printf '%s\n' "$added" | grep -qE '^\+\s*(public\s+|export\s+)?interface\s' && case "$why" in *interface*) ;; *) why="${why:+$why, }interface" ;; esac
  [ -n "$why" ] || continue
  hits="$hits$f ($why); "
done <<< "$files"
[ -n "$hits" ] && printf 'ticket|%s\n' "$ticket" >> "$ledger"

lesson=""
# Wording about why a defect was NOT DETECTED -- not "root cause", which every fix body explains
# (7432f37f and 107637b0 in reports both fired on it).
if printf '%s' "$body" | grep -qiP "(was|were|is|are)( not|n't) caught|neither was caught|nothing caught|should have caught|went unnoticed|the (unit )?(fixtures?|tests?) (used|were|mocked|never)|hand-?written (sql|fixture|query)|follow-?up defects?|slipped through|missed because"; then
  grep -qxF "lesson|$sha" "$ledger" || { lesson=1; printf 'lesson|%s\n' "$sha" >> "$ledger"; }
fi

[ -n "$hits" ] || [ -n "$lesson" ] || exit 0
# Every firing logged, so "do sessions act on it?" can be measured (2-week review reminder set
# 2026-10-20) instead of guessed.
printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$ticket" "$sha" "${hits:+A}${lesson:+B}" "${hits%; }" \
  >> "$(hstate logs shared-input-nudge.log)" 2>/dev/null

msg=""
if [ -n "$hits" ]; then
  ops="$(printf '%s' "$ops" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')"
  msg="Just committed $ticket ($sha). Shared component(s) changed: ${hits%; }${ops:+ -- text ops added: $ops}. Code at a convergence point is fed by N producers and read by M consumers; one assumed shape for all of them is the bug class behind PROJ-15416's five follow-ups and 15808's prod 42601 (its commit named \"the fourteen families\" and sampled none). Before pushing, put EVIDENCE (not \"it inherits\") in the ticket's regression note:
1. INPUTS YOU DON'T OWN -- list every producer of each value this code parses, rewrites or name-matches (all implementers, DI registrations, callers) and capture one REAL output from each: call the real builder in a test, or copy a logged production value. Names used as contracts (aliases, cache keys, JSON property names) are inputs too: read the real one, never guess it.
2. FIXTURES FROM THOSE PRODUCERS -- one all-producers test that pushes every registered producer's real output through the change. A hand-typed fixture tests your assumption against itself.
3. OUTPUTS -- every consumer that wraps, splits, re-orders, references by name or ships your output elsewhere gets one real run: SQL -> rs-explain-shapes.sh (and its FAMILY lines: a measure kind never exercised is not covered), JSON -> a real call per consumer, shared UI -> each host page.
4. TEXT PARSING of structured text (SQL, JSON, CSV, paths) splits only at top level (parens, brackets, quotes) -- or use a real parser.
Protocol: ama-debugging-notes/SHARED-CHOKEPOINT-CHANGES.md. Nothing to do if every changed file's inputs and outputs are already covered -- say so in one line."
fi
if [ -n "$lesson" ]; then
  [ -n "$msg" ] && msg="$msg

"
  msg="${msg}This commit message ($sha) reads as a postmortem (\"not caught because\" / \"root cause\" ...). A lesson in a commit body is read by nobody: c26fcee3 recorded 15416's fixture lesson on 2026-09-27 and three more follow-ups shipped before anything acted on it. Record the generalised lesson where a future session hitting the same PROBLEM will find it (CLAUDE.md 'Gotcha/Lesson Placement'; for AMA code, ama-debugging-notes), in this same turn."
fi

jq -cn --arg r "$msg" '{decision:"block", reason:$r}'
