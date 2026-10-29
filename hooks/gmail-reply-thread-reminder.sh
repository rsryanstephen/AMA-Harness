#!/usr/bin/env bash
# PostToolUse hook (mcp__*__create_draft, mcp__*__update_draft). Tells Claude to verify a
# reply draft actually landed on the intended thread.
#
# Trap 1 -- create_draft, confirmed live 2026-08-18: passing the id of an INBOUND message
# (the other party's reply) produced a draft on a BRAND-NEW thread, detached from the
# conversation -- list_drafts showed threadId 1a016037939c2912 against the real chain's
# 1a0004ef44cd6154. Re-creating it against the thread's LAST message (our own most recent
# sent one) threaded correctly. The user caught it, not us, and an unnoticed send would
# have arrived outside the chain.
#
# Trap 2 -- update_draft, confirmed live 2026-08-19 and AGAIN 2026-08-20: updating only the
# BODY of an already-correctly-threaded reply draft DETACHES it. threadId came back equal to
# its own messageId (1a01f6894b0ca810), i.e. its own new thread, while the chain it belonged
# to was 1a0004ef44cd6154. There is no reply-target field on update_draft to preserve, so
# there is no way to update a reply draft in place -- the only fix is re-create.
#
# Trap 2 was already written up in gmail-drafting's step 2c after the 2026-08-19 incident
# and a later session walked straight into it anyway, because the note only fires if you
# happen to re-read the skill mid-task. Per CLAUDE.md's "Mechanical Triggers Over
# Self-Recognition", prose that has already failed once gets a hook behind it.
#
# Same "nudge, not verify" shape as backlog-page-reminder.sh / git-push-ticket-reminder.sh
# -- hooks have no Gmail access, so this cannot check threadId itself. It names the one
# cheap call that can. Also cannot be a PreToolUse gate: for create_draft, whether a given
# message id is the thread's last is only knowable from Gmail; for update_draft, whether the
# target draft is a reply is likewise not in the payload.
#
# Deliberately silent on a NEW-thread create_draft (no replyToMessageId) -- those are
# supposed to start their own thread, and nagging every draft would train the nudge away.
# update_draft always nudges: the payload cannot tell us whether the draft is a reply, and
# the cost of a redundant nudge on a new-thread draft is far below the cost of a silent
# detach.
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork (precedent: aggregation-secret-gate.sh)
# -- a tool-name literal substring must be present. ~60ms/fork on this machine.
case "$payload" in *create_draft*|*update_draft*) ;; *) exit 0 ;; esac

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"

case "$tool" in
  mcp__*__update_draft)
    draft="$(printf '%s' "$payload" | jq -r '.tool_input.draftId // empty')"
    jq -cn --arg d "$draft" '{decision:"block", reason:("update_draft ran on draft " + $d + ". If that draft was a REPLY, it has just been DETACHED from its thread -- confirmed live twice (2026-08-19, 2026-08-20): updating only the body re-creates it as its own thread, threadId == its own messageId. There is no reply-target field on update_draft, so a reply draft can never be updated in place. VERIFY NOW: call list_drafts and check this draft'"'"'s threadId still equals the intended thread'"'"'s id. If it detached: create_draft again against the thread'"'"'s LAST message id (get_thread -> last, usually our own most recent sent message), then clear the stray with trash_message on the DRAFT'"'"'s messageId -- reversible, and gmail-drafting step 2c already sanctions doing that unprompted for a Claude-created stray from moments ago. Get the wording right BEFORE creating a reply draft; never plan to update one. See gmail-drafting step 2c.")}'
    exit 0
    ;;
  mcp__*__create_draft) ;;
  *) exit 0 ;;
esac

reply_to="$(printf '%s' "$payload" | jq -r '.tool_input.replyToMessageId // empty')"
[ -n "$reply_to" ] || exit 0

jq -cn --arg r "$reply_to" '{decision:"block", reason:("Reply draft created against message " + $r + ". VERIFY IT THREADED before calling it ready: call list_drafts and confirm the new draft'"'"'s threadId equals the intended thread'"'"'s id. Replying to an INBOUND message id can silently spawn a NEW thread -- confirmed live 2026-08-18, the draft looked fine and create_draft returns only {id}, so nothing surfaces it. If the threadId is wrong: get_thread on the real chain, take its LAST message id (usually our own most recent sent message, not the other party'"'"'s reply), and create the draft again against that -- update_draft CANNOT fix it, it DETACHES a reply draft instead, so the mis-threaded draft has to be replaced and the stray one discarded by the user. See gmail-drafting.")}'
