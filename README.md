# AMA Claude Harness

**This file is for humans.** It's a short install-and-use guide. For how the harness
actually works under the hood — hooks, gates, skills, failure modes — see `AGENTS.md`
instead; that's the file Claude reads for its own operation, and it's kept current
automatically. This file is **not** auto-updated — it only changes when someone edits it
because something a human does with the harness actually changed.

The harness is a set of Claude Code skills, hooks, and config that make Claude a more
capable teammate for the AMA_APP fleet: chat-log continuity across sessions, ticket/commit
discipline, deploy and debugging workflows, and guardrails that keep routine work from
hitting a wall of permission prompts.

## Installing on a new machine

**Prerequisites:**
- Windows, PowerShell 7+ (`pwsh`), Git for Windows (Git Bash), Claude Code installed.
- `git`, `jq`, `curl`, `perl`, `node` + `npm` on `PATH`.
- Developer Mode **on** (Settings → Privacy & security → For developers → Developer Mode)
  — needed for some of the installer's symlinks.
- **Python:** install as `python`, not `python3` — on Windows, `python3` commonly
  resolves to a non-functional Microsoft Store stub. Needed for release-notes PDF
  generation and the team-meeting-notes HTML splice.
- **Docker Desktop: turn Resource Saver off** (Settings → Resources → Advanced → untick
  *Enable Resource Saver*). If the laptop goes to sleep while Docker is resting in
  Resource Saver mode, Docker can fail to wake up afterwards. The tray icon still says
  it's running, but every `docker` command hangs, which breaks the Postgres and Mongo
  database skills until Docker Desktop is restarted. If it happens anyway, Claude checks
  whether this is the cause before suggesting the setting.

  ![Docker Desktop settings with Enable Resource Saver unticked](docs/docker-resource-saver-images/resource-saver-off.png)
- **Graylog access:** if you'll use log search, generate a Personal Access Token first.
  Auth is unusual — the PAT is the *username*, and the literal string `token` is the
  password (not your real password). Set it via:
  ```
  echo 'export GRAYLOG_PAT="your_actual_graylog_pat_here"' >> ~/.bashrc && source ~/.bashrc
  ```

### 1. Clone
```
git clone git@bitbucket.org:yourorg/ama-claude-harness.git
```
Any location — nothing hardcodes the clone path.

### 2. Run the installer
```
pwsh -File scripts\install.ps1
```
Links skills, hooks, and config into `~/.claude`, and merges the harness's shareable
hook/permission rules into your own `~/.claude/settings.json` without touching your
personal settings (model, theme, etc). Safe to re-run any time.

### 3. First run
Open Claude Code and run **`/harness-setup`** to personalize your config (email,
Jira/AWS/Octopus/Graylog identifiers). If your org already keeps this config in an
Octopus library variable set, setup is a one-line fetch instead of a Q&A — `/harness-setup`
tells you the command.

### 4. Required environment variables
Set whichever of these your work needs — each fails loudly and tells you what's missing
if you skip it and then hit a skill that needs it:
- `ATLASSIAN_API_TOKEN` — Jira/Confluence.
- `BITBUCKET_API_KEY` — Bitbucket REST API (pipelines, PRs).
- `GRAYLOG_PAT` — log search (see the auth quirk above).
- `OCTOPUS_API_KEY` — deployments.
- `MONGO_SSH_KEY_PASSPHRASE` — the cohorts/cohort-reports DB tunnel, if you use it.

### 5. Verify
- `Get-Item ~/.claude/skills`, `~/.claude/hooks`, `~/.claude/CLAUDE.md` each show a
  `LinkType` (confirms the symlinks/junctions landed).
- No permission-prompt storm on your first real task (confirms the settings merge worked).
- `/harness-setup`'s resulting config has no leftover `example.com`/`yourorg` placeholders.

### 6. Subscribe to the AWS certificate notices

Production certificate notices all arrive through one SNS topic,
`hs-production-certificate-lifecycle`: the Octopus→ACM sync-failure alarm, ACM's 45-day
expiry warning, and the sync Lambda's own "certificate re-imported" message. The installer
does **not** add you, and it isn't self-service — someone with the
`Backbone_Base_Certificates` Octopus project and approval rights has to do it, so don't
block your install on this:

**Do this first, whether or not you subscribe directly:**

1. **Allowlist `no-reply@sns.amazonaws.com` in Gmail.** Settings → Filters and Blocked
   Addresses → Create a new filter → From: `no-reply@sns.amazonaws.com` → Never send it to
   Spam. Every SNS mail so far has landed in spam — confirmation links *and* live notices —
   and a notice you never see is the same as no notice. This matters even if you only read
   the shared `<noticeSenders>` mail: the filter applies to your own inbox, which is
   where that mail lands.

