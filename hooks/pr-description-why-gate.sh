#!/usr/bin/env bash
# PreToolUse gate (Bash|PowerShell). Denies creating a pull request whose description does not
# explain WHY the change was made. Your Name's rule, 2026-09-09: "an explanation of why the changes
# were made must be included in the PR description, but try to keep it brief."
#
# A title says what changed; only the description can say why, and a reviewer who has to
# reconstruct the reason from the diff is doing the author's job. Prose alone would not hold --
# CLAUDE.md's "Mechanical Triggers Over Self-Recognition".
#
# Scope: the RAW CURL form only (POST .../pullrequests with an inline -d body), which is what
# ama-bitbucket-api/SKILL.md points an agent at. The harness's own create-bitbucket-pr.sh
# enforces the same rule itself, at the point where it has the description as a clean argv
# element -- reparsing a quoted shell argument here would be guesswork, and a quote-blind match
# is how two earlier gates in this harness produced wrongful denials.
#
# Length is the only thing measurable mechanically; "does this actually explain why" is a
# judgement AGENTS.md carries. The bar is deliberately low -- it stops the empty and one-line
# cases that actually happen, not a short-but-real explanation.
set -u

MIN_CHARS=60

IFS= read -r -d '' payload || true
case "$payload" in *pullrequest*) ;; *) exit 0 ;; esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
[ -n "$command" ] || exit 0

printf '%s' "$command" | grep -qP 'curl\b' || exit 0
printf '%s' "$command" | grep -qP -- '-X\s*POST|--request\s+POST' || exit 0
printf '%s' "$command" | grep -qP '/pullrequests(\?|"|'"'"'|\s|$)' || exit 0

# A -d @file body is written by the Write tool first and is not readable as text here; let it
# through rather than guess. Same fail-open stance the payload-file gates take.
printf '%s' "$command" | grep -qP -- "-d\s*@|--data\s*@" && exit 0

# Pull the inline JSON body. Single- or double-quoted; take the longest brace-delimited run,
# which is the body in every real invocation shape.
body="$(printf '%s' "$command" | grep -oP '\{.*\}' | head -1)"
[ -n "$body" ] || exit 0

# Unparseable JSON (shell interpolation inside the body) -> not this gate's call. Test jq's
# own exit status directly: an `|| true` fallback would make a parse failure look like an
# empty description and deny it.
description="$(printf '%s' "$body" | jq -r '.description // empty' 2>/dev/null)" || exit 0

chars=${#description}
[ "$chars" -ge "$MIN_CHARS" ] && exit 0

if [ "$chars" -eq 0 ]; then
  found="no description at all"
else
  found="a ${chars}-char description"
fi
reason="This pull request has ${found}. Every PR description must briefly explain WHY the change was made -- the problem it fixes or the need it serves -- not just what changed (the title and diff already say that). Keep it brief: two or three sentences is the target, and the minimum here is only ${MIN_CHARS} characters. Add the reason to .description and retry."

jq -cn --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
