#!/usr/bin/env bash
# PreToolUse hook (Bash|PowerShell). Denies launching verify-qa-deploy.sh /
# verify-deployment-e2e.sh until the user has explicitly said yes for THIS session --
# docs already said "never run unprompted" in three places (DEPLOY-VERIFICATION.md,
# commit-ticket/SKILL.md) and it still got skipped (launched anyway, reported as
# already-decided). Same pattern as jira-fixversion-confirm-gate.sh.
# Confirmation is ONE-SHOT (per explicit user choice) -- not valid for a later push in the
# same session. Also wired PostToolUse (dispatch-post-bash.manifest): PreToolUse allows,
# PostToolUse consumes, so a call another gate denied never burns it. Recorded via
# confirm-deploy-verify.sh into harness-state/tickets/.deploy-verify-approved, keyed by session_id.
#
# Match requires an actual invocation prefix (bash/sh/pwsh/powershell/./), not just the
# script name anywhere in the command text -- a bare substring match self-triggered on
# this hook's OWN synthetic test payloads (a `jq --arg` call building test JSON quoted
# the script name, no real invocation) -- same quote-blind trap bare-cd-gate.sh's
# comments already document. Known remaining gap: a command that quotes a full
# `bash .../verify-qa-deploy.sh` invocation as inert text (e.g. `echo "run bash ..."`)
# still matches -- accepted, same tradeoff bare-cd-gate.sh makes.
set -u
. "$HOME/.claude/hooks/lib-claude-paths.sh"

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork (precedent:
# aggregation-secret-gate.sh) -- the invocation regex below requires one of these two
# literal script names, so a payload without either can exit on zero forks. False
# positives fall through to the unchanged full logic; ~60ms/fork on this machine.
case "$payload" in *verify-qa-deploy*|*verify-deployment-e2e*) ;; *) exit 0 ;; esac
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
event="$(printf '%s' "$payload" | jq -r '.hook_event_name // "PreToolUse"')"

[ -n "$command" ] || exit 0
printf '%s' "$command" | grep -qP '(^|[;&|]\s*)(bash|sh|pwsh|powershell(\.exe)?)\s+"?\S*(verify-qa-deploy|verify-deployment-e2e)\.sh|(^|[;&|]\s*)\.[/\\]\S*(verify-qa-deploy|verify-deployment-e2e)\.sh' || exit 0
[ -n "$sid" ] || exit 0

FILE="$(hstate tickets .deploy-verify-approved)"

# What this run would verify: `<repo>:<version>`, from the command's own arguments -- the
# repo is the first argument after the script, the version any dotted-numeric token (arg 5
# of verify-qa-deploy.sh, derived by verify-deployment-e2e.sh). An approval carrying a
# DIFFERENT scope is not re-usable: a fix that changes what is being deployed goes back to
# the user rather than being re-armed on the earlier yes (user instruction 2026-09-22).
# An approval recorded with an EMPTY scope still unlocks any run -- given before the
# expected version is known, which is normal.
req_repo=""; req_version=""
# Quotes stripped first: the documented invocation quotes the script path
# (bash "$HOME/.claude/skills/.../verify-qa-deploy.sh" <repo> ...), so a token-suffix match
# on the script name misses and the repo silently reads as empty -- which would compare two
# scopes that differ only by a quoting accident.
cmd_tokens="${command//\"/}"
cmd_tokens="${cmd_tokens//\'/}"
for tok in $(printf '%s' "$cmd_tokens" | tr -s ' \t' '\n\n'); do
  case "$tok" in
    *verify-qa-deploy.sh|*verify-deployment-e2e.sh) req_repo="PENDING"; continue ;;
  esac
  [ "$req_repo" = "PENDING" ] && { req_repo="$tok"; continue; }
  case "$tok" in
    [0-9]*.[0-9]*.[0-9]*) [ -z "$req_version" ] && req_version="$tok" ;;
  esac
done
[ "$req_repo" = "PENDING" ] && req_repo=""
req_scope="$req_repo:$req_version"

if [ -f "$FILE" ]; then
  approved_scope=""
  matched_row=""
  # Read the RAW line and split it here, rather than letting `read` do it: a pre-scope
  # approval is a bare sid with no tab at all, and reconstructing "sid<TAB>scope" for it
  # produces a line that is not in the file, so `grep -vxF` removes nothing and the
  # approval is never consumed -- it would then unlock every later run in the session.
  while IFS= read -r line || [ -n "$line" ]; do
    row_sid="${line%%	*}"
    case "$line" in *"	"*) row_scope="${line#*	}" ;; *) row_scope="" ;; esac
    [ "$row_sid" = "$sid" ] || continue
    if [ -z "$row_scope" ] || [ "$row_scope" = "$req_scope" ]; then
      matched_row="$line"
      break
    fi
    [ -z "$approved_scope" ] && approved_scope="$row_scope"
  done < "$FILE"

  if [ -n "$matched_row" ]; then
    # One-shot, consumed on PostToolUse -- i.e. only once the call actually RAN. Consuming
    # at PreToolUse burned the approval when a sibling gate (short-path-gate.sh) denied the
    # same call: one "check it on QA" needed 3 re-confirms (harness-gaps 2026-10-06).
    [ "$event" = "PostToolUse" ] || exit 0
    # e2e consumes for itself on entering Stage 3 (confirm-deploy-verify.sh --consume): a run
    # that stopped at Stage 1/2 verified nothing, so the rerun keeps the yes (user decision
    # 2026-10-12). Only a direct verify-qa-deploy.sh call is consumed here.
    case "$command" in *verify-deployment-e2e*) exit 0 ;; esac
    # NOTE: grep -v exits 1 when it excludes the only/last line (nothing selected) --
    # confirmed live -- so this must NOT be `grep ... && mv ...` or the mv silently never
    # runs and the approval never actually gets consumed. mv unconditionally instead.
    grep -vxF "$matched_row" "$FILE" > "$FILE.tmp"
    mv "$FILE.tmp" "$FILE"
    exit 0
  fi

  [ "$event" = "PostToolUse" ] && exit 0   # post side only consumes, never denies
  if [ -n "$approved_scope" ]; then
    jq -cn --arg sid "$sid" --arg approved "$approved_scope" --arg req "$req_scope" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: ("Deploy verification was approved for " + $approved + ", but this run verifies " + $req + " -- what is being deployed has CHANGED, so the earlier yes does not carry over. Ask the user again, naming what changed (a failed deploy whose cause you then fixed is exactly this case, not a repeat of the same verification). On yes: `bash \"$HOME/.claude/hooks/confirm-deploy-verify.sh\" " + $sid + " " + $req + "`.")
      }
    }'
    exit 0
  fi
fi
[ "$event" = "PostToolUse" ] && exit 0

jq -cn --arg sid "$sid" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Deploy verification not yet approved by the user this session. Ask first (yes/no) -- declining is a normal answer for a small fix, not a fallback. On yes, run `bash \"$HOME/.claude/hooks/confirm-deploy-verify.sh\" " + $sid + "` then re-run this command. Never call this script from a subagent that returns before it finishes -- launch it from the main session with run_in_background instead, so the completion notification actually fires.")
  }
}'
