#!/usr/bin/env bash
# Stop hook. A reply that recommends approving a Terraform plan -- with or without an Octopus
# link -- must come after a THOROUGH review of that plan (user rule 2026-10-15): the mechanical
# pass (skills/ama-terraform-backbone/scripts/plan-review.sh: stateful destroys, real changes
# with list-shift noise removed, diff vs the previously approved plan) AND the judgment checks
# in that skill's "Before recommending a plan approval". Origin: ExporterPlus 2.0.0.114
# (2026-10-15) -- the user had to ask "is it completely safe?" before the real review happened.
#
# Fires when the last assistant text has an AFFIRMATIVE approval ask (approve the plan / safe to
# approve / approve here / please approve / ready to approve ...) in a paragraph that also names a
# plan, Terraform, Octopus or a ServerTasks id. Sentences with never/don't/do not/reject/unless
# are dropped first, so a warning ("never approve a plan that deletes a DB") is not an ask.
# Silent when the recent transcript ran plan-review.sh -- on EACH ServerTasks id the reply names,
# or on anything at all when it names none (a local plan: plan-review.sh --file).
# `stop_hook_active` honoured: a resumed turn is never blocked twice.
set -u
payload="$(cat)"
case "$payload" in *"stop_hook_active\":true"*) exit 0 ;; esac
tr_path="$(printf '%s' "$payload" | jq -r '.transcript_path // empty')"
[ -n "$tr_path" ] && [ -f "$tr_path" ] || exit 0

text="$(tail -n 200 "$tr_path" 2>/dev/null | jq -s -r '[.[] | select(.type=="assistant")] | last | .message.content[]? | select(.type=="text") | .text' 2>/dev/null | tr -d '\r')"
[ -n "$text" ] || exit 0
case "$text" in *[Aa]pprov*) ;; *) exit 0 ;; esac

hit="$(printf '%s\n\n' "$text" | awk '
  BEGIN { para="" }
  /^[[:space:]]*$/ { if (para != "") { print para; print "\x01" }; para=""; next }
  { para = (para=="" ? $0 : para " " $0) }
' | awk -v RS='\x01' '
  {
    p = tolower($0)
    n = split(p, s, /[.!?] /); keep = ""
    for (i = 1; i <= n; i++) if (s[i] !~ /never|don.t|do not|reject|unless|refuse/) keep = keep " " s[i]
    ask = (keep ~ /approve (the|this|that|it|both|each)|safe to approve|approve here|please approve|go ahead and approve|ready (to|for) approv|you can approve|approve it in octopus|approve the terraform/)
    ctx = (keep ~ /plan|terraform|octopus|servertasks-[0-9]/)
    if (ask && ctx) { print; exit }
  }')"
[ -n "$hit" ] || exit 0

recent="$(tail -n 800 "$tr_path" 2>/dev/null | grep -o 'plan-review\.sh[^"\\]*' )"
ids="$(printf '%s' "$text" | grep -oE 'ServerTasks-[0-9]+' | sort -u)"
missing=""
if [ -n "$ids" ]; then
  for t in $ids; do printf '%s' "$recent" | grep -q "plan-review\.sh $t" || missing="$missing $t"; done
else
  [ -n "$recent" ] || missing=" (the plan you are recommending)"
fi
[ -n "$missing" ] || exit 0

jq -cn --arg m "$missing" '{decision:"block", reason:("PLAN APPROVAL RECOMMENDED WITHOUT A THOROUGH REVIEW of" + $m + ". User rule 2026-10-15: never tell the user to approve a Terraform plan (link or not) before reviewing it. Run `bash ~/.claude/skills/ama-terraform-backbone/scripts/plan-review.sh <ServerTasks-N> [<last approved ServerTasks-N>]` (or `--file <plan.txt>` for a local plan), then do the judgment checks in ama-terraform-backbone SKILL.md \"Before recommending a plan approval\" (every change intended and explained, nothing stateful destroyed, removed things provably dead, shared settings, availability, rollback). Then rewrite the recommendation with the findings -- or say not to approve.")}'
exit 0
