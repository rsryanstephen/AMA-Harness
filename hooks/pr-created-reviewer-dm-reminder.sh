#!/usr/bin/env bash
# PostToolUse hook (Bash|PowerShell). Nudges Claude to DM each reviewer a link right after a
# pull request is actually created. Your Name's rule, 2026-09-09: "when PRs are created, the
# reviewers receive a DM with a link to the PR" -- a reviewer who is never told has to notice
# the PR themselves, which is exactly the hand-off that gets missed.
#
# Hook, not prose, per CLAUDE.md's "Mechanical Triggers Over Self-Recognition" -- same pattern
# and same reasoning as library-version-sync-reminder.sh, which this is modelled on.
#
# It cannot send the DM itself: Slack in this harness is MCP-only (no bot token anywhere -- the
# only slack file in hooks/ is slack-brevity-gate.sh, and skills/slack-search has no scripts).
# So this resolves WHO to DM and hands Claude the link. Fires on every real PR creation, no
# de-dupe -- same philosophy as its sibling hooks.
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork (precedent: aggregation-secret-gate.sh).
# BOTH tokens are needed: the curl form carries "pullrequests" (API path, no hyphen) but the
# script form need not mention it at all -- its command is just the script name, and the URL in
# the response is the *hyphenated* "pull-requests". Filtering on "pullrequest" alone silently
# dropped every script-form PR (caught in this hook's own test run, 2026-09-09).
case "$payload" in *pullrequest*|*create-bitbucket-pr*) ;; *) exit 0 ;; esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
[ -n "$command" ] || exit 0

# Two ways a PR gets created here: the harness script, or a raw curl POST. Require a real
# invocation prefix on the script form -- a bare substring match self-triggers on a git commit
# message that merely names the script (the trap ticket-in-progress-reminder.sh documents).
is_pr_create=""
printf '%s' "$command" \
  | grep -qP '(^|[;&|]\s*)(bash|sh|pwsh|powershell(\.exe)?)\s+"?\S*create-bitbucket-pr\.sh|(^|[;&|]\s*)\.[/\\]\S*create-bitbucket-pr\.sh' \
  && is_pr_create="script"
if [ -z "$is_pr_create" ]; then
  # curl form: must be a POST *to* the pullrequests collection, not a GET listing one.
  printf '%s' "$command" | grep -qP 'curl\b' \
    && printf '%s' "$command" | grep -qP -- '-X\s*POST|--request\s+POST' \
    && printf '%s' "$command" | grep -qP '/pullrequests(\?|"|'"'"'|\s|$)' \
    && is_pr_create="curl"
fi
[ -n "$is_pr_create" ] || exit 0

# Only nudge when it SUCCEEDED. create-bitbucket-pr.sh prints the html URL on success and
# nothing on failure; a raw curl returns the created PR JSON. Either way the response carries a
# bitbucket PR link. No tool_response at all -> fail open and nudge (same stance as
# ticket-in-progress-reminder.sh).
resp="$(printf '%s' "$payload" | jq -r '.tool_response // empty | if type == "string" then . else tojson end')"
pr_url=""
if [ -n "$resp" ]; then
  pr_url="$(printf '%s' "$resp" | grep -oP 'https://bitbucket\.org/[^"\\ ]+/pull-requests/[0-9]+' | head -1)"
  [ -n "$pr_url" ] || exit 0
fi

CONFIG="$HOME/.claude/harness-config.json"
[ -f "$CONFIG" ] || exit 0

# Who to tell: the configured default reviewers, resolved to Slack ids through .audiences.
#
# Match on the FIRST NAME, case-insensitively -- the two config blocks disagree on name form.
# .bitbucket.defaultPrReviewers holds full names ("Reviewer One"); .audiences.people holds the
# short name the audience policy speaks in ("Reviewer One"). An exact match resolves nobody, which is
# how this hook first came out naming a reviewer with "no Slack id" while the id sat in the
# same file (2026-09-09). Collect the ids into an array before testing length: a bare stream
# bound with `as` yields nothing when empty and silently drops the whole entry.
#
# A reviewer with no Slack id still gets named -- better to be told "no id on file" than to
# silently drop someone from the hand-off.
who="$(jq -r '
  def first_name: (. // "") | ascii_downcase | split(" ")[0];
  (.audiences.people // []) as $people
  | [ (.bitbucket.defaultPrReviewers // [])[]
      | .name as $n
      | ([ $people[] | select((.name | first_name) == ($n | first_name)) | .slackUserIds[]? ]) as $ids
      | if ($ids | length) > 0 then "\($n) (\($ids[0]))" else "\($n) (no Slack id in .audiences)" end ]
  | join(", ")
' "$CONFIG" 2>/dev/null | sed 's/\r$//')"
[ -n "$who" ] && [ "$who" != "null" ] || exit 0

link="${pr_url:-the PR you just created}"

# Merge-on-approval watcher (user instruction 2026-10-14): every PR Claude opens is merged the
# moment a reviewer approves it. Started here, detached, so it is mechanical -- not a nudge the
# model may skip. nohup + & + disown is the headless-prune-check.sh precedent (no setsid on
# this msys). pr-watch-check.sh (on-prompt) restarts it if the process dies. The ORIGIN session
# id rides along so the merge reminder wakes THIS session first. PR_WATCH_NO_SPAWN=1 is the
# test seam. No URL in the response (fail-open nudge) -> nothing to watch.
watch_note=""
if [ -n "$pr_url" ] && [ -z "${PR_WATCH_NO_SPAWN:-}" ]; then
  slug="$(printf '%s' "$pr_url" | sed -E 's#https://bitbucket\.org/[^/]+/([^/]+)/pull-requests/([0-9]+).*#\1#')"
  prid="$(printf '%s' "$pr_url" | sed -E 's#.*/pull-requests/([0-9]+).*#\1#')"
  sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
  watch_script="$HOME/.claude/skills/ama-bitbucket-api/scripts/pr-merge-watch.sh"
  if [ -n "$slug" ] && [ -n "$prid" ] && [ -f "$watch_script" ]; then
    { nohup bash "$watch_script" "$slug" "$prid" ${sid:+--sid "$sid"} >/dev/null 2>&1 & } 2>/dev/null
    disown 2>/dev/null || true
    watch_note=" A merge-on-approval watcher is now running for it (pr-merge-watch.sh ${slug} ${prid}): it merges the PR as soon as a reviewer approves and wakes this session with a durable reminder -- do not poll the PR yourself."
  fi
fi

reason="Pull request created (${link}). DM the reviewer(s) the link now, don't wait to be asked -- Your Name's standing rule is that reviewers are told directly when a PR is theirs to review. Reviewers: ${who}. Use the Slack MCP tool (slack_send_message to the user id). Keep it to a line or two: what changed, why, and the link -- memory/slack-messages-terse.md (fewest words possible) and the audience policy for that person's level both apply, and it needs the 'Sent from Claude' disclosure line (memory/ai-disclosure-footer.md). If the PR's actual reviewers differ from the configured defaults above, DM the real ones.${watch_note}"

jq -cn --arg r "$reason" '{decision:"block", reason:$r}'
