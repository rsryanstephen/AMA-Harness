#!/usr/bin/env bash
# PreToolUse hook (Edit|Write). RECORDER, not a gate: notes that this session edited this
# file, prints nothing, decides nothing, and can never block an edit. The warning built on
# it fires at COMMIT time, inside cross-session-repo-claim.sh -- see lib-file-claims.sh's
# header for why that is the right moment (PROJ-15368).
#
# Fork budget. This is the tenth hook on the Edit|Write path; a 2026-09-01 solo baseline put
# the existing nine at 2.53s total, with the cheapest prefilter-and-exit gate at ~130ms --
# so bash startup dominates and anything extra shows. Hence NO jq (payload fields come out
# via bash regex) and no forks in fclaims_put. Measured cost of this hook is in AGENTS.md
# next to that baseline; if a change here pushes it up, say so rather than absorbing it.
#
# Toggle: FILE_CLAIMS=off skips recording entirely. Unlike a `model:` in frontmatter this
# genuinely does disable the feature -- the ledger is only ever written here, and the
# consumer stays silent on an empty/absent file.
set -u

[ "${FILE_CLAIMS:-}" = "off" ] && exit 0

payload="$(cat | tr -d '\r')"

# Cheap pure-bash prefilter before sourcing anything (GATES-AND-HOOKS.md fork-budget
# convention): no file_path in the payload -> nothing to record.
case "$payload" in *'"file_path"'*) ;; *) exit 0 ;; esac

# Bash regex, not jq: the two fields are flat strings and a jq fork here would be most of
# this hook's cost. A payload shape these don't match falls through to silence, which is the
# documented behaviour for ambiguity everywhere else in this hook set.
fp=""; sid=""
[[ "$payload" =~ \"file_path\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] && fp="${BASH_REMATCH[1]}"
[[ "$payload" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] && sid="${BASH_REMATCH[1]}"
[ -n "$fp" ] && [ -n "$sid" ] || exit 0

. "${BASH_SOURCE[0]%/*}/lib-file-claims.sh" 2>/dev/null || exit 0
fclaims_put "$fp" "$sid" 2>/dev/null || true
exit 0