Then, to get your own subscription:

2. Add your address to the project variable `notification-emails` (comma-separated — each
   address becomes its own subscription).
3. **Cut a new release**, or re-snapshot variables on the current one
   (`POST /api/{space}/releases/{id}/snapshot-variables`). Octopus freezes project variables
   into a release when it's created, so redeploying the *existing* release applies nothing
   and reports no error at all.
4. Deploy it and approve at the manual step.
5. **Click the confirmation link AWS emails you.** An unconfirmed subscription delivers
   nothing, and AWS drops it silently after about 3 days. Nobody else can click it for you
   and no API exposes the token.

Confirm you're actually subscribed:
```
aws sns list-subscriptions-by-topic   --topic-arn arn:aws:sns:us-east-1:<account>:hs-production-certificate-lifecycle   --query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output text
```
A `SubscriptionArn` of `PendingConfirmation` rather than a real ARN means step 5 hasn't
happened. Note that mail sent to a shared mailbox is a second hop the topic knows nothing
about: being on a list that's subscribed is not the same as being subscribed.

### 7. Set up the AWS notices mailbox and its Gmail label

The weekly AWS sweep reads a Gmail label as one of its mail sources. You have to create that
label yourself and tell the harness its name — the installer can't do either.

1. **Subscribe a mailbox to AWS User Notifications.** In the AWS console: Notifications →
   create a notification configuration, event source **AWS Health**, select the regions you
   actually run in, and add your mailbox as an email contact. Ours is called
   `AMA-Health-Notification` and covers `aws.health` only.
2. **Click the verification link AWS emails you.** Until you do, the contact delivers nothing
   and says nothing about it — the same silent trap as step 5 above.
3. **Add a Gmail filter** that applies a label to mail from that subscription. Sending it
   straight past the inbox is fine; the sweep searches `in:anywhere`.
4. **Put the label's name in `harness-config.json`** under `.awsNotices.noticeLabels`. It's an
   array, so you can list several — the sweep runs one search per entry.

Three things that will cost you an afternoon otherwise:

- **Use the label's display name, exactly as Gmail shows it — not its `Label_…` id.** Gmail's
  API docs say the `label:` operator takes ids. It doesn't: an id-based search comes back
  empty rather than erroring, which looks identical to "no mail has arrived".
- **The name has to match the filter exactly**, spaces and capitals included. Get it wrong and
  the sweep reports a clean week forever while looking perfectly healthy.
- **AWS can stop delivering to your address** if mail to it ever bounces or gets marked as
  spam, and it will not resume on its own — someone has to raise an AWS Support case. The
  sweep checks every notification contact is still `active` on each run and will tell you, so
  this shows up as a finding instead of quietly killing the mail leg.

**The <one entry per line; this element only declares the type> monitor works the same way.** If you file vendor notices into their own Gmail
label, put its name in `.embs.noticeLabels` and `check the <one entry per line; this element only declares the type> notices` will search it
alongside its configured senders. Everything above applies unchanged — display name, exact
match, one search per entry.

### 8. Keep the notice senders out of spam

Do this even if you skip everything else in section 7. **Claude's mail searches cannot see
spam.** They run with `in:anywhere`, which sounds like it covers everything and does not:
measured, it reaches archived mail and trash but *not* the spam folder. So a notice Gmail
files as spam is invisible to every monitor here — not partially, entirely. And the monitors
report an empty result as a quiet week, which is exactly what a blind spot looks like.

In Gmail: Settings → Filters and Blocked Addresses → Create a new filter → put the address in
**From** → **Never send it to Spam**. Do it for each sender your monitors rely on, which is
whatever you have configured in `.awsNotices.noticeForwarders`, `.embs.noticeSenders` and
`.supportNotices.senders`, plus `no-reply@sns.amazonaws.com` from section 6.

This isn't hypothetical for AWS: two SNS mails sat in spam while four separate searches for
them came back empty, and a wrong conclusion ("that address rejects external senders") was
written into a ticket before they turned up. Vendor mail has stayed clean so far — the filter
is cheap insurance against the failure being silent when it isn't.

## What you can say to it

