#!/usr/bin/env bash
# PostToolUse hook (Edit|Write). Two jobs, one fork:
#
#  1. Edited a file check-gates.sh ASSERTS ABOUT -> say so, and name the filtered command.
#  2. Once per session, ARM the full-run-owed reminder, which nothing else creates.
#
# Origin (2026-09-14): commit 4e54f3b replaced the harness-gaps runner's hardcoded
# `--model opus` with a strongest-first resolver and left check-gates.sh's static needle for
# that literal behind. The suite went red on an assertion that session never ran, and it was
# found by accident days later. The suite pins files OUTSIDE hooks/ by literal grep, and
# nothing connected "I edited that file" to "run the suite". That block is suite-level, so
# ANY filtered run catches it -- the session simply ran no suite at all.
#
# KEY ON A PATH, NEVER A BARE BASENAME. `SKILL.md` appears 24x and `settings.json` 8x in
# check-gates.sh as unrelated fixture literals, so a basename key would fire on every skill
# edit in the fleet. Measured rules instead:
#   hooks/<x>.sh  -> a line matching ^G=<x>$          (exact gate pin; 0 hits for SKILL.md)
#   anything else -> literal of its last TWO path components
# Under rule 2, SKILL.md matches only the ~7 skill files the suite really does assert about
# (commit-ticket/SKILL.md, ama-jira-api/SKILL.md, ...) -- wanted hits, not false positives.
#
# Reuses readme-currency-gate.sh's shape deliberately: same norm(), same
# .session-chatfiles/$sid dedup, same {decision:"block"} output (whose header records that
# PostToolUse block DOES reach the model, verified against a real transcript). Case matters
# for the grep, so norm() is used only to LOCATE the file, never to build the search key.
#
# Job 2 detail: hstate notices .check-gates-full-run-owed is read by check-gates-reminder.ps1
# and deleted by scripts/run-check-gates-full.sh on a green pass, and the digest file is
# drained into the next prompt by on-prompt.sh:777 -- but NOTHING created the marker, so the
# whole mechanism had been inert since the wrapper last went green and deleted its own
# scheduled task. Arming it here closes that loop with no host-level change.
set -u

payload="$(cat)"

# Raw needle before any jq fork (GATES-AND-HOOKS.md fork budget): edits outside the harness
# cost nothing.
case "$payload" in *ama-claude-harness*|*.claude*) ;; *) exit 0 ;; esac

sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')"
[ -n "$sid" ] && [ -n "$file_path" ] || exit 0

harness="$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$harness" ] || exit 0
# Edit inside a harness worktree -> check that tree's own suite (lib-harness-worktree.sh).
. "${BASH_SOURCE[0]%/*}/lib-harness-worktree.sh" 2>/dev/null && { hwt_root_of "$file_path"; [ -n "$HWT_ROOT" ] && harness="$HWT_ROOT"; }
suite="$harness/scripts/check-gates.sh"
[ -f "$suite" ] || exit 0

claude_root="$HOME/.claude"

