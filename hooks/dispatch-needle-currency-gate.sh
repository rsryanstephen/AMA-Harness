#!/usr/bin/env bash
# PostToolUse hook (Edit|Write). Edited a gate that hooks/dispatch.sh DISPATCHES -- or the
# dispatcher/extractor themselves -- so the needle prefilter may no longer match what that
# gate decides on. Say so, and name the command that proves it.
#
# Why this is a hook and not a paragraph (2026-09-18, <harnessEpicKey>): the dispatcher only
# spawns a gate whose extracted needle matches the payload, so a gate whose needle drifts
# STOPS FIRING SILENTLY -- the call runs unguarded and looks exactly like a pass. That is the
# same class GATES-AND-HOOKS.md records as unexplained for psql/mongo, and the reason the
# extractor's own bugs (taking only the first of several `case "$payload"` prefilters;
# re-interpreting `*'\n'*` as `*\n*`) were invisible until something replayed real payloads
# through the real dispatcher. CLAUDE.md's "Mechanical Triggers Over Self-Recognition"
# applies exactly: a rule that fires "after someone edits a gate" needs a hook behind it.
#
# Deliberately a separate small hook rather than a third job inside
# check-gates-currency-gate.sh: that file is 187 lines, check-gates.sh asserts about it, and
# it already does two jobs in one fork. This costs one extra fork on Edit|Write only -- NOT
# on the hot Bash path this whole change exists to thin out.
set -u

payload="$(cat)"

# Raw-payload needle before any jq fork (GATES-AND-HOOKS.md fork budget).
case "$payload" in *ama-claude-harness*|*.claude*) ;; *) exit 0 ;; esac

sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')"
[ -n "$sid" ] && [ -n "$file_path" ] || exit 0

harness="$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$harness" ] || exit 0
base="$(basename "$(printf '%s' "$file_path" | tr '\134' '/')")"

why=""; flag=""
case "$base" in
  dispatch.sh|build-needle-cache.sh)
    why="hooks/$base IS the dispatcher/extractor" ;;
  *.sh)
    # A dispatched gate: its name sits in a manifest's second column. Two manifests since
    # 2026-09-18 (PreToolUse and PostToolUse halves of the Bash|PowerShell block).
    for m in "$harness/hooks/dispatch-pre-bash.manifest" "$harness/hooks/dispatch-post-bash.manifest"; do
      [ -f "$m" ] || continue
      if grep -q "	$base	" "$m" 2>/dev/null; then
        why="hooks/$base is dispatched by hooks/dispatch.sh (${m##*/})"
        case "$m" in *post*) flag=" --post" ;; esac
        break
      fi
    done
    ;;
esac
[ -n "$why" ] || exit 0

# One nudge per session per file.
STATED="$HOME/.claude/.session-chatfiles"
mkdir -p "$STATED" 2>/dev/null
NUDGE="$STATED/$sid.dispnudge"
grep -qxF "$base" "$NUDGE" 2>/dev/null && exit 0
printf '%s\n' "$base" >> "$NUDGE" 2>/dev/null

reason="$why, so its needle prefilter may no longer match everything it decides on -- and a gate whose needle drifts too narrow STOPS FIRING SILENTLY: the call runs unguarded and looks exactly like a pass. Prove it before calling this done: \`bash scripts/check-dispatch-equivalence.sh$flag\` (~1-2 min, reuses the last payload trace; add --full to re-harvest; the dispatcher itself needs both the bare and the --post run). If you changed the EXTRACTOR rather than one gate, also run \`bash scripts/check-dispatch-equivalence.sh --mutate\`, which narrows a real needle and asserts the check goes red -- a check that cannot fail is worse than no check. A needle that is too BROAD only costs one spawn; too narrow is the bug that matters, so widen when unsure."

jq -cn --arg r "$reason" '{decision:"block", reason:$r}'
