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

## What you can say to it

| Say this | What happens |
| --- | --- |
| `` See prompt in `X Chat.md` `` | Switches this session's log to `X`, reads it as your task |
| `See latest prompt` | Reads the file's last block as your task |
| "rename this topic to X" | Renames the chat file + bookkeeping |
| "rename topic" (no name) | Claude picks a name from the file's current content |
| Write a `-- Q` block in the chat file | Queues that task for later |
| "address the queued items" | Works through the queue right away |
| "move this session to X" | Claude gives you the `/cd` command to run yourself |
| "create AMA release notes" | Runs the full PROJ release-notes pipeline |
| "generate stand-up notes" | Summarizes work across all sessions since yesterday |
| Ask to commit/push/merge/raise a PR | Claude requires a ticket ref first |
| "review my PRs" | Reviews PRs assigned to you across the fleet with real repo context |
| "search graylog for X" | Runs a Lucene query against Graylog, summarizes results |
| "check cloudwatch/ECS/lambda logs for X" | Searches the actual container/function logs |
| `/fewer-permission-prompts` | Scans transcripts, adds missing allow rules |

## Chat logs and sessions

Every session gets a chat-log file mirroring your prompts and Claude's replies, at zero
extra LLM cost. It defaults to `<shortid> Chat.md` in your current directory, but you can
pre-write a task into `<your name> Chat.md` and submit `` See prompt in `<your name> Chat.md` ``
to name it yourself — or just leave it, and Claude renames it once the task is clear.

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

## Notification sounds

A chime plays when Claude's turn finishes, and a different one when it's asking you for
something (permission, plan approval, a question). If it seems too quiet or silent even
though sound works elsewhere, check the Windows Volume Mixer's **per-app volume** for
`powershell` — Windows remembers per-app volume indefinitely, and it can be stuck at 0%
regardless of your master volume.

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