| Say this | What happens |
| --- | --- |
| `` See prompt in `X Chat.md` `` | Switches this session's log to `X`, reads it as your task |
| `See latest prompt` | Reads the file's last block as your task |
| "rename this topic to X" | Claude tells you to run `/rename X` — the chat file follows automatically |
| "rename topic" (no name) | Claude picks a name from the file's current content, tells you to run `/rename` with it |
| Write a `-- Q` block in the chat file | Queues that task for later |
| "address the queued items" | Works through the queue right away |
| "move this session to X" | Claude gives you the `/cd` command to run yourself |
| "create AMA release notes" | Runs the full PROJ release-notes pipeline |
| "deploy the release" / "we need a hotfix" | Runs the release or hotfix flow end to end, including creating and releasing the Jira version — no manual step in Jira |
| "what's the state of the repos" | Reports every repo's branch, uncommitted work, worktrees and which session holds it |
| "generate stand-up notes" | Summarizes work across all sessions since yesterday |
| Ask to commit/push/merge/raise a PR | Claude requires a ticket ref first |
| "review my PRs" | Reviews PRs assigned to you across the fleet with real repo context |
| "search graylog for X" | Runs a Lucene query against Graylog, summarizes results |
| "check cloudwatch/ECS/lambda logs for X" | Searches the actual container/function logs |
| "check the AWS notices" | Sweeps AWS Health, support cases, extended-support billing and the AWS notice mail; only what needs action reaches you |
| "check the <one entry per line; this element only declares the type> notices" | Triages `<one entry per line; this element only declares the type> Data Notice:` mail for what it means for AMA |
| "check support notifications" | Triages AMA's own automated failure mail |
| `/fewer-permission-prompts` | Scans transcripts, adds missing allow rules |

## Action items live in Atlassian Forms, not in Jira tickets

Meetings produce work that isn't a coding task. "Reviewer One to answer questions regarding what
<one entry per line; this element only declares the type> files we look out for" is a real commitment, but filed as a Jira ticket it sinks
into the board among the coding tickets and is never seen again.

So the harness tracks these separately, using **Atlassian Forms** rather than issues.
There is one tracking issue on the project, and every open action item or decision is an
attached form on it carrying the item text, its owners, when it was first raised, and
whether it is still open. They sit together in one place, outside the board's noise, and
anyone on the team can read them.

