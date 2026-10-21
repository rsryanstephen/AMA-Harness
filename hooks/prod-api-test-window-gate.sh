#!/usr/bin/env bash
# dispatch: fail-closed-on-timeout -- a dispatcher timeout DENIES instead of skipping (hooks/dispatch.sh, 2026-10-15).
# PreToolUse hook (Bash|PowerShell). Denies triggering either PRODUCTION api-testing
# pipeline inside the prohibited window: Mon-Fri, 9am-5pm Eastern.
#
# `ama-deploy-release` Step 5a has carried that rule as prose since it was set by explicit
# user instruction, and prose nearly shipped the failure it forbids: the step told agents to
# resolve ET with `TZ=America/New_York date`, warning only that the `%Z` LABEL might be
# wrong and to "trust the hour". git-bash on this machine ignores `TZ` entirely -- `TZ=UTC`,
# `TZ=America/New_York` and `TZ=Asia/Tokyo` all print the identical time -- so the HOUR is
# wrong too, by 4 hours. Following the step as written would have fired both Production
# API-test pipelines at 12:34 ET, mid-business-hours, against production, with the user's
# standing instruction being not to. Caught only because a cross-check against UTC happened
# to be in the same note. Step 5a is fixed, but a rule an agent has to remember to apply,
# whose failure is silent and lands on production, is exactly what belongs in a gate.
#
# ET is resolved with python's zoneinfo (real tzdata), never `TZ=` or a UTC offset guess.
#
# FAILS CLOSED, unlike hotfix-version-claimed-gate.sh and the other network-dependent gates
# in this repo. Those fail open because a missing token must not wedge an urgent hotfix; here
# the failure mode this gate exists to stop IS an unresolvable/wrong clock, so treating "I
# could not read the time" as "go ahead" would reproduce the original defect exactly. python
# with zoneinfo is present on this machine (verified: ET=14:49 Wed offset=-0400 EDT while
# UTC read 18:49), so the closed path is a real error, not a routine state.
#
# Escape hatch: AMA_ALLOW_PROD_API_TESTS=1 in the environment. Deliberately an env var the
# USER sets, not anything an agent produces by following the skill -- the deadlock lesson
# from hotfix-version-claimed-gate.sh is that a "claimed"/"approved" signal the skill itself
# tells the agent to emit is no signal at all.
set -u

payload="$(cat)"

# Cheap needle on the RAW payload before any jq fork (precedent inplace-edit-gate.sh).
# Literal QUOTED: the public mirror's scrub swaps it for a `<...>` placeholder.
case "$payload" in *'<repository>-api-testing'*) : ;; *) exit 0 ;; esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null | tr -d '\r')"
[ -n "$command" ] || exit 0

# Heredoc bodies are DATA. Without this scoping a commit message or doc edit that merely
# DESCRIBES this hazard self-denies -- the trap inplace-edit-gate.sh fell into on its own
# first commit.
. "$HOME/.claude/hooks/lib-command-text.sh" 2>/dev/null || command_scan_region() { printf '%s' "$1"; }
head_region="$(command_scan_region "$command")"

# All three signals must be in the same command: the api-testing repo, a pipelines POST, and
# a `production` custom selector. `production` also prefix-matches `production_exports`, the
# second of the two serial runs. A `staging`/`qa` selector, or a pipelines call against any
# other repo, is none of this gate's business.
case "$head_region" in *'<repository>-api-testing'*) : ;; *) exit 0 ;; esac
case "$head_region" in *pipelines*) : ;; *) exit 0 ;; esac
printf '%s' "$head_region" | grep -qE '"pattern"[[:space:]]*:[[:space:]]*"production' || exit 0

[ "${AMA_ALLOW_PROD_API_TESTS:-}" = "1" ] && exit 0

deny() {
  jq -cn --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# ET resolution and the window predicate are lib-et-now.sh's -- this gate used to carry
# its own "proven inline copy, left alone deliberately", which is the exact state the two
# Octopus deploy gates were in until a fix reached one of them and not the other
# (2026-09-15). The deny REASONS stay here; they are the only gate-specific part.
. "$HOME/.claude/hooks/lib-et-now.sh" 2>/dev/null || deny "Could not load hooks/lib-et-now.sh, so this production API-test trigger cannot be cleared against the 9am-5pm ET Mon-Fri window. This gate fails CLOSED on purpose. Resolve ET with python zoneinfo (never TZ=... date -- git-bash ignores TZ), and once confirmed outside the window re-run with AMA_ALLOW_PROD_API_TESTS=1."
state="$(et_window_state)"

if [ "$state" = "unresolved" ]; then
  deny "Could not resolve Eastern time (python/zoneinfo unavailable), so this production API-test trigger cannot be cleared against the 9am-5pm ET Mon-Fri prohibited window. This gate fails CLOSED on purpose: the defect it exists to stop is a silently wrong hour firing production tests mid-business-hours. Resolve ET yourself with: python -c \"from datetime import datetime; from zoneinfo import ZoneInfo; print(datetime.now(ZoneInfo('America/New_York')).strftime('ET=%H:%M %a offset=%z %Z'))\" -- if the printed ET equals UTC the lookup failed, do not act on it. Do NOT use TZ=America/New_York date; git-bash ignores TZ here. Once confirmed outside the window, re-run with AMA_ALLOW_PROD_API_TESTS=1."
fi

case "$state" in utcmatch*) et_hm="${state#utcmatch }" ;; *) et_hm="" ;; esac
if [ -n "$et_hm" ]; then
  deny "Eastern time read back identical to UTC ($et_hm) -- the zoneinfo lookup failed rather than resolving ET, which is exactly the failure mode that nearly fired these pipelines at 12:34 ET. Do not act on that reading. Re-resolve ET, and once genuinely outside the 9am-5pm ET Mon-Fri window re-run with AMA_ALLOW_PROD_API_TESTS=1."
fi

case "$state" in
  inside*)
    pretty="${state#inside }"
    if true; then
      deny "Production API tests must not run during US business hours -- the blocked window is 9am-5pm Eastern, Mon-Fri (standing user instruction). It is currently ET=$pretty, inside the window. Timeshift to the next opening, don't skip the run: after 5pm ET today, or before 9am ET -- outside the window is fine in BOTH directions, so an early-morning slot is just as valid as an evening one. See ama-deploy-release Step 5a. Deferring = scheduling: set a durable reminder (scripts/reminder.sh add) for the next weekday 08:00 LOCAL (not 17:04 ET: the PC is off then) with the full task in the same turn -- deferred-window-reminder-check.sh blocks a deferral that sets none. If you have confirmed with the user that this specific run should go now anyway, re-run with AMA_ALLOW_PROD_API_TESTS=1."
    fi
    ;;
esac

exit 0
