---
name: ama-pr-review
description: Review Bitbucket PRs assigned to (or created by) the user across the AMA fleet, filtered server-side, with real local repo context -- not a bulk unfiltered fetch. Use when the user says "review my PRs", "review open PRs assigned to me", or similar.
---

# AMA PR review

## Step 0 — Resolve the user's Bitbucket UUID (once)

Check `harness-config.json`'s `bitbucket.selfUuid` (already cached:
`<selfUuid>`). Missing/different adopter → resolve via
`GET /2.0/user` with the user's own Basic auth (see [[ama-bitbucket-api]]), write
`.uuid` back into `harness-config.json`, same pattern as the cached Jira accountId —
never re-look-up after that.

## Step 1 — Disambiguate scope if asked bluntly

"review PRs" alone (no "assigned to me"/"created by me") → ask which. Don't guess.

## Step 2 — Filtered discovery, looping locally-cloned repos in BOTH fleets

Bitbucket's cross-repo per-user endpoint (`GET /2.0/pullrequests/{selected_user}`)
404s against this workspace (tested live) — don't use it. The workspace also has 383
repos total, nearly all unrelated client codebases — looping all of them is wrong-scoped.

Loop `hooks/lib-harness-repos.sh`'s own index instead — real Bitbucket slugs, not
guessed from folder name:

```bash
bash ~/.claude/hooks/lib-harness-repos.sh index    # slug \t folder \t path \t fleet, BOTH fleets
```

**Loop both fleets — app-only misses everything.** ETL PRs are the norm, app-fleet PRs
the exception (per [[ama-app-solo-no-prs]]). Only covers repos cloned locally — a PR in
a never-cloned repo is invisible, not reported.

Per slug, query that repo's own PR endpoint (confirmed working live):

```bash
curl -sS -u "$(jq -r .user.email ~/.claude/harness-config.json):$BITBUCKET_API_KEY" \
  --get "https://api.bitbucket.org/2.0/repositories/yourorg/<repo-slug>/pullrequests" \
  --data-urlencode 'q=state="OPEN" AND reviewers.uuid="<selfUuid>"'
```

- "assigned to me" → `reviewers.uuid="<selfUuid>"` (excludes self-authored PRs,
  confirmed live that this filter is accepted).
- "created by me" → `author.uuid="<selfUuid>"` instead.
- **Assert each returned PR's own `state` is `OPEN`** before trusting it — a `q` clause
  can silently override a standalone `state=` param (hit live: 44 reported, 3 real).
- Drop anything whose `updated_on` is more than 30 days old (stale filter).

## Step 3 — Per PR, review with real repo context, fetch-only

1. Repo path already known from the Step 2 index row (column 3).
2. **Not cloned locally** → tell the user this repo needs cloning first; skip only
   this PR, keep going on any others that ARE cloned.
3. **Never check out the PR branch** — can clobber unpushed local commits (hit live).
   Fetch-only instead:
   - `git -C <repo> fetch origin <source-branch>` — fetch only, no checkout.
   - PR-side files: `git show FETCH_HEAD:<path>`. Base side: `git show origin/master:<path>`.
   - Surrounding context: `git grep <symbol> FETCH_HEAD` — greps the fetched tree,
     never touches the working tree.
4. Judge the diff against the rest of the repo's real code this way — the reason for
   pulling it locally rather than reviewing Bitbucket's raw diff text in isolation.

## Step 4 — Comment only on a real issue, verified against real code first

No "looks good" chatter. Before reporting a suspected bug anywhere, run
[[verify-before-reporting]] — a subagent's raw-diff read alone isn't enough, and
verifying can change the framing (e.g. "always wrong" → "wrong only when two inputs
diverge").

Sign every comment `-- Reviewed by Claude` (ASCII only). Post via
[[ama-bitbucket-api]]'s PR-comment section — anchor it on the offending line
(`inline.to`), not a top-level comment. Do not pass an em dash/emoji through a bash
argument, it silently corrupts on this machine.

**Then DM the PR author automatically** (a real issue, not "looks good" — no ask-first
here, by explicit user instruction): `slack_search_users` for their name → DM channel
id. Keep the DM itself short and hedged ("Claude flagged a possible bug here, may not
have full context, feel free to ignore") with the PR link — no technical detail in the
DM body. Put the actual notes (mechanism, why it's probably fine most of the time, the
condition that would trigger it) in a `slack_create_canvas`, then post the canvas link
as a **thread reply** under the DM (`thread_ts`), not a second top-level message. There
is no message-edit tool for this Slack integration — get the DM text right before
sending, since it can't be fixed after.

## Step 5 — Auto-approve if clean

No issues found → approve via `POST /2.0/repositories/yourorg/<repo>/pullrequests/<id>/approve`
automatically (explicit user instruction — a real API action with no per-PR
confirmation, by direct request). **Never approve a PR the user themselves authored**
(carries over [[ama-bitbucket-api]]'s existing rule) — moot for "assigned to me" scope
since Step 2 already excludes self-authored PRs there.

## Step 6 — Leave findings for future agents, correctly scoped

Anything discovered about a repo's real structure/conventions while reviewing → see
[[commit-ticket]]'s "Leave context for future agents" section (the canonical rules
both `ama-architecture-notes` and `ama-debugging-notes` already defer to) — don't
re-derive terseness/severity/ask-first rules locally, follow that section exactly.