The same items are also published on one Confluence page,
[AMA Action Items and Decisions](https://yourorg.atlassian.net/wiki/spaces/HO/pages/3723264049/AMA+Action+Items+and+Decisions),
so anyone can open them from a single link without knowing the tracking issue's number.
The page is rebuilt after every run, so change an item by telling Claude, not by editing
the page.

You don't file them by hand. Claude reads the summaries your own Zoom AI Companion wrote
for the meetings you attended, and keeps the forms in step:

- **Daily at 12:00**, a scheduled task searches your Zoom meeting history and pulls
  action items out of any summary it hasn't already processed. It adds only — it never
  closes anything — and says nothing when there's nothing new.
- **The 9:00 stand-up run** does the same as part of generating the notes, and is the
  one that closes items once it has evidence they're done.

Both are driven by a local ledger that stays the source of truth, so the ageing of an
item ("open 23d") and the rules about when something may be closed keep working even if
Atlassian is unreachable. The forms are the shared, visible copy of that ledger.

### Setting it up

Every meeting you attended is read by default. `standup.actionItems.meetingTitleExcludePatterns`
is the opt-out: a list of text fragments, and a meeting is skipped when its title
contains one of them. It ships as `["Company Broadcast"]`, so all-hands broadcasts stay
out and everything else -- stand-ups, weekly meetings, ad-hoc calls, and the untitled
notes Zoom saves for a meeting with no agenda -- comes in.

**That list is a convenience filter, not a privacy control.** It matches titles and
nothing else, so a one-to-one whose note was saved untitled has no title to match on and
will be read. Claude is told to judge each item on its content and leave anything
personal out, but if a meeting must never reach a shared Jira issue, add its title here
rather than relying on that. `"1:1"` and `"Performance Review"` are the usual additions.

The other settings are `atlassian.standupTrackingIssueKey` and
`atlassian.standupFormTemplateId` (the tracking issue and the form), both in
`harness-config.json`.

### What it can and can't see

Only meetings **you attended** produce a note of yours, so only those can be read. Claude
reads your own Zoom AI Companion notes, not the host's — if someone else runs the meeting
and you weren't there, nothing reaches the ledger.

This replaced an earlier version that read summary links posted to a team Slack channel.
Posting the link is a manual habit and it lapses: one stand-up's summary existed in Zoom
but was never posted, so its action item ("send the backlog link to Reviewer Two") was invisible
for four days until the Zoom-based version picked it up. Reading Zoom directly also means
a new user needs no channel convention to copy.

## Chat logs and sessions

Every session gets a chat-log file mirroring your prompts and Claude's replies, at zero
extra LLM cost. Its name is always Claude Code's own session name — there's no separate
harness name to keep track of. It defaults to `<shortid> Chat.md` until that name exists,
then follows it automatically, including through later renames. Run **`/rename <name>`**
yourself any time to set it directly; Claude will suggest one if you haven't. You can also
pre-write a task into `<your name> Chat.md` and submit `` See prompt in `<your name> Chat.md` ``
to start the log under that name — Claude will then tell you to run `/rename <your name>`
to make it stick, since otherwise it'll follow Claude Code's auto-title instead.

**Queueing:** say "open chat file" to open this session's log in your editor, then add a
queued message after a `---` divider:
```
---

-- Q
Your queued task text here.
```
Claude works through queued blocks automatically once it finishes the current task —
no new message needed. A quick side question without disrupting the current task can be
prefixed `/btw`.

**Save conflicts:** if you type and save a prompt in the chat file while Claude's reply is
landing, your editor may refuse the save (VS Code does, showing a merge-conflict-style
diff). Click **Compare**, copy your just-added text from the "your version" side, then
discard your changes to keep Claude's reply, and paste your prompt(s) back in at the end.
If any were queued, double-check each still starts with its own `-- Q` line after
re-pasting — that marker is what makes a block visible to the queue at all.

**Resuming:** on exit, a resume command (`cd <dir> && claude --resume <session-id>`) is
appended to the chat file — copy-paste it into a terminal to jump back in. `sessions.txt`
is a master index of every session across every repo; grep it by name or folder to find
one again (`sessions.md` is the same data formatted for reading).

**Relocating a session:** say "move this session to X" — Claude gives you a `/cd <path>`
command to run yourself; everything else follows automatically.

## Running more than one session at once

Sessions share **one local clone per repo**, so `git checkout` affects everybody: whichever
session switches branch last wins, for all of them. Claude now notices this and will say so
rather than silently trampling another session's work — expect messages like *"exporterplus
is claimed by another live session on hotfix/129.0.2"* or *"this sweeps all 3 modified files,
and session 431272bb is working in that same clone"*.

Those are **warnings, never blocks** — nothing is prevented, and an urgent hotfix can always
go ahead. They are driven by `~/.claude/.repo-claims`, a small machine-local file recording
which session was last seen in which repo. A session counts as "live" if its transcript has
been written in the last 10 minutes, so a claim left behind by a finished session goes quiet
on its own; nothing needs releasing and nothing can get stuck.

To see the state of everything yourself:

```bash
bash ~/.claude/scripts/fleet-repo-state.sh              # only repos needing attention
bash ~/.claude/scripts/fleet-repo-state.sh exporterplus # one repo, plus its worktrees
bash ~/.claude/scripts/fleet-repo-state.sh --all        # everything
```

It is read-only — no fetch, no checkout, no writes — and shows each repo's branch,
uncommitted tracked files, worktrees and which session (if any) holds it. Worth a look if
Claude mentions another session, or before you switch branches by hand.

If two people (or sessions) genuinely need the same repo at once, the clean answer is a
second working tree rather than fighting over one:

```bash
git -C <repo> worktree add /c/<repo>-worktrees/<name> -b <branch> origin/master
```

Claude will also warn you before checking out or deleting a branch that already lives in
another worktree — git refuses that outright, and the warning arrives before the failure
rather than in the middle of a longer sequence.

## Notification sounds

A chime plays when Claude's turn finishes, and a different one when it's asking you for
something (permission, plan approval, a question). If it seems too quiet or silent even
though sound works elsewhere, check the Windows Volume Mixer's **per-app volume** for
`powershell` — Windows remembers per-app volume indefinitely, and it can be stuck at 0%
regardless of your master volume.

The chime now repairs that itself: if it finds its own per-app volume muted or under 10% it
resets it to 100%, so a stuck 0% fixes itself after one tone (that first tone is still
silent). Anything above 10% is left alone, so the mixer slider still works as a volume
control. To fix it immediately instead of waiting for a tone, run
`pwsh -File scripts/fix-powershell-volume.ps1`.

## Permissions

The harness ships an allow-broad, deny-specific permission stance for Claude Code — most
tools and shell commands are pre-approved so routine work doesn't stall on prompts, with a
short deny-list (force-pushes, `sudo`/`eval`, piping a download straight into a shell,
etc.) that always wins over the allow list. If you'd rather not allow shell commands
broadly, you can remove the blanket `Bash(*)` allow rule from `settings.json` — a curated,
narrower set of common commands (`git`, `dotnet`, etc.) still works fine underneath it.

---

*Agent-facing details — every hook, gate, skill, and confirmed failure mode — live in
`AGENTS.md`, kept current automatically as the harness evolves. This file changes only
when a human needs to know something new about installing or using the harness.*