# Slash-normalise without lowercasing (the key must keep real case); lowercase copies are
# for prefix matching only. Lowercasing preserves length, so offsets are shared.
slash() { printf '%s' "$1" | tr '\134' '/'; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

f="$(slash "$file_path")"; f_lc="$(lower "$f")"
h_lc="$(lower "$(slash "$harness")")"
c_lc="$(lower "$(slash "$claude_root")")"

rel=""
case "$f_lc" in
  "$h_lc"/*) rel="${f:$(( ${#h_lc} + 1 ))}" ;;
  "$c_lc"/*) rel="${f:$(( ${#c_lc} + 1 ))}" ;;
  *) exit 0 ;;
esac
[ -n "$rel" ] || exit 0

# Editing the suite itself is not a currency problem.
case "$(lower "$rel")" in scripts/check-gates.sh) exit 0 ;; esac

STATED="$claude_root/.session-chatfiles"
mkdir -p "$STATED" 2>/dev/null
NUDGEFILE="$STATED/$sid.cgnudge"
touch "$NUDGEFILE" 2>/dev/null

# --------------------------------------------------- shared: does the suite pin this file?
# Computed BEFORE job 2 (it used to sit after) because the reminder now records WHICH gate
# sections an edit needs re-run, not merely THAT something was edited. Job 1 below uses the
# same values, so there is still exactly one mapping here, not two.
gate_name=""
pinned="no"
case "$(lower "$rel")" in
  hooks/*.sh)
    # A GATE is pinned by its own `G=<name>` block. A non-gate hook the suite still asserts
    # about (on-prompt.sh, asserted via "$hooks/on-prompt.sh") has no G= line, so fall
    # through to the path rule rather than missing it.
    gate_name="$(basename "$rel")"
    if grep -qE "^G=$(printf '%s' "$gate_name" | sed 's/[.[\*^$]/\\&/g')$" "$suite" 2>/dev/null; then
      pinned="yes"
    else
      gate_name=""
    fi
    ;;
esac

# Last two path components, real case, e.g. scripts/harness-gaps-unattended-run.sh or
# hooks/on-prompt.sh or commit-ticket/SKILL.md.
two="$(printf '%s' "$rel" | awk -F/ '{ if (NF>=2) print $(NF-1) "/" $NF; else print $NF }')"
if [ "$pinned" = "no" ]; then
  grep -qF -- "$two" "$suite" 2>/dev/null && pinned="yes"
fi

# WHICH sections assert about this file? A `G=<name>` line opens a gate section and a
# column-0 `fi` closes it, so a mention inside one belongs to that gate and a mention
# outside every one is suite-level -- and suite-level assertions have no want_gate guard,
# so ANY filtered run already covers them.
#
# This mapping is the whole point: a non-gate file is usually asserted INSIDE some gate's
# block. Every suite mention of scripts/mutate-gates.sh sits in check-gates-unfiltered-
# gate.sh's section, so recording it as "suite-level only" would clear the reminder while
# leaving that gate unrun -- silently worse than the blunt full pass this replaces.
needle="$two"
case "$(lower "$rel")" in hooks/*.sh) needle="$(basename "$rel")" ;; esac
# NO `next` on the `G=` rule: a gate's name usually appears nowhere in its section EXCEPT
# that opening line, so skipping the line would report the gate's own file as suite-level.
entries="$(awk -v pat="$needle" '
  /^G=/  { cur = substr($0, 3) }
  /^fi$/ { cur = ""; next }
  index($0, pat) { print (cur == "" ? "N:" : "G:" cur) }
' "$suite" 2>/dev/null | sort -u)"
# No mention anywhere => nothing but the always-on suite-level assertions can cover it.
[ -n "$entries" ] || entries="N:"

# ---------------------------------------------------------------- job 2: arm the reminder
# On any harness edit -- independent of whether the suite pins this file. The marker is a
# line-oriented LEDGER now rather than a bare flag: `G:<gate>` means that gate's section is
# owed a run, `N:` means an edit whose only relevant coverage is the always-on suite-level
# assertions. run-check-gates-full.sh sweeps exactly those and falls back to the full pass
# on anything it cannot account for.
if [ -r "$claude_root/hooks/lib-claude-paths.sh" ]; then
  # shellcheck disable=SC1091
  . "$claude_root/hooks/lib-claude-paths.sh" 2>/dev/null || true
  if command -v hstate >/dev/null 2>&1; then
    _marker="$(hstate notices .check-gates-full-run-owed 2>/dev/null)"
    _digest="$(hstate notices check-gates-reminder.txt 2>/dev/null)"
    if [ -n "${_marker:-}" ]; then
      [ -e "$_marker" ] || printf '# gate sections owed a pass since the last green run\n' \
        > "$_marker" 2>/dev/null
      # Append each entry at most once. Concurrent sessions need no lock: an append is a
      # single printf, and a duplicate would only cost the consumer a repeated filtered
      # run, which it de-duplicates anyway.
      printf '%s\n' "$entries" | while IFS= read -r _e; do
        [ -n "$_e" ] || continue
        grep -qxF "$_e" "$_marker" 2>/dev/null || printf '%s\n' "$_e" >> "$_marker" 2>/dev/null
      done
    fi
    # Digest line once per session while the marker STANDS, not only when creating it.
    # on-prompt.sh:777 DRAINS the digest as it relays, and the daily task that used to
    # refill it deleted itself. Tying the line to creation made the whole reminder a
    # one-shot: the marker would sit armed and silent forever after its first mention.
    # Once per session x still-owed = the daily nag's cadence, without the task.
    if ! grep -qxF '__armed__' "$NUDGEFILE" 2>/dev/null; then
      if [ -n "${_digest:-}" ] && [ -e "${_marker:-/nonexistent}" ]; then
        printf '%s a check-gates.sh pass is owed (harness files edited, none since) -- run "bash scripts/run-check-gates-full.sh" from the harness repo when the machine is quiet; it sweeps only the sections your edits touched and clears this on green.\n' \
          "$(date '+%Y-%m-%d %H:%M')" >> "$_digest" 2>/dev/null
      fi
      printf '__armed__\n' >> "$NUDGEFILE" 2>/dev/null
    fi
  fi
fi

# ------------------------------------------------------------------ job 1: nudge the edit

[ "$pinned" = "yes" ] || exit 0

# One nudge per session per file.
key="$(lower "$rel")"
grep -qxF "$key" "$NUDGEFILE" 2>/dev/null && exit 0
printf '%s\n' "$key" >> "$NUDGEFILE" 2>/dev/null

if [ -n "$gate_name" ]; then
  how="bash scripts/check-gates.sh --gate $gate_name"
else
  # A non-gate file is asserted inside some gate's section -- name it instead of saying
  # "<any gate.sh>". Today that sent an agent editing scripts/mutate-gates.sh to an
  # arbitrary gate when check-gates-unfiltered-gate.sh is the section that covers it.
  _g="$(printf '%s\n' "$entries" | grep '^G:' | head -1 | cut -c3-)"
  if [ -n "$_g" ]; then
    how="bash scripts/check-gates.sh --gate $_g"
  else
    how="bash scripts/check-gates.sh --gate <any gate.sh>"
  fi
fi

reason="Edited $rel, which scripts/check-gates.sh asserts about -- run the suite before you call this done: \`$how\` (~10s). Suite-level assertions run under ANY filter, so a filtered run covers static cross-file pins too. This exists because 4e54f3b changed a file the suite pinned by literal string, never ran the suite, and left it red. If the suite's assertion is the thing that is now wrong, update the assertion rather than reverting your edit."

jq -cn --arg r "$reason" '{decision:"block", reason:$r}'
