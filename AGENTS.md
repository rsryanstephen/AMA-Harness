# AMA Claude Harness

**This file is for AI agents.** It is the operational source of truth for this harness —
every hook, gate, skill and confirmed failure mode. For humans, see `README.md` (brief
install/usage guide, updated only when human-visible behavior changes — never
auto-updated the way this file is).

## Installing on a new machine

### Prerequisites

**Core — the harness won't function without these:**
- Windows, PowerShell 7+ (`pwsh`), Git for Windows (Git Bash), Claude Code installed.
- `jq` on `PATH` — every hook shells out to it, no graceful degradation if it's missing.
  This environment's build is `jq-1.5rc1`, which emits CRLF on `-r` output — already
  worked around once, centrally, in `lib-harness-repos.sh`'s `_jqr()` helper (which also
  reads files via **stdin**, never a path argument, so it survives `MSYS_NO_PATHCONV=1`).
  Nothing to do here, just don't be surprised if you go looking for the fix.
- `git`, `curl`, `perl`, `node` + `npm` on `PATH`.
- Developer Mode **on** (Settings → Privacy & security → For developers → Developer Mode)
  — needed for the `CLAUDE.md`/`harness-config.json` symlinks. The `skills/`/`hooks/`
  junctions work without it, so the installer still gets partway without this.
- `~/.claude/.harness-local.json` (repo roots + trusted sandbox paths) — set up by
  `/harness-setup` steps 5/5a below, not something to hand-create.

**Per-capability — only needed if you use that skill:**

| Prerequisite | Used by | Missing behavior |
|---|---|---|
| `ATLASSIAN_API_TOKEN` (env var) | `ama-jira-api` (all read/write scripts), `ama-confluence-api` (attachments, archiving — direct REST) | Fails loud, `exit 1` |
| `BITBUCKET_API_KEY` (env var) | `ama-library-version-sync`, `ama-search-shared-version-sync`, `ama-library-pr-propagate`, `ama-pr-review`, `ama-bitbucket-api` | Fails loud in scripts that call Bitbucket REST directly; prose-enforced only elsewhere (the model has to obey, no mechanism blocks it) |
| `GRAYLOG_PAT` (env var) | `ama-graylog-search` — the **default** error-lookup path for the whole fleet | Both `graylog-*.sh` scripts fail loud. Auth quirk: the PAT is the *username*, the literal string `token` is the password |
| `OCTOPUS_API_KEY` (env var) | `ama-octopus-deploy`, `ama-cloudwatch-search`'s deploy-verification scripts, `ama-postgres-access`'s `get-aggregation-connection.sh` (reads the aggregation-db connection string from a non-sensitive Octopus library variable), `ama-ui-verify`'s one-time password fetch (also a non-sensitive Octopus library variable — see below) | Fails loud where scripted; prose-enforced in the deploy skill itself |
| AWS CLI, default profile signed in | `ama-cloudwatch-search`, `ama-cut-release-branch`'s library-drift check, `ama-graylog-search`'s Step Functions query, `ama-postgres-access`, `ama-octopus-deploy`'s Lambda cleanup, `ama-ui-verify`'s Cognito lookup | No SSO / `--profile` anywhere — it's always your machine's default profile. Account + region come from `harness-config.json`'s `aws.accountNumber`/`aws.region` (`hr_config_required`, fails loud if unset). Needed IAM actions, inferred from real call sites: `logs:DescribeLogGroups`, `logs:FilterLogEvents`, `logs:DescribeLogStreams`, `ecs:ListClusters/ListServices/ListTasks/DescribeServices/DescribeTasks/DescribeTaskDefinition`, `lambda:GetFunction/GetFunctionConfiguration/ListFunctions/DeleteFunction` (+ `lambda:InvokeFunction` for `ama-architecture-notes`' `MONTHLY-DOWNLOADS.md` targeted report-transfers run), `states:ListStateMachines/DescribeStateMachine/ListExecutions/GetExecutionHistory`, `s3:ListBucket/GetObject` on the client-SFTP bucket (verifying monthly-download exports), `apigateway:GET` (resolving the cache-update gateway id/stage, see `ama-graylog-search`'s `CACHE-UPDATE-DEBUGGING.md`), `cloudwatch:DescribeAlarms`, `codeartifact` read + `GetAuthorizationToken`, `cognito-idp:ListUsers`, plus — for `ama-postgres-access`'s `rs-query.sh` against the aggregation Redshift DB — `redshift-data:ExecuteStatement/DescribeStatement/GetStatementResult`, `redshift:GetClusterCredentials` and `redshift:DescribeClusters` (granted here via IAM group `hs_redshift_query_acess` — typo is in the real group name; without that group the script fails `AccessDenied`, not a script bug) |
| Docker Desktop, **daemon actually running** | `ama-postgres-access` — `docker run --rm postgres:16 psql ...` for the **per-service Postgres** DBs (`exportproducer` etc). **Not needed for the aggregation Redshift DB** — `rs-query.sh` goes via the `redshift-data` API, confirmed working with Docker stopped | Deliberate: no local `psql`/`psycopg2` is installed, this *is* the workaround, not a stopgap. Daemon down (not just uninstalled) fails the same way: `open //./pipe/dockerDesktopLinuxEngine: The system cannot find the file specified` — `docker desktop start` (waits for the engine; `docker desktop restart` if wedged), don't read it as "docker missing" and don't hand back to the user. **Wedged reads very differently from down**: `docker desktop start` reports "already running" and `docker ps` exits 0 with no output, while every real command hangs to timeout — probe with `timeout 60 docker images`, fix with `docker desktop restart --timeout 240`. Postgres credentials go via `--env-file`, never interpolated into the command (classifier-denied); **Production is readable this way**, a denial there is a shape problem, not a missing permission |
| Node.js + `npm install` in `skills/ama-library-version-sync/scripts/` | `check-pipeline-yaml.js` (needs `js-yaml`), the nightly `AMA-Harness-Fleet-Health-Check` scheduled task | `node_modules` is gitignored — unlike `ama-ui-verify`'s Playwright script, this one does **not** self-heal, so the nightly task breaks silently on a fresh clone |
| Python (`python`, **not** `python3`) + `reportlab` | `ama-release-notes`'s PDF generation, `ama-team-meeting-notes`'s HTML splice | `python3` on this machine resolves to the **Microsoft Store stub** and errors out — use `python` (real Python 3.10 install) |
| `~/.claude/.ama-ui-credentials.json` | `ama-ui-verify` | Hard exit if missing. Holds `users[env][tier3500\|tier1800]` + `passwordEnvVar` only — the password itself is never stored in this file, it's exported to `$claude_ama_pw` from a non-sensitive Octopus library variable (`OCTOPUS_API_KEY` needed for that one-time fetch, see the skill's setup section) |
| *(nothing — no credential needed)* | Triggering a cache update after a report/SqlTemplate change (`ama-graylog-search`'s `CACHE-UPDATE-DEBUGGING.md`). The `<env>-v1-cacheupdate-api-gateway-rest-api` methods are `authorizationType: NONE`, no HMAC/IAM/API key | Listed here because the opposite is the natural assumption — don't go hunting for an HMAC secret or admin JWT. Only `apigateway:GET` (above) is needed, and only to resolve the gateway id |
| VPN connection | Octopus, and Graylog (a bare EC2 host) — both unreachable off-VPN. Also the documented cause of transient bitbucket.org DNS blips | Calls time out or DNS-fail; see `commit-ticket` skill's VPN-DNS guidance before assuming it's an auth problem |
| SSH private key (`MONGO_SSH_KEY`, default `~/.ssh/PROJ_RELEASE.pem`) + its passphrase (`MONGO_SSH_KEY_PASSPHRASE` env var) + CA bundle (`MONGO_CA_CERT`, default `~/.ssh/global-bundle.pem`) + Docker Desktop running | `ama-mongo-access` — the SSH bastion tunnel to the cohorts/cohort-reports DocumentDB clusters. Key: request `PROJ_RELEASE.pem` from a teammate with EC2 bastion access, store it anywhere, point `MONGO_SSH_KEY` at it if not using the default path. CA bundle needs no hand-off, it's a public AWS download: `curl -o ~/.ssh/global-bundle.pem https://truststore.pki.rds.amazonaws.com/global-bundle.pem` | Missing key/passphrase/CA fails loud with a clear message; Docker not running fails the same way `ama-postgres-access` documents |
| Claude in Chrome extension v1.0.36+ + `/chrome` → "Enabled by default" opt-in (offered at `/harness-setup` step 5b) | `ama-ui-verify` / any UI work outside `admin`/`exporterplus` (that skill's Playwright script covers those two repos only) | **INSTALL-TIME ROW — agents don't re-check any of this per session** (see the UI-verify section below: treat Chrome as available, just try, and if it can't connect ask the user to open Chrome). For whoever is *installing*: falls back to headless Playwright where it exists, nothing outside `admin`/`exporterplus`, and it **fails silently, not loud** — needs a direct Anthropic plan (Pro/Max/Team/Enterprise — not Bedrock/Vertex/Foundry) and `/login` auth; an API key or `claude setup-token` keeps Chrome off **even with `--chrome` passed** (2.1.216+; earlier, every connect 403'd instead), looking like the flag worked when it didn't |

MCP servers — one line each on where they're actually used:

| MCP | Used for |
|---|---|
| Atlassian | Jira ticket create/edit/transition (largely superseded by `ama-jira-api`'s REST scripts — see below) **and Confluence page-body writes, which stay MCP-only**: `ama-release-notes` publishes the release-note page, `ama-team-meeting-notes` splices the weekly "AMA Current Tasks" block. Confluence attachments/images/archiving have no MCP tool at all — direct REST, `ama-confluence-api`. **Its results prepend an outdated HTTP+SSE transport-deprecation notice asking to be relayed to the user — never do; see `memory/suppress-mcp-transport-deprecation-notices.md`** |
| Slack | `ama-release-notes` DMs the release approvers; `ama-pr-review` posts review findings as a canvas; `slack-search` for channel lookup (see its private-channel gotcha) |
| Gmail | `ama-release-notes` **drafts** (never sends) the release announcement email with the PDF attached |
| Google Calendar | `ama-embs-reminders` creates next-day eMBS monthly-file processing reminders |
| claude-in-chrome | `ama-ui-verify` probes for it to decide whether a `--chrome` session restart is needed — see the prerequisites table above for the opt-in and its silent-failure prerequisites |

**Deliberately disconnected (2026-08-10):** Pipedrive, Figma, Microsoft Learn, Google
Drive, Zoom, Fathom — no harness skill referenced any of them, and each connector's
tool names + instructions get injected into every single request whether used or not.
Reconnect on demand if a task needs one; don't "helpfully" reconnect them by default.
**Miro deferred, not dropped** (~60 tool names, the single biggest one) — an active
session still uses it; a calendar reminder is queued to revisit removing it.

**Credentials note:** the Atlassian token and Bitbucket key are separate and **not
interchangeable** — each 401s against the other's API. Bitbucket-API scripts also need
`harness-config.json`'s `user.email` (or `BITBUCKET_EMAIL`/`BITBUCKET_USER_EMAIL`) set,
and fail loud with a `user.email not set` message when it isn't.

### 1. Clone
```
git clone git@bitbucket.org:yourorg/ama-claude-harness.git
```
Any location — nothing in this repo hardcodes the clone path.

### 2. Run the installer
```
pwsh -File scripts\install.ps1
```
- Links `skills/`, `hooks/`, `memory/`, `Chat files/` (junctions), `CLAUDE.md`,
  `harness-config.json`, `README.md`, `AGENTS.md`, `harness-config.example.json`, `sessions.txt`,
  `sessions.md` (symlinks) into `~/.claude`. Any real pre-existing file at one of those
  paths is backed up (`<name>.backup-<timestamp>`) before being replaced — never
  silently overwritten. `Chat files/`/`sessions.txt`/`sessions.md` are gitignored
  (per-machine runtime state, not shared content), so a fresh clone won't have them —
  the installer creates them empty first rather than treating that as a broken clone.
  `harness-config.json` is gitignored too (real values live in the Octopus "Claude
  Harness" variable set) — when missing, the installer seeds it from
  `harness-config.example.json` so hooks always see valid JSON.
- Merges `settings.template.json` (this repo's shareable hooks wiring + permission rules)
  into your real `~/.claude/settings.json` — creates it if missing, otherwise unions
  permissions/hooks in without touching any personal setting you already have (`model`,
  `theme`, etc.).

  **Settings mirroring — which keys travel, and the three parts that make it work.**
  `~/.claude/settings.json` can't be a symlink (it mixes shared harness wiring with
  per-adopter personal content), so it's a merge, and every key falls in one of three
  buckets:

  | Bucket | Keys | Handled by |
  |---|---|---|
  | Shared — template owns it | `$schema`, `env`, `permissions.allow`/`.deny`, `hooks`, `statusLine`, `autoMode.environment` | `Merge-Settings` in `scripts/install.ps1` — union for lists, set-if-absent for objects |
  | Per-adopter, derived | `permissions.additionalDirectories` | same merge, but only ever ADDS this adopter's own `~/.claude` |
  | Personal — never templated | `model`, `theme`, `tui`, `effortLevel`, `advisorModel`, `skipWorkflowUsageWarning`, `permissions.defaultMode` | nothing; left exactly as the adopter has it |

  Adding a shareable key means all three of: (1) put it in `settings.template.json`,
  (2) give `Merge-Settings` a branch for it — a template key with no branch silently
  never reaches an adopter who already has a `settings.json` (that was true of
  `statusLine` for months), (3) add it to `shared_keys()` in
  `scripts/check-settings-parity.sh`, which diffs template-vs-live and feeds
  `on-stop.sh`'s `harness-gaps.md` line. Parity checked hook script names only until
  it was widened to top-level keys and `autoMode.environment` entries.

  `permissions.defaultMode` stays personal deliberately: on Pro/Max/Team `auto` is
  already Claude Code's own built-in starting mode, so templating it changes nothing
  there and would silently impose a permission posture on Enterprise/Console-API-key/
  Bedrock adopters, whose built-in default is Manual.
- Safe to re-run any time — already-correct links and settings are left alone.
- Stops with clear instructions if a symlink fails on privilege — enable Developer Mode
  and re-run the exact same command; already-linked paths are skipped, not redone.

### 3. First run
Open Claude Code and run **`/harness-setup`** to personalize `harness-config.json`'s
org-specific identifiers (email, Jira/AWS/Octopus/Graylog values, etc) — it also offers
the Chrome-by-default opt-in (step 5b) covered in the prerequisites table above.
Org already keeps its harness config in Octopus (a "Claude Harness" library variable
set)? Then setup is one fetch instead of a Q&A:
`bash scripts/octopus-config-sync.sh fetch --server <url> --space <Spaces-N>`
(needs `OCTOPUS_API_KEY` + VPN; only the per-person `user` block remains to fill).

### 4. Required environment variables
- `ATLASSIAN_API_TOKEN` — see "Jira REST API" below.
- `BITBUCKET_API_KEY` — see "AMA library version-sync skills → One-time setup" below.
- `GRAYLOG_PAT` — see "Graylog search" below.
- `OCTOPUS_API_KEY` — see "AMA Octopus deploy skill" below.
- `MONGO_SSH_KEY_PASSPHRASE` — see "AMA Mongo access" below.

### Permissions

`settings.template.json` ships an **allow-broad, deny-specific** stance — 91 `permissions.allow`
entries (including a blanket `Bash(*)`) and 32 `permissions.deny` entries, and **deny always
wins over allow**. Safety comes from the deny list plus the 12 `PreToolUse` gate hooks (see
"Reducing permission prompts" below), not from the allowlist being narrow.

**In `auto` permission mode that allow stance is largely suspended, by design.** Claude
Code drops broad arbitrary-execution allow rules while auto mode is active — blanket
`Bash(*)`/`PowerShell(*)`, wildcarded interpreters, package-manager run commands, `Agent`
rules — and restores them on leaving. Narrow rules (`Bash(npm test)`) carry over. So under
auto mode shell calls route through the classifier instead of the allowlist; that is what
`autoMode.environment` in `settings.template.json` is for (it names our Bitbucket org, AWS
account, CodeArtifact, Octopus, Graylog, Atlassian and app domains so routine AMA work
isn't read as external). Deny rules and explicit `ask` rules still apply in every mode.
Inspect the effective rules with `claude auto-mode config`; a classifier block shows up in
`/permissions` → **Recently denied** (`r` retries), and the durable fix is another
`autoMode.environment` entry, not a wider allow rule.

- **Deny** covers: curl-pipe-to-shell (`curl * | sh`/`bash`/`iex`), writing into `/etc`/`/usr`,
  `sudo`/`eval`/`exec`/`chown`, `kill`/`Stop-Process`, the PowerShell download-cmdlet aliases
  (`iwr`/`irm`/`iex`), all four `git push --force`/`-f` shapes (Bash and PowerShell), and
  `Read(./.env*)`.
- **Allow** is mostly bare tool names (`Edit`, `Read`, `Write`, `Grep`, …), plus `Bash(*)`
  itself, plus a curated narrower `Bash(git *)`/`Bash(dotnet *)`/etc. set that sits redundantly
  alongside it — **that redundancy is intentional, not leftover cruft**: `Bash(*)` is a
  deliberate solo-dev choice for a frictionless workflow, and the narrower set is a ready
  fallback. If you'd rather not allow-all shell commands, delete the `Bash(*)` line and the
  curated set underneath it still runs fine — don't also delete those.
- **MCP tools are allowlisted individually**, not by blanket wildcard (except Atlassian, which
  keeps a legacy wildcard *and* every tool spelled out) — Google Calendar, Slack, and Gmail
  each list only the specific tools the skills above actually call. **claude-in-chrome is the
  other exception: server-level `mcp__claude-in-chrome` (all tools)** — deliberate, so
  `--chrome` UI-verification loops run unattended instead of stopping at a permission prompt
  per click/navigate; the extension's own per-site permissions stay as the second gate.
- The template ships **no** `ask`, `defaultMode`, or `additionalDirectories` — those are
  personal settings that live only in your real `~/.claude/settings.json`, never merged from
  here. There's also no `settings.local.json` in this design — just `settings.template.json`
  (shareable, this repo) merged into `settings.json` (personal, per-machine, not in the repo).

### 5. Verify
- `Get-Item ~/.claude/skills`, `~/.claude/hooks`, `~/.claude/memory`, `~/.claude/CLAUDE.md`,
  `~/.claude/harness-config.json`, `~/.claude/README.md`, `~/.claude/AGENTS.md`,
  `~/.claude/harness-config.example.json` each show a `LinkType`.
- A `git commit` without a `PROJ-XXXXX:` prefix is blocked (ticket-gate hook) in any repo except `~/.claude` itself (that repo has its own separate gate, see below).
- No permission-prompt storm on your first real task (confirms the `settings.json` merge worked).
- `/harness-setup`'s resulting config has no `example.com`/`yourorg`/`000000000000` placeholders left.

## Harness memory (cross-machine, replaces native auto-memory)
- `memory/*.md` — durable rules (preferences, corrections, project state), git-tracked,
  injected into every turn via `on-prompt.sh`, scoped `global` or to a cwd substring.
- See `harness-memory` skill for format/scope rules. Never write to Claude Code's native
  `~/.claude/projects/*/memory/` — gitignored, single-directory, single-machine only.

---

# Chat Logging & Session Management

Every Claude Code session gets a chat-log file that mirrors your prompts and Claude's replies — automatically, at **zero LLM tokens** (plain shell hooks copying text that already exists, not new generation). The say-this/what-happens quick reference is human-facing — see `README.md`.

## How the streaming works

- **`on-prompt.sh`** appends your prompt; **`on-stop.sh`** appends Claude's reply — both verbatim, both zero tokens.
- Tool calls/results never appear — they're a structurally different block type, excluded automatically.
- No API call, no summarizing, no rewriting. What streams is exactly what was said, byte for byte.

## Naming the chat file

- **Default:** `<shortid> Chat.md` in the current directory — but that's a symlink. The
  real file lives in `Chat files/` in this harness repo (centralized, greppable, safe to
  open/edit directly) via `lib-chatfile-link.sh`; the session's own bookkeeping still
  points at the cwd path, so nothing else about the workflow changes. `Chat files/` is
  also junctioned into `~/.claude/Chat files/` (`scripts/install.ps1`), so every
  session's log is browsable from there too without cd-ing into the harness repo.
- **Name it yourself:** write your task into `<your name> Chat.md`, then submit `` See prompt in `<your name> Chat.md` `` — the pointer text itself is never streamed.
- **Otherwise:** Claude renames it once the task is clear, unprompted, before you exit.
- **Still unnamed at exit?** A mechanical fallback renames it anyway — no model turn needed.

## Pointing back at what you wrote

- Pre-write your task in the chat file, then submit a short pointer: `See latest prompt`.
- **No filename given, exactly one unclaimed chat file in the directory** → adopted automatically, no new file created.
- **More than one unclaimed candidate** → Claude asks which one you mean.

## Renaming a topic

- **"rename this topic to X"** — renames the file and bookkeeping in one step.
- **"rename topic"** (no name) — Claude picks one from the file's *current* content, not just its first prompt.

## Queueing prompts

To queue a message, type **"open chat file"** in the Claude Code CLI — Claude opens this
session's chat log in your editor (see the `open-chat-file` skill) — then write the queued
message into that file, after a normal `---` divider. This edits the REAL file in
`Chat files/` directly (the cwd path is just a symlink to it), so a normal editor save
works exactly as it would on any other file — nothing to detach.

```
---

-- Q
Your queued task text here.
```

- Queue as many as you like, each its own `-- Q` block. Marker also accepts `--Q`,
  `-Q`, `- Q`, `-- q`, `- q`, `-q` — 1-2 hyphens, optional space, Q or q.
- **Automatic:** once Claude finishes a task cleanly, it picks up the next queued block
  itself and keeps looping — no new message needed from you — until the queue's empty
  or something needs you.
- **If Claude's turn ends anyway with items still queued** (it forgot, or got
  interrupted), send any next message (even just "continue") to nudge it — and the next queued prompt will be picked up.
- Hits an issue? Stops, resolves it with you, resumes only once you're good to move on.
- **Kick it off directly:** say "address the queued items."
- **Why bother, instead of just typing the next prompt when you think of it:** the CLI's own prompt queue *steers* mid-task, even if docs say "it technically queues" — it still steers heavily, sending a new prompt while Claude is mid-task can make it drop what it was doing. Writing it into the chat file as a queue-marker block instead avoids that.

<details>
<summary>How dequeuing actually works internally</summary>

Claude looping through the queue itself, same turn, is the primary path and always
has been — nothing forces it, Claude just follows the convention. As a backstop for
when that lapses: the queued block is consumed and its text moved into the file as a
plain block the instant Claude's turn ends (`on-stop.sh`), so the file itself is
correct right away even if Claude didn't get to it. Claude Code's Stop-hook mechanism
can't hand content back mid-turn, though, so if a turn DID end with items still
queued, Claude only learns what got dequeued on your next prompt (`on-prompt.sh`'s
injected context) — that's the one case where sending a message is actually needed.

</details>

### Save conflicts while Claude is writing to the same file

Claude appends its reply to the chat-log file after every turn — if the user types and
saves a prompt while a reply is landing, their editor may refuse the save (VS Code
does). Walkthrough with screenshots is in `README.md` (human-facing); the mechanism worth
knowing here: after a discard-and-repaste, any re-pasted queued block **must still start
with its own `-- Q` line** — the Stop-hook block, backstop reminder, and dequeue logic
all grep for that exact marker, and one missing line drops the block silently. Non-queued
prompts are handled first, in order; a second non-queued prompt may not get picked up if
a first one is still being worked. A quick side question without steering the current
prompt uses `/btw`.

## Relocating a session

- Say **"move this session to X"**. Claude gives you a `/cd <path>` command — it can't run this itself, so type it yourself in the session.
- That's the only manual step. Send one more message afterward and the chat file, bookkeeping, and `sessions.txt` all follow automatically.
- Your conversation/context isn't touched — only `/cd` moves that, and it already did.

## Recap streaming

- Claude Code's own periodic **"recap:"** bullets (idle periods, context compaction) get mirrored into the chat file too.
- Stripped automatically once your next real prompt streams in.

## Notification sounds

- `notify-sound.sh` plays an audible cue on two events: turn finished (`Stop` → "Windows Ding") and Claude asking for something — permission, plan approval, AskUserQuestion (`Notification` → "Windows Notify Calendar").
- Claude Code's ~60s idle-timer re-notification ("Claude is waiting for your input", fires a minute after the turn's own Stop already dinged) is **suppressed** — per explicit user request, tones play only for a finish or a genuine ask. Still logged, marked `[suppressed]`.
- The `Stop` ding is also **suppressed when the turn ended with live background work** (a backgrounded Bash task, async agent, or Monitor still running) — that Stop is a hand-off, not "done"; the work's completion re-invokes the model and *that* turn's Stop dings. Detected from the transcript: launched background IDs (`backgroundTaskId` / async `agentId` / Monitor `taskId`+`timeoutMs` launch records) not yet paired with a **terminal** `<task-id>` notification (one carrying a `<status>` tag — a Monitor emits per-event notifications *without* `<status>` while still running, confirmed real ping from session 431272bb). Monitors that die at their own timeout emit no terminal notification at all (confirmed real), so a monitor candidate past launch+timeout is treated as dead rather than muting every later ding. The Stop hook's own "Mirroring reply text to session log" status line is settings.json UI text, never in the transcript, so it can't false-positive. Logged as `[bg-live: <ids>] [suppressed]`. Detection is one rc-checked transcript grep plus pure-bash extraction/set-difference — no process substitution (msys fakes it with named pipes, flaky under Windows load; a real miss at spawn time, f7feade0 2026-08-07, traced to exactly that). A grep read error retries once then fails open (ding rather than mute) with `[bg-check-error rc=N]` logged.
- **One exception**: `Stop` never fires on a turn that died on an API error (529/etc — confirmed real), so this same idle-timer notification is the only signal that a turn stalled. The hook checks the transcript tail for a trailing `isApiErrorMessage` entry and, when found, does NOT suppress — plays "Windows Critical Stop" (falling back to "Windows Hardware Fail" — never Ding or Notify Calendar, per explicit user instruction not to reuse those two — if the primary file isn't present) and logs `[api-error-stall status=<code>]` instead of `[suppressed]`. Paired with `CLAUDE_CODE_MAX_RETRIES` (see `settings.json`'s `env` block) riding out the retry-able window in-session first — this is only the backstop for what escapes that.
- The stock Windows chimes are mastered very quietly (Ding peaks at 7% of full scale — inaudible over music), so the hook volume-normalizes them to 95% once into `~/.claude/.notify-sound-cache/` (machine-local, gitignored) and plays the boosted copies. Pure sample scaling into real headroom — no clipping. Delete the cache dir to regenerate; a non-PCM or already-loud file falls back to the original untouched.
- Every invocation is logged to `~/.claude/notify-sound.log` (when, which event, which session, the Notification message if any) — the answer to "why did a tone just play?". A tone that seems to fire for nothing is usually a `Stop` at a mid-task turn end.
- Inaudible-chime troubleshooting (Windows Volume Mixer per-app volume) is human-facing — see `README.md`.

## Finding past sessions

`sessions.txt` is a master index, one line per session, across every repo. Like
`Chat files/`, the real file lives in this harness repo (`sessions.txt`/`sessions.md`
at the repo root, gitignored — per-machine runtime state, not adopter-shareable) and
`~/.claude/sessions.txt`/`sessions.md` are symlinks to it (`scripts/install.ps1`).
Every rewrite goes through `lib-sessions-lock.sh`'s `sessions_write_through`, which
resolves the symlink before its atomic `mv` — same reasoning as the chat-file symlinks
above, but preserving the atomicity the file's own documented concurrency race
depends on (a plain overwrite-in-place would risk a reader seeing a truncated file):

```
<name> cd <dir> && claude -r <session-id>
```

- Grep by name or by folder (the repo path is inside `cd <dir>`, so `grep AMA sessions.txt` finds every AMA session). `sessions.txt`'s field 1 and `sessions.md`'s bold field are both this harness's own chat-log topic — `grep <name> sessions.txt` and `grep <name> sessions.md` find the same rows now (see the bold-field bullet below for the two placeholder exceptions, where the topic itself never carried a real name to grep for).
- Copy from `cd` onward into a terminal to jump back in, from anywhere.
- **`sessions.md`'s command ends `--chrome` — unless chrome-by-default is already on.** Appended at render time (now in `session-ctx-sizes.pl`), display-only; `sessions.txt` itself never gets it. So a resume always has Chrome control on hand, for whatever repo the session was in (many have no headless Playwright path at all — see `ama-ui-verify`). Skipped when `~/.claude.json` has top-level `claudeInChromeDefaultEnabled: true` (the `/chrome` opt-in, below) — redundant there, and an explicit flag on every row would keep forcing Chrome on resumes even after the user turns the default back off. Toggling the default re-renders the right way on the next prompt, no manual step. The two OTHER resume-command emitters are deliberately left alone: `on-session-end.sh`'s chat-log line (its exact text is what `on-prompt.sh`'s strip regex matches — appending `--chrome` there would break the strip) and `statusline.sh`'s unattended rate-limit auto-resume command, which explicitly carries `--no-chrome` instead (below) — `--chrome` needs attendance, which a background resume doesn't have.
- **Sorted most-recently-active first** — no stored timestamp (removed per user request); instead `on-prompt.sh` splices the touched/new session's line out and re-prepends it to the top on every prompt, so file position itself is the recency signal. A session you're actively working on stays at the top even if it was created hours or days ago. Concurrent-write-safe (mkdir-based lock) and self-healing (a session missing from the file gets re-added, at the top, the next time it's prompted).
- **Only sessions that actually received a prompt get a line** — a session opened and closed with zero interaction never appears at all; the line is created on first prompt, not at session start.
- **Synthetic test sessions never get a line** — `on-prompt.sh`'s self-heal append only fires for a UUID-shaped session id, so a harness test driving that hook with a fake payload sid can't pollute the user's real session list (`testpersist1` did, once). **When testing hooks, keep fabricated sids non-UUID-shaped** — that's what the guard keys off; a UUID-shaped fake would still get a line.
- **`sessions.md`** — the same data, bulleted, for viewing/presentation only. Never edit it directly, and nothing reads it back — `sessions.txt`'s exact line format is what the tooling above actually parses. Two independent display-only substitutions, both driven by `on-stop.sh`'s per-turn capture off the transcript's own metadata lines (`customTitle`/`agentName`/`aiTitle`, all in-band, append-only, latest wins — NOT a `/rename`-prompt-text catch, `/rename` is client-side and never reaches a hook as prompt text):
  - **Resume handle**: an explicit name (`/rename`, `-n`, Ctrl+R, or plan-accept's `agentName` — empirically confirmed to resume directly too, despite the CLI docs saying only an explicit name should) shows as `claude -r "<name>"` in place of the raw session id. Captured into `.session-chatfiles/<sid>.explicitname`. Claude Code's auto-generated `aiTitle` is **not** a confirmed `-r` match, so it never feeds this substitution — a session with only an `aiTitle` still shows a raw sid here.
  - **Bold field — the harness topic wins by default.** It's the one name that ties a row to a real artifact (the chat-log file on disk), and it's what `sessions.txt` field 1 always shows — leading with it makes `sessions.txt`/`sessions.md` grep-symmetric (above). Claude Code's own session name (`.explicitname` — `customTitle`/`agentName` — else `.aititle`, latest wins) only takes over the bold field when the topic itself carries no information:
    1. Topic is still the bare shortid → CC name wins; a placeholder nobody chose.
    2. Topic is Claude Code's own derived `<dir>-<n>` placeholder (`.claudename`, e.g. `exporterplus-37`) that a fallback rename lifted verbatim into the topic (`lib-fallback-rename.sh` step 3, e.g. `ama-claude-harness-f0`) → CC name wins, same reasoning as above. Detected by exact match against `.claudename`, not a `<dir>-<n>` regex — the regex found only 4 of the 6 real cases.
    3. Otherwise → the topic stands, and if Claude Code's name differs it's added as its **own field** right after the bold one (below), never dropped.

    A prior version of this rule reconciled onto the CLI's name by default, on the theory that a model-initiated topic rename (per `CLAUDE.md`) just duplicates Claude Code's own auto-title. That broke down on any session reused across many tasks: Claude Code renames such a session repeatedly (one real transcript held 5 distinct `agentName`/`aiTitle` values over its life), so "the CLI's name" meant only the *latest* of however many — not a specific name anyone could grep for later, and the harness topic was the only stable handle left. A `context > 400k` backstop existed for exactly this drift case but had it backwards: `/compact` resets context, so the sessions most prone to title churn carry the *smallest* live context and never tripped it. Measured effect of switching the default: 26 of 72 visible rows had diverged under the old rule; all but the 2 placeholder cases above now show their topic, with the CC name preserved as a second field. `.customtitle` and `.usertopic` (a user-set title, or the user having named the harness topic themselves) are still written per-turn by `on-stop.sh`/`on-prompt.sh`/`rename-topic.sh` but no longer read by the render — no user-set name is lost, it now surfaces via the plain "topic stands" path since the user set it in the first place.
  `sessions.txt` itself always keeps the harness's own chat-log topic in field 1, unaffected by this substitution, since 6 other scripts parse it positionally.
- **Short-id field**: each row shows the bare shortid (`${sid%%-*}`) between the name field(s) and the resume command, so it's easy to eyeball or match against other shortid-keyed state (`.session-chatfiles/<sid>.*`, `sessions/<pid>.json`, the transcript filename itself). Skipped when the bold field IS already the bare shortid (the still-nameless fallback case) — showing it twice right next to itself is just noise.
- **Claude Code's own name, when it differs from the topic**: shown as its own field right after the bold one (`- **<topic>** — <cc-name> — <shortid> — ...`), so the CLI-visible name stays findable even though the topic won the bold field. Omitted entirely when the two agree, or in the two placeholder cases above where the topic itself became the CC name.
- **Trailing context-size field**: each row ends `— **<Nk>**` (or `**—**` if unknown) — the session's current context size, read from the last NONZERO `"usage"` blob in its transcript jsonl (sum of `input_tokens`+`cache_creation_input_tokens`+`cache_read_input_tokens`+`output_tokens`), summed and humanized (`>=1000` → rounded `Nk`). Deliberately the last *nonzero* blob, not just the textually-last one: a turn that errors out (API 529 etc) writes a synthetic all-zero usage blob, and taking that unconditionally would clobber a real nonzero value from the last successful turn — a session that had real turns then died on a 529 storm would render as a bright-green `0`, reading as fresh/healthy instead of dead. Also deliberately NOT the max across the whole transcript — `/compact` resets context, so a later smaller number is the correct live state, not a decrease to paper over. One perl process (`session-ctx-sizes.pl`) seeks just the last ~300KB of every transcript (a per-file bash `tail`|`grep` loop measured 3.9s, too slow for a hook that runs on every prompt), falling back to a bounded 3MB scan only if that tail has no nonzero blob (a single JSONL line can exceed 300KB — base64 screenshots, big file reads; a long error storm can also fill 300KB with nothing but zero blobs) — bounded, not the full file size, since the corpus includes a 91MB transcript and slurping that inside a 5s `SessionEnd` hook budget isn't acceptable. No perl, or the script errors → sessions.md just isn't rendered this time (stays at its last good state), `sessions.txt` itself untouched either way.
- **Colored as a green→red spectrum**, absolute tokens 0→600k capped red (NOT %-of-window — transcripts don't record window size, so a percentage would be a fabricated denominator; 600k matches the real spread seen, min 50k/median 213k/max 793k). 25 precomputed hex stops (`CTX_COLORS` in `session-ctx-sizes.pl`, piecewise HSL hue ramp, 25k-token buckets) wrapped in `<font color="#hex">` — confirmed by hand that `<span style="color:...">` is silently stripped by VS Code's markdown preview, `<font color>` is not. The `—` unknown case stays uncolored.
- **Rows are hidden for two independent reasons, each with its own footer count.** `session-ctx-sizes.pl` builds its context-size map from every transcript file it finds before touching `sessions.txt` at all.
  - **Unresumable.** A sid hides entirely if EITHER: it's absent from that map (its transcript file is gone — relocated/deleted), OR its transcript exists but never produced a nonzero usage blob (metadata-only session with zero turns; prompts sent but no assistant response ever landed; every turn errored out) — a session that never completed a turn is no more resumable than one with no transcript at all. Footer: `_N session(s) hidden — no transcript on this machine, or no context (never completed a turn) — not resumable._`
  - **Under `$MIN_CTX` (90k, the script's own constant).** A small session did little worth returning to and just crowds out the long-running ones this list exists to surface. Compared against the **raw token sum**, not the rounded `Nk` display field — a row that happens to render `90k` is anywhere in 89,500–90,499, so it can legitimately fall on either side of the cut. Still resumable, unlike the bucket above: `sessions.txt` keeps the line regardless, so `grep <name> sessions.txt` always finds it. Footer: `_N session(s) hidden — under 90k context. Still resumable: \`grep <name> ~/.claude/sessions.txt\`._` One consequence to know: a session still under 90k hides from `sessions.md` entirely, including its own currently-active row, until it crosses the threshold.

  Both footers are display-only, same as everything else here — `sessions.txt` keeps every line regardless, nothing is ever deleted from it.
- **One perl process does the whole render** (`session-ctx-sizes.pl`, invoked by the now-thin `render-sessions-md.sh`) — parses `sessions.txt`, builds the context-size map, applies every substitution/priority rule above, writes `sessions.md` once. Used to be a bash loop forking ~8-10 subprocesses per row; measured at 43s over a real 65-row file, which blew past every automatic caller's hook timeout (Stop: 10s, SessionEnd: 5s) and left `sessions.md` stuck stale — confirmed via a killed mid-render `.tmp` with 12 of 65 rows still on disk. One process instead of ~500+: ~1s. A hash-guard re-checks `sessions.txt` right before the write and skips it if the file changed mid-render (a fresher render is either already in flight or the next prompt triggers one) — cheap at ~1s render time, where the old 43s made that overlap the normal case rather than a rare one.
- Regenerated every time `sessions.txt` changes, AND whenever `on-stop.sh` captures a changed `explicitname`/`aititle`/`customtitle` (so a name doesn't wait for the next unrelated session's prompt to show up), AND unconditionally at `SessionEnd` (so a name captured on a session's very last turn isn't stranded with no further render to ride along with).
- **A session stuck on its bare shortid gets renamed live, not just at exit.** `attempt_fallback_rename` (`lib-fallback-rename.sh`) runs every turn end from `on-stop.sh` (last, after the reply-mirroring above settles), plus at a clean `SessionEnd` and in every later session's startup sweep of OTHER stale, inactive (10+ min untouched) entries — three call sites covering live, clean-exit, and crashed sessions alike. No-ops instantly once a session already has a real name (basename guard), so the per-turn call costs nothing after that.
- **Name-source priority for the mechanical *chat-file* rename** (distinct from the `sessions.md` bold-field priority above — that one is display-only, this one actually renames the file): (1) `.session-chatfiles/<sid>.explicitname` — a user-set `customTitle` (`/rename`, `-n`, Ctrl+R) or plan-accept's auto-derived `agentName`, snapshotted by `on-stop.sh` from the transcript's own metadata lines (the `customTitle` half is *also* snapshotted alone to `.customtitle`, which only the bold field uses); (2) `aiTitle` — Claude Code's auto-generated session title, read directly from the transcript's own `{"type":"ai-title","aiTitle":"..."}` line (durable, append-only, latest wins); (3) the `~/.claude/sessions/<pid>.json` `.name` field, snapshotted per turn to `.session-chatfiles/<sid>.claudename` since that file dies with the session — this is **not** the AI title, it's Claude Code's derived `"<dir>-<n>"` placeholder (e.g. `exporterplus-37`) used whenever the user hasn't renamed, so it only wins when neither of the above exists yet. Only if none of the three exist does the old derivation (`away_summary` slug, else first chat block) kick in. The `rename-topic` skill's pick-a-name-yourself path checks the same source order.

---

## AMA library version-sync skills

Three skills keep AMA library NuGet references up to date across `~/Repos/AMA_APP/` (falls back to `~/Repos/AMA/` during migration).

**`ama-library-version-sync`** — any push to `master` on a library repo:
1. Confirms it publishes a NuGet, reads the new version + build number.
2. Bumps every consumer's reference, gated on green `dotnet build` + `dotnet test`.
3. Confirms with you **per repo** before pushing.

**`ama-search-shared-version-sync`** — `product-service-search`'s special case: publishes from `develop`, not `master`. Auto-scopes to whichever of Search.Shared/Search.Cache actually changed — no question asked if only one did.

**`ama-library-pr-propagate`** — *paused for now* (solo dev, direct push is the standing default — see the two skills above). Kept, not deleted, for when a team workflow needs PRs again. Same idea via pull requests:
- **Phase A**: "make a PR to update library X" → opens the PR, reports consumers, stops and waits.
- **Phase B**: "update the references for X" (anytime later, no expiry) → propagates to each consumer via its own PR.
- Branch names stay slash-free (`/` breaks the pipeline's NuGet suffix step).

**Cascading:** a consumer that's itself a library keeps the chain going, not just one hop. Direct-push skills cascade fully automatically (safety cap, reported not truncated); the PR skill chains Phase A→B pairs across turns since each hop needs a real merge. Genuine version conflicts or package-ID collisions get flagged to you, never guessed past.

**Small changes:** trivial ones (a comment, a scoped bugfix) don't force a full cascade — you get the consumer list as free text (no 4-option cap) and pick which get bumped.

**One-time setup:**
1. Set your Bitbucket API key once — never in a chat prompt:
   ```
   echo 'export BITBUCKET_API_KEY="your_actual_api_key_here"' >> ~/.bash_profile
   ```
2. Your Bitbucket account needs read/write access to the AMA repos.
3. **Bitbucket API unreachable, no auth error?** Check `settings.json` for a `Bash(curl *)` deny rule — deny always beats allow, so remove/narrow the deny rule itself.

If the key isn't set, the skills stop and wait for confirmation rather than skipping the check.

**Nightly fleet health check:** a Windows Scheduled Task (`AMA-Harness-Fleet-Health-Check`, runs hidden, no visible window) checks every repo's pipeline YAML validity and every library's Bitbucket build-counter for reset risk. Results live in `~/.claude/fleet-health/` — `results.log` only shows what *changed* since last run; `latest-build-counter.txt` is the current full snapshot. `ama-library-version-sync` checks this file before computing a new version, so a library with a known counter-reset risk doesn't get bumped straight to `live-build+1`.

## Commit & ticket discipline

Applies everywhere, no trigger phrase needed — just ask Claude to commit/push/merge/raise a PR/transition a ticket.

- **No ticket named** → Claude stops *before* committing and asks (existing ticket, or create one) — never commits first and flags it after. A later push/cherry-pick carrying a no-ticket commit forward has the same obligation.
- Commit format: `PROJ-XXXXX: <short, imperative description>`.
- **New tickets:** assignee defaults to you; status defaults to "To Do," or the real status if the work's already done.
- **Actively working a ticket** → moved to "In Progress."
- **Transitions:** PR→develop = Review · push/merge→develop = QA · push→master = Test Complete · prod deploy = Done (always confirmed with you).
- Lives in a skill, not `CLAUDE.md` — costs nothing until it triggers.
- **Mechanically enforced, not just self-policed:** a `PreToolUse` hook blocks any `git commit` outright (any repo except `~/.claude`, which has its own gate below) if the message doesn't start with `PROJ-XXXXX:` — this isn't Claude choosing to follow the rule, the commit itself fails. Real gap this closed: a session once committed and pushed across 13 repos with zero ticket ref, the skill simply never got consulted.
- **Applies to `~/.claude` itself, too:** its auto-commit hook won't commit any change touching `hooks/` or `skills/` without a ticket resolved first (routine bookkeeping — chat logs, `sessions.txt` — stays frictionless). Resolve one, then run `set-session-ticket.sh` to unblock it. `hooks/`, `skills/`, `CLAUDE.md` actually live in this separate `ama-claude-harness` repo (junctioned back into `~/.claude`; `harness-config.json` sits there too but is untracked — it syncs via Octopus, not git) — `on-stop.sh`'s `auto_commit_push_harness` job auto-commits+pushes there too, same ticket gate, once `set-session-ticket.sh` has recorded <harnessEpicKey> for the session.
- **New-ticket assignee mechanically gated** (`jira-ticket-fields-gate.sh`, `PreToolUse` on `createJiraIssue`): denies creation unless `assignee_account_id` matches your own cached `jiraAccountId` (not just non-empty — a wrong/stale/hallucinated GUID used to pass silently). Epic Link is no longer mandatory here — forcing one onto a plain bug with no natural epic just got worked around (fake epic, then stripped) instead of fixed.
- **New-ticket description mechanically gated** (`jira-ticket-description-gate.sh`, `PreToolUse` on `createJiraIssue`): denies creation unless the description has an "acceptance criteria", "how to test", and either "how to reproduce" (Bug) or "requirements" (everything else) section — checks presence only, any wording/heading style. Template + example: `commit-ticket/TICKET-TEMPLATE.md`. `jira-create-issue.sh` now posts `description` to `/rest/api/2/issue` (wiki markup, e.g. `h2.`/`*`/`#`) instead of v3 — confirmed live that this instance round-trips wiki markup as markup, not ADF; create through that script, not MCP `createJiraIssue`, or headings render as literal text.
- **Harness work never gets its own ticket** (this rule flip-flopped twice before settling here): every harness change commits directly against **<harnessEpicKey>**, no status transitions, no comments — `AGENTS.md` updates only (`README.md` too, but only when the change is human-visible — see below). `harness-ticket-gate.sh` (`PreToolUse` on `createJiraIssue`) mechanically denies creating any new ticket whose Epic Link is <harnessEpicKey>, so this can't silently drift back a third time. **The doc-currency half is now also mechanically enforced** — see `readme-currency-gate.sh` below.
- **Recent regressions route to one generic ticket** (`atlassian.regressionsTicketKey` in `harness-config.json`, currently **<regressionsTicketKey>**), instead of a fresh ticket per fix — a live search on "Regressions" previously turned up 40+ individually-filed one-off tickets nobody revisits. "Recent" = the regressed behavior belongs to a feature/change that shipped within roughly the last 3 releases (resolved live against Jira's version list, never hardcoded). If the specific causing ticket IS identifiable, the existing reopen-that-ticket rule still wins over this one. Genuinely unsure whether a fix qualifies → Claude asks, rather than guessing either way. Like <harnessEpicKey>, this ticket never transitions status, never gets a Fix Version, never gets a per-fix comment — but unlike the harness epic, it's a plain **Bug** parked at **Open** (not In Progress), so it stays out of the "what am I working on"/pickup queries permanently. See `commit-ticket/SKILL.md`.
- **`AGENTS.md` currency mechanically enforced** (`readme-currency-gate.sh`, `PostToolUse` on `Edit`/`Write`): the moment a harness `hooks/`/`skills/` file is edited, greps `AGENTS.md` for that file's name and blocks with the matching line numbers if found, so the description can be checked/updated on the spot instead of silently going stale. A new untracked hook/skill with no `AGENTS.md` mention blocks too, prompting a bullet to be added. Small edits (≤4 changed lines) are suppressed until they accumulate past 5, and at most one nudge per file per session — `on-prompt.sh` resurfaces any still-outstanding nudge on every later turn until `AGENTS.md` itself is touched, so it can't be silently dropped mid-task. If the check concludes no change is actually warranted, run `readme-nudge-ack.sh <key>` to clear that nudge instead of forcing a hollow edit. **`README.md` (human-facing) is a separate file, deliberately outside this loop** — editing it never clears an `AGENTS.md` nudge, and a dedicated `human-readme-edit-gate.sh` (`PostToolUse` on `Edit`/`Write`) instead reminds that it updates only when human-visible behavior changed.
- **Column/status queries default to your own tickets** — "what's in review" (or similar) implicitly adds `assignee = currentUser()` rather than asking every time; only drops that filter if you explicitly ask for everyone's/the whole team's tickets.
- **Push-triggered status reminder** (`git-push-ticket-reminder.sh`, `PostToolUse` on `Bash`/`PowerShell`): nudges Claude to check/transition the session's ticket after a push to `master`/`develop`/`release/*`/`hotfix/*` — hooks have no live Jira read access, so this only prompts a check via Claude's own MCP access, it can't verify or de-dupe. Harness work is exempt twice over, because the session ticket alone isn't enough: a harness commit made *during* a product-ticket session leaves the session ticket at the product key, so the pushed commit's own `PROJ-` ref is checked against `atlassian.harnessEpicKey` as well (fired wrongly once — session on 15307, commit on 15106, nudge said move the mid-investigation 15307 to Test Complete).
- **Develop back-merge reminder** (`develop-backmerge-reminder.sh`, `PostToolUse` on `Bash`/`PowerShell`): fires after a push to `master` in a repo that also has `origin/develop`, when `git cherry origin/develop origin/master` reports any `+` line (a commit whose **patch** has no equivalent downstream) — the back-merge half of `ama-deploy-release` Step 1 / `ama-hotfix` Step 4. Both skills already said to merge to master **and** develop, but nothing checked the develop half and prose alone didn't hold: hotfixes 128.0.1–128.0.7 each skipped it, and the drift only surfaced weeks later at the release/129.0.0 wrap-up, when six repos had conflicting `.csproj` library versions and `reports` had a real semantic conflict (develop had dropped a line the hotfixes restored on master) that nobody could still explain from memory. The reason text carries the two resolution rules that have precedent — `.csproj` conflicts take the latest version of each package (confirmed against CodeArtifact **publish dates**, since the Bitbucket migration reset some build counters, so a higher version string isn't automatically newer), and a hotfix's own code beats develop, because that's what production is running. Deliberately a reminder, never a gate: the master push is already done and correct by the time it runs, and a production hotfix must never be blocked on a develop chore. Reads only local refs (no fetch), so a stale `origin/develop` can only produce a spurious reminder, never a missed one. **The predicate is the whole correctness of this hook, and two obvious-looking answers were both wrong.** (1) *Branch ancestry* — `ama-deploy-release` Step 1 deliberately sources both merges from the release branch rather than chaining develop through master, so after a normal release `origin/master` is never an ancestor of `origin/develop` even though every line already landed there; fires forever on healthy repos (7 of the 17 release/129.0.0 repos sat in exactly that state). (2) *Counting non-merge commits in `origin/develop..origin/master`* — a fix committed on a release branch and separately **cherry-picked** onto develop is two commits, different SHAs, identical content, so the master copy reads as missing. Confirmed live 2026-08-18: all 10 `exporterplus` commits flagged that way were already on develop with byte-identical patches (`git patch-id --stable` matched exactly), and the back-merges pushed for `export`/`feedback`/`querybuilder` produced empty file diffs for the same reason. `git cherry` compares patch IDs and is immune to both. Verified silent on all 9 live repos, and on a synthetic repo: silent when clean, **fires** on one genuinely unapplied commit, silent again once that same patch is cherry-picked onto develop under a different SHA.
- **Cherry-picking a release fix onto develop instead of merging is the underlying process defect** the hook exists to catch. It leaves the branches with no shared ancestry for that work, so git sees two unrelated commits touching the same lines and **every later merge conflicts there** — the direct cause of release/129.0.0's `.csproj` conflicts across six repos and the `reports` `UpdateUserReportService.cs` semantic conflict. It also makes a genuinely missing commit indistinguishable from a duplicated one without a patch-id comparison. Fixes on a live `release/*`/`hotfix/*` branch must reach develop **through the merge**, never as a parallel cherry-pick.
- **Scoped-commit sweep prevented** (`git-commit-scope-gate.sh`, `PreToolUse` on `Bash`/`PowerShell`): denies `git add <specific files> && git commit` with no trailing pathspec and no `-a`/`--all` — `git commit` always commits the whole index, not just what was just added, so a concurrent session's already-staged files silently ride along under an unrelated message. Confirmed real, twice in one session against this repo. Fix: `git commit -m "..." -- <same paths>`. Doesn't flag a deliberate `git add -A`/`.` (the shape `on-stop.sh`'s own auto-commit uses), and only catches add+commit chained in the same command — a separate later `git commit` call isn't covered. **One edge in the recommended fix itself**: `git commit -- <paths>` has `--only` semantics — it commits those paths' WORKING-TREE content, silently overriding anything staged for them, including a `git rm --cached` deletion (bit a real untracking once: the "deleted" file re-committed with its edits). Committing a staged deletion of a file that stays on disk needs a plain index commit with nothing else staged.
- **Direct master pushes blocked** (`master-push-direct-gate.sh`, `PreToolUse` on `Bash`/`PowerShell`): denies `git push` to `master` on an AMA_APP repo when the outgoing commits include non-merge commits not reachable from any `hotfix/*`/`release/*` ref — master is production fleet-wide, and out-of-cycle changes must ride a hotfix branch per `ama-hotfix` (the solo-repo "no PRs" convention skips pull requests, not the hotfix flow; a cherry-pick straight onto master already happened once and needed a revert). The legitimate `--no-ff` hotfix/release merge shape passes; `~/.claude` and `ama-claude-harness` (which live on master by design) are excluded; reads only local refs (no network), fails open on unparseable shapes. A user-instructed direct push (e.g. history repair) needs the user to confirm that specific push.
- **Production-deploy-triggered Done sweep** (`octopus-prod-deploy-ticket-sweep-reminder.sh`, `PostToolUse` on `Bash`/`PowerShell`): fires on a `POST .../deployments` call whose `EnvironmentId` matches `octopus.environmentIds.production`, nudging the mandatory Fix-Version ticket sweep to Done (`ama-deploy-release` Step 7a, reused as-is by `ama-hotfix` Step 4) once Claude's own ECS-image-tag verification confirms the deploy landed. Reversed 2026-08-11 per explicit user instruction — this used to require asking the user first every time; that gate is gone, the sweep is unconditional once verified. Same nudge-not-verify limitation as the push reminder above, plus a quote-blind gap: only catches an `EnvironmentId` literal actually visible in the command text, not one built via a shell variable or file payload.
- **New tickets get added to the AMA Backlog Confluence page** (`atlassian.backlogPageId` in `harness-config.json`), kept priority-ordered — but only ones left **Open** (not worked this session; the backlog is future work, not a log of everything created). Nudged by `backlog-page-reminder.sh` (`PostToolUse` on `createJiraIssue`/`Bash`, same "nudge not verify" shape as the push reminder above, and mostly a no-op since request-time tickets usually go straight to In Progress). Section mapping + insertion mechanics: `commit-ticket/BACKLOG-PAGE.md`. The same page is also the **pickup** source — "backlog"/"pick up tasks from the backlog" means its Open tickets, in the page's own document order, **plus** a second, lower-priority "AMA Backlog — Deferred" child page (older off-page tickets triaged 2026-08, read only after the main page is exhausted) — both pages' mechanics live in `memory/ama-backlog-page.md`.
- **Old/foreign tickets get a premise check before being worked** — a ticket created >2y ago or reported by someone other than you gets its condition verified first: a fix ticket is re-tested for whether it still reproduces, a requirement is re-confirmed with you as still wanted. Verified gone/not-wanted → cancelled automatically (commented, transitioned, removed from the backlog page); couldn't verify → ask, never cancel on that alone. Nudged by `ticket-in-progress-reminder.sh`'s existing reason text (no new hook). See `commit-ticket/SKILL.md`'s "Old/foreign ticket picked up" section.
- **Release/hotfix Fix Version tagging is gated** (`jira-fixversion-confirm-gate.sh`, `PreToolUse` on `createJiraIssue`/`editJiraIssue`): a `release/*`/`hotfix/*` Fix Version has to be created manually in Jira first (no MCP/REST tool does it) — confirm it with the user, then run `confirm-jira-version.sh <version>` to record it in `~/.claude/.confirmed-jira-versions` before the gate allows tagging. The script's output then nudges the next step: **set the version's description** (Claude CAN edit that — `PUT /rest/api/3/version/<id>`, recipe in `ama-jira-api`'s "Version descriptions" section), since Jira version descriptions surface as the Octopus Releases page's Description column. Applies whenever a hotfix/release version is confirmed created or found already existing with an empty description.
- **Release tagging (Step 3a) is a Jira query, not a code search:** assignee in (you, Reviewer One) + status in (QA/Ready to Test/Test Complete) → tag it, full stop. A code-search-based check used to wrongly call tickets "unmerged" when their code lived outside `~/Repos/AMA_APP` (an `AMA_ETL` repo, or the harness itself). Any *other* code sweep (grepping for a ticket ref across the fleet) must cover `AMA_APP` + `AMA_ETL` + `~/.claude` — and remember some tickets genuinely have no code at all.
- **Repo location and folder naming are no longer hardcoded** (PROJ-15143 wave 1): `hooks/lib-harness-repos.sh` resolves any repo by Bitbucket slug or local folder name via its own `git remote get-url origin` — local folder names aren't trustworthy (this machine alone strips 4 different prefixes). Roots + a discovered index live in `~/.claude/.harness-local.json` (gitignored, per-machine). The scripts/skills that hardcoded `~/Repos/AMA_APP` now call it. Wave 2 (remaining hardcoded identifiers — emails, project/epic keys, AWS/Octopus/Graylog literals) is audited and checklisted, not yet migrated. `hooks/lib-harness-repos.sh index` now emits the fleet as a 4th column (`slug/folder/path/fleet`) on both the real and test-override paths — `ama-pr-review` loops it directly instead of a docs-table list, so PR discovery covers app + ETL fleets in one pass.
- **Leaves context for future sessions**, per repo/topic — see the `ama-debugging-notes` skill below. Architecture facts get added liberally; a specific bug's root cause only for a genuinely reoccurring class, always confirmed with you first. Deliberately a skill, not a repo's own `CLAUDE.md` — the latter's cost is unconditional (every future session in that repo pays for the whole file from turn one), a skill only loads when actually relevant.

## AMA debugging notes

Reoccurring-bug-class context gathered from past sessions, for `shared`, `search`, `fieldtablemapper`, `manage`, `exporterplus`, and fleet-wide conventions — read automatically when relevant, not injected into every session.

## AMA architecture notes

Companion skill to the above: how the AMA_APP fleet is actually structured (libraries, API services, auth, frontend, shared-infra, messaging, Selenium/cache-crawler internals, the dedicated testing repos) from a full fleet survey — not bug patterns, structural facts. Same on-demand loading, same skill-not-`CLAUDE.md` reasoning. Both skills' descriptions cross-reference each other so finding one surfaces the other.

## AMA cut-release-branch skill

Say **"cut a release branch"** to start the FIRST stage of a release (before it's
deployed/promoted, and well before `ama-release-notes` documents it after the fact):
next version from Jira → `release/X.Y.Z` branched off `develop` for every deployable repo
(scripted, not per-repo tool calls) → tags every included-but-undeployed ticket with the
release's Jira Fix Version and moves it to QA → checks (read-only) whether any repo's
library references have drifted from CodeArtifact's latest, asks before updating →
build/AWS/CloudWatch/Graylog verification against Staging. **Libraries no longer get
their own release branch** — replaced by the drift-check-and-ask step. **Always confirms
before pushing** — this creates real branches and triggers real Staging deployments
fleet-wide.

## AMA hotfix skill

Say **"hotfix"** / **"HF"** to patch production outside the normal release cycle:
`hotfix/X.Y.Z+1` branched off `master` (not `develop`) → ticket tagged with Fix Version
`hotfix/X.Y.Z+1` → auto-deploys to Staging → verify + explicit go-ahead → merge to
master+develop, deploy to Production, ticket swept to Done. No release notes (not a
scheduled release). `admin`/`exporterplus` fixes go through `ama-ui-verify`'s
self-verify loop before pushing — see below.

## AMA UI verify skill

**Launch UI-project (`admin`/`exporterplus`) sessions with `claude --chrome`.** Confirmed
real dead end otherwise: PROJ-15260 hit a case Playwright's synthetic clicks
couldn't drive at all (a MatDialog overlay that never opened, 0 `cdk-overlay-pane`
before/after) — a session started without `--chrome` has no fallback for that. A
mechanical nudge (`chrome-verify-nudge.sh`, fires on `ama-ui-verify`/`ama-report-debug`/
`verify`/`run`, **and on any Bash/PowerShell command mentioning `playwright`/`verify-ui.mjs`/
`chromium.launch`** — the Skill matcher alone missed the case where an agent left the skill and
drove a scratchpad `.mjs` directly) catches this mid-session — it reads `~/.claude.json` itself
(on **stdin**, not as a path arg: native `jq.exe` cannot resolve an MSYS `/c/...` path and would
silently take the wrong branch) and branches:
chrome-by-default ON → states as fact that the `mcp__claude-in-chrome__*` tools are in
the session's deferred list and forbids claiming otherwise without a no-match
`ToolSearch` (session a3d73cec asserted absence without probing while the tools sat in
its own list); it also **forbids re-litigating prerequisites** (extension, plan type,
`/login` auth, version — all install-time concerns) and names the single thing worth
asking for: **Chrome not running → ask the user to open Chrome and retry the same call**,
never a silent fallback to headless. OFF → the original relaunch-with-`--chrome`
suggestion. Starting with the
flag (or the default) avoids the dead end in the first place. `sessions.md` resume commands carry `--chrome` too, for the
same reason — unless chrome-by-default is already on, which makes the flag redundant
(see "Finding past sessions" above).

**`run-ui-verify.sh` screenshots on `networkidle`, before ag-grid rows load** — a
report/grid URL yields a correct-looking app shell with an empty grid at exit 0
(confirmed live 2026-08-13). For grid pages, write a scratchpad script waiting on a
non-empty `.ag-cell` instead — see the skill's caveat under "Running the full flow".
For cache verification, `scripts/drive-report-fromcache.mjs` drives a report twice and
prints every `/search/*` response's `FromCache` flag; Curve Analyzer driving has its
own trap list in `CURVE-ANALYZER-DRIVING.md`.

**`chrome-verify-compact-nudge.sh`** (`PostToolUse` on `tabs_close_mcp`): closing a
claude-in-chrome verify tab means its base64 screenshots — the biggest confirmed driver
of that MCP server's context cost — are done being useful. One-shot per session, writes
into the same per-session notice file `statusline.sh`'s context gauge uses (see below),
recommending `/compact`. Backstop for `ama-ui-verify`'s own screenshot-discipline rule.

**`subagent-model-tiering-gate.sh`** (`PreToolUse` on `Agent`, warn-only, never denies):
reminds to tier the `model` param per `resource-efficiency`'s easy→haiku/medium→sonnet/
hard→omit mapping when a spawn omits it. Honors `SUBAGENT_MODEL_TIERING=off`.

**`statusline.sh` also renders/notices context-window usage now**, not just the 5h/weekly
rate-limit windows — a `ctx:NN%` segment in the bar, plus a per-session (not
account-wide) one-shot `/compact`-or-`/clear` recommendation at 60%/80%, relayed by
`on-prompt.sh` from `.ctx-notices-<session-id>`. See the `context-hygiene` and
`usage-monitor` skills for the full mechanism and what to do when it fires.

Drives a real `admin`/`exporterplus` page headlessly (Playwright, six dedicated Cognito
test users, no MFA) — no user attendance needed. `claude --chrome` now runs unattended
too (server-level `mcp__claude-in-chrome` allow + the browser's own already-logged-in
state — pauses only at a login page it doesn't hold or a CAPTCHA); Playwright's remaining
edge is only that it works with Chrome closed, or on a machine without the opt-in.

**Fresh (non-resumed) launches too: run `/chrome` once, pick "Enabled by default."** No
settings key or env var does this — it's an interactive, client-side command, same
category as `/rename`; nothing here can run it for you. Requires Claude Code 2.1.211+
(startup no longer hangs if Chrome isn't running) — confirmed on 2.1.222. **Sets
`claudeInChromeDefaultEnabled: true` at the TOP LEVEL of `~/.claude.json`** (confirmed by
diffing before/after) — global user state, not project-scoped, and not something
`settings.template.json`/`install.ps1` can ship (that file is per-machine, gitignored,
outside the installer's scope) — a fresh adopter or new machine must run `/chrome`
themselves too. Tradeoff: browser tools load on every session, raising context cost even
when there's no UI work — `/chrome` toggles it back off if that bites. `statusline.sh`'s
unattended rate-limit auto-resume explicitly carries `--no-chrome` regardless of this
default, since it discards
all output and a stalled browser-tool prompt there would hang silently forever.

- **Debugging**: screenshot/computed-CSS/console state of the actual current UI, as a
  first step investigating a bug — not only to confirm a fix already made.
- **Standing rule, all UI work**: self-verify → fix/re-verify loop until resolved → user's
  own local sign-off → only then push/deploy. Applies before any QA/Staging/Production
  deploy, not just hotfixes.
- `tier1800` test users can't access Dynamic Cohorts/Cohort Reports (plan limit, not a
  bug) — use `tier3500` there.
- Confirmed selectors for the report/description UI, one-off-Playwright-in-scratchpad
  setup, and a real gotcha: elevated/admin view access to another user's report doesn't
  add it to your own Home/Shared-with-me folder listing, so it can't be found via the
  list UI at all — only via direct `/aggregations/view/<id>` — see the skill file.
- If a fix only reproduces on a real person's own report (no test account sees it as its
  owner does in the list): have that person log into the local dev server themselves,
  then restart `claude --continue --chrome` to drive their already-authenticated tab.

## AMA report debug skill

Say a ticket describes a report that fails to load/hangs/errors — triggers this
sequence: offer the user a chance to self-serve first (load it, hand over a Graylog
link); if declined, Claude loads it via `ama-ui-verify` and checks Graylog
(`ama-graylog-search`); for a custom band (dynamic column), check Postgres
(`ama-postgres-access`) — its data lives in the **export API's** DB, not
`querybuilder`'s own, even though querybuilder serves it (see `ama-architecture-notes`).

## AMA Release Notes skill

Say **"create AMA release notes"** to run the full pipeline: next release number → Done/Test Complete tickets → mark Resolution Done (Fix Version is already tagged at cut time by `ama-cut-release-branch`, not here) → Confluence page → PDF → email draft.

- **Two steps stay manual:** creating the Jira release version, marking it Released. Claude tells you when and waits.
- Config (recipients, greeting names, board, space, footer, approvers) lives in **`harness-config.json`** under `atlassian.*`/`releaseNotes.*` — not in `SKILL.md`, which only names the keys. Edit the config, then `scripts/octopus-config-sync.sh push` (it's untracked, so git doesn't carry it to other machines).
- **Greeting names come from `releaseNotes.greetingNames`, never from the email address.** The 129.0.0 draft opened "Hi Dan, Sebastien," because it was inferred from `<emailRecipients>` — he goes by **Seb**, and the local part is a legal name, not a form of address. A recipient missing from the map is an ask-the-user, not a fallback to the address.
- **Distributing to Claude.ai:** no upload tool exists — package as a `.skill` zip and upload manually. Rebuild it whenever `SKILL.md` changes; it goes stale silently otherwise.

## Graylog search

Ask to search/check Graylog logs (e.g. "search graylog for errors in qa in the last day excluding exportproducer/ping") — Claude turns it into a Lucene query and runs it against `http://your-graylog-host:9000`.

- **One-time setup:** `echo 'export GRAYLOG_PAT="your_actual_graylog_pat_here"' >> ~/.bashrc && source ~/.bashrc` — a Personal Access Token, not your account password.
- Uses the legacy `/api/search/universal/relative` endpoint — confirmed the newer Graylog "Search Scripting API" 404s on this instance's version (4.2.6).
- **Falls back to CloudWatch automatically** when Graylog has nothing — infra-level failures (container crash, ECS task issues, Lambda cold-start) never reach Graylog at all. No setup needed, uses your existing AWS CLI credentials.
- **Recognizes known error patterns** instead of re-diagnosing them every time — a stale-cache condition that just needs an admin-panel refresh, and a historic library bug that only matters if the affected repo hasn't picked up the fix yet.
- **Cache-update failures get traced end-to-end**: Graylog → the AWS Step Function that ran it → CloudWatch logs for whichever Lambda actually failed (the failing one is rarely named after the step that failed — Claude resolves the real target instead of guessing).

## CloudWatch log search

For AMA_APP repos running as ECS tasks or Lambdas — searches the actual container/function logs directly, for the errors Graylog structurally can't see.

- No setup — reuses your existing AWS CLI credentials (account `000000000000`, `us-east-1`).
- **Retention is short and varies:** qa ECS = 1 day, production ECS = 5 days, Lambda is per-function (seen 1/5/30/never-expire). A clean empty result may just mean the logs already expired, not that nothing happened.
- Lambda log group names don't follow a predictable pattern — always searched by keyword, never guessed.
- **`AWS-SWEEP.md`** — a distinct "quick sweep, is anything crashing/restarting right
  now" check (ECS health + logs + Alarms + cache-update Step Functions, one env at a
  time), separate from post-deploy verification below.
- **`DEPLOY-VERIFICATION.md`** — the post-`develop`-push QA deploy check (build →
  Octopus → AWS order). Shared/reused by both `ama-cut-release-branch` and
  `ama-hotfix`, not a standalone flow.
- **Deploy verification is gate-enforced, not just an "ask first" convention** — see
  `deploy-verify-confirm-gate.sh` in the hook table below.

## AMA Postgres access

Direct Postgres access to any AMA env (Staging/QA/Production) — resolves the live
connection string straight from the running ECS task definition, connects via a
throwaway `docker run postgres:16` client. No local `psql`/driver install needed.

## AMA Mongo access

Read-write access to the cohorts / cohort-reports Amazon DocumentDB clusters (QA/Staging/
Production) — resolves the live connection string from ECS same as Postgres above, tunnels
through the SSH bastion, connects via a throwaway `docker run mongo:7|mongo:4.0` client
(engine version picks which). No local `mongosh`/driver install needed, no connection
string ever stored in this repo. See `ama-mongo-access` skill.

## Bitbucket REST API auth

For calling `api.bitbucket.org` directly (pipeline status, logs, triggering a run) — not git clone/fetch/push, which is a separate SSH-transport concern (see `commit-ticket`'s DNS/SSH-transport section).

- `$BITBUCKET_API_KEY` is an Atlassian API token (`ATAT`-prefixed) — needs HTTP **Basic** auth (`-u "<email>:$BITBUCKET_API_KEY"`), not Bearer. Bearer gives a misleading 401 that reads like a bad token when the auth scheme is just wrong.
- Log-download endpoints redirect (`307`) — pass `-L` to `curl`.
- PR comments (top-level or anchored to a line via `inline.to`), deleting one, and the non-ASCII-in-bash-argument gotcha are all in `ama-bitbucket-api`.

## Jira REST API (direct, via API key) — why not just the MCP server

`ama-jira-api` calls Jira's REST API directly (`-u "<email>:$ATLASSIAN_API_TOKEN"`, same Basic-auth pattern as Bitbucket above) instead of the Atlassian MCP tools, for both reads (issue status/fields, transitions, JQL search) and writes (create/edit/transition/comment). Reason: an MCP tool's result is injected into context **verbatim** — there's no way to trim it — and Jira's own API shape carries fixed nested overhead (`avatarUrls`, `self`, `statusCategory`) that a `fields` param can't strip. A script piping the same REST call through `jq` prints only the value actually needed (Atlassian MCP had grown to 42% of a usage window before this was built).

Writes go through a fixed payload file (`~/.claude/.jira-write-payload.json`, written via the `Write` tool, never a shell argument; scripts delete it on success only — a failed call leaves it for retry) rather than embedded JSON — this is also what lets the 3 write-gated `PreToolUse` hooks (`harness-ticket-gate.sh`, `jira-fixversion-confirm-gate.sh`, `jira-ticket-fields-gate.sh`) keep reading structured JSON instead of parsing it back out of command text. Confluence writes and `addWorklogToJiraIssue` are deliberately still MCP-only (lower call-frequency, not worth the added complexity yet). New env var: `ATLASSIAN_API_TOKEN`, same convention as `GRAYLOG_PAT`/`BITBUCKET_API_KEY` — needs Jira/Confluence scope specifically, confirmed NOT interchangeable with `BITBUCKET_API_KEY` (each 401s against the other's API).

## Verify before reporting a bug

`verify-before-reporting` — read the real post-change code (not a subagent's diff-only summary) and the schema/contract it writes into before telling anyone a bug exists. Applies to any report, not just PR review: a raw-diff read can overstate a finding (e.g. "always wrong" when it's actually "wrong only if two inputs diverge").

## Reducing permission prompts

- **`/fewer-permission-prompts`** scans transcripts and adds missing `settings.json` allow rules.
- **The sandbox (`sandbox-allow.sh`)** auto-allows a tool call outright (no manual
  approval prompt) when its cwd or target path is under a trusted root. `~/.claude`
  and Claude Code's own scratchpad temp dir are **always** trusted, for any adopter —
  both are derived from `$HOME` at runtime, not hardcoded. **Everything else is
  configured per machine, not assumed**: set your own trusted directories (repo
  clones, working trees, whatever you want routine work in to skip prompts) in
  `~/.claude/.harness-local.json`'s `sandboxTrustedRoots` array — plain paths, `~`
  supported. See `~/.claude/.harness-local.json.example` for the exact schema, or run
  `/harness-setup` (step 5a walks you through it, defaulting to the same paths you
  give it for repo discovery). Unset → nothing outside `~/.claude`/scratchpad is
  auto-allowed; every other call gets a normal prompt until you configure this. (This
  used to hardcode Your Name's own `~/Repos/` convention — PROJ-15143 wave 2 made it
  config-driven since a new adopter's repos won't necessarily live there.)
  Its debug logging (full tool payload per call, into `hooks/sandbox-allow.log`) is now
  **off by default** — it had grown to 33MB of verbatim payloads (a secret-at-rest
  concern) and forked `date` per line on every tool call. Set `SANDBOX_ALLOW_DEBUG=1`
  to re-enable for troubleshooting.
- **A separate, hardcoded "sensitive file" guard for `~/.claude/`** exists independent of all of the above. Its "always allow" option persists correctly for Write/Edit, but **not** for Bash/PowerShell — expect repeated re-prompts there regardless. Claude Code product limitation, not fixable here.
- **On any denial, keep talking** — state what was denied and what you're retrying, don't go silent waiting for the user (a session once sat idle 4 minutes after a denial with zero text in between).

### All 23 `PreToolUse` gate hooks at a glance

Count is derived, not hand-maintained — regenerate it rather than trusting it:
`jq -r '.hooks.PreToolUse[].hooks[].command' settings.template.json | grep -oE '[a-z0-9-]+-gate\.sh' | sort -u`.
It read "12" while listing 16 and omitting 4 wired gates, for long enough that a review
had to point it out.

The sandbox above plus these 23 mechanical gates are what actually keep routine work
from hitting a wall of manual approval prompts — prose-only rules kept getting
violated even when clearly written elsewhere, so each of these enforces one specific,
already-confirmed failure mode at the moment of the action itself, not just in a
skill the model has to remember to read.

| Hook | Fires on | Blocks |
|---|---|---|
| `bare-cd-gate.sh` | `Bash`/`PowerShell` | A LEADING, unparenthesized `cd <path>` (alone, or followed by `&&`, `;`, or `\|`) — shell cwd persists across separate calls, so either shape leaks it forward. Use `(cd X && cmd)` (a real subshell) or pass the path as an argument instead (`git -C X ...`, `ls -la X/`). Only the command's own first token is in scope — deliberate, keeps it quote-safe (a broader version was tried and reverted after it flagged `cd` text merely *quoted* inside an argument). Exempt: a **bare** `cd` back to the session's own home dir (corrective return). The COMPOUND form is denied even for home — Claude Code can't statically resolve a cd-compound's final cwd on git-bash, so it refuses to delegate the call to the auto-approval classifier and prompts manually every time. |
| `parallel-fanout-gate.sh` | `Bash`/`PowerShell` | The 2nd+ call in a genuine parallel dispatch batch — one denial otherwise rejects the WHOLE batch at once (7 fired together → all 7 lost). Detected deterministically from the transcript (consecutive `tool_use` entries with no `tool_result` between them), not a timing guess — a timing heuristic misfires on ~22% of ordinary fast *sequential* calls. Use separate `Agent` calls for genuinely independent parallel work instead — no shared shell state, not gated by this. |
| `grep-memory-gate.sh` | `Bash`/`PowerShell` | A recursive `grep -r`/`-R`/`--recursive` missing `-I` (binary-skip) — an unscoped recursive grep buffers a binary file as one giant "line" (hit ~2GB then ~6GB RAM). See the `grep-usage` skill for the fuller scoping guidance this doesn't hard-gate (`--exclude-dir`/`--include`). |
| `deploy-verify-confirm-gate.sh` | `Bash`/`PowerShell` | Launching `verify-qa-deploy.sh`/`verify-deployment-e2e.sh` before the user has explicitly said yes for THIS session — docs already said "never run unprompted" in three places and it still got skipped once. Confirmation is one-shot, not carried into a later push. |
| `aggregation-secret-gate.sh` | `Bash`/`PowerShell` | Running `get-aggregation-connection.sh` without consuming its output, so its `export PGPASSWORD=...` line would print the live DB password into the transcript. Allowed: the documented `eval "$(...)"` form, a variable assignment, a pipe, or a redirect. Querying that DB at all is better done via `rs-query.sh` (redshift-data API, no password involved). |
| `unanalyzable-script-gate.sh` | `Bash`/`PowerShell` | **Backstop for `bash-command-style`'s Rule 0** (beyond a simple pipeline → Write a script file, run `bash <file>`, which is analyzable by construction). Catches the INLINE command shapes Claude Code can't statically analyze — it then refuses to delegate the call to the auto-approval classifier and falls back to a manual permission prompt every run, subagents included. **(a)** any loop (`for`/`while`/`until` + `done`) **at any length**, including a one-liner ("Contains simple_expansion" — the loop variable and any path built from it are unresolvable) → Write it to a file, run `bash <file>`; **(b)** `if`/`case` spanning lines, or a multi-line embedded awk/perl program → same fix (single-line `if …; then …; fi` stays allowed); **(c)** a quoted string left open across a newline, i.e. `git commit -m "multi-line msg"` → use `git commit -F - <<'EOF'`; **(d)** an unresolvable ALL-CAPS env var (`$ATLASSIAN_API_TOKEN`, `$OCTOPUS_API_KEY` — `$HOME` and friends are resolved fine) → same script-file fix, which also keeps the token out of the command line and transcript. Only the region before the first `<<` is measured, so heredoc bodies are exempt. Each rule was added after a shape slipped past the previous ones and cost a real prompt — **don't assume the set is complete**; `bash-command-style` carries the 6-step triage recipe (get the exact command from the transcript, replay it through the hook, read the prompt's own reason string, cost the rule against both corpora, widen the prefilter, live-probe). Measured by replaying two sessions in full: mine 112/122 allowed, 55c72ae1 154/176 main and 155/162 subagent. The ~8% denied in ordinary work is concentrated in ad-hoc analysis one-liners, which belong in a file anyway — hence the loop rule at full strength rather than fitted to one trigger. Quote-blind on purpose (`bare-cd-gate.sh` reverted quote-aware matching), so script text passed as DATA also denies — put hook-test fixtures in files. No bypass marker: skipping this gate wouldn't skip Claude Code's own refusal. |
| `short-path-gate.sh` | `Bash`/`PowerShell` | A command containing an 8.3 short path segment (`RYAN~1.STE`, `PROGRA~1`) — the tilde reads as an unresolved expansion and costs the same manual prompt. Long and short name the same directory, so it always rewrites safely; prefer `$HOME/...`. Pattern requires a trailing path separator, so `HEAD~1`, `HEAD~1..HEAD` and `~/` are out of scope. Root cause (`TEMP`/`TMP` in 8.3 form) fixed on this machine 2026-08-17 — see the `bash-command-style` skill. |
| `inplace-edit-gate.sh` | `Bash`/`PowerShell` | An in-place stream edit (`sed -i`, `sed --in-place`, `perl -i`, `-i.bak`) against a `~/.claude` path. Every file there is a SymbolicLink into this repo, and these tools RENAME a temp file over the target — which replaces the link with a standalone file, so the edit lands OUTSIDE the repo, `git status` reports clean, and the copies silently diverge. Confirmed live 2026-08-17 on `harness-gaps.md`: sed reported success, `LinkType` came back empty. Shell sibling of `symlink-write-gate.sh` and the worse half — Edit/Write at least refuse; `sed -i` succeeds. Narrow by design: needs an in-place FLAG plus a `.claude` path, so `sed -n`/`grep -i` on those paths pass. The flag must be a real TOKEN (whitespace, `-`, optional bundled letters, `i`) — matching a bare `-i` anywhere in the argument region was wrong BOTH ways: it denied `sed -n '1,25p' …/jira-edit-issue.sh` (the `-i` sits inside `edit-issue`) and it MISSED `perl -pi -e` / `perl -npi.bak -e`, the classic in-place perl idioms this gate exists to stop. Fixed 2026-08-18 against a 17-case fixture. |
| `publish-scrub-gate.sh` | `Bash`/`PowerShell` | A `git commit` in THIS repo whose staged content would abort `scripts/publish-public.sh` at its forbidden-token gate — the gate otherwise only runs post-commit inside `on-stop.sh`, so a bad token broke the public mirror silently (it did, for a full day). Calls `publish-public.sh --check-paths` on the staged paths (working-tree copies — the normal export is `git archive HEAD`, useless pre-commit). Fix by adding the literal to `scripts/public-scrub-map.txt`, not by rewording. ~2s. |
| `git-commit-ticket-gate.sh` | `Bash`/`PowerShell` | A `git commit` (any repo except `~/.claude`, which has its own separate gate) whose message doesn't start with `PROJ-XXXXX:` — see "Commit & ticket discipline" below. Only reads a message from `-m "..."` or the `-m "$(cat <<'EOF' ...)"` shape; **the heredoc must be attached to `-m`**, since matching a bare `<<MARKER` anywhere in the command made any write-a-file-then-commit call self-trip (a `cat > msg.txt <<'MSG'` + `commit -F msg.txt` read the message file's first line as the message; a `cat > script.sh <<'EOF'` + `bash script.sh` reported the message as `set -u` and matched a `git commit` that was only script *text*). Everything else — `-F`, `--amend --no-edit`, an editor commit, a conflicted-merge conclusion — extracts no message and fails open by design. |
| `master-push-direct-gate.sh` | `Bash`/`PowerShell` | A `git push` to `master` whose outgoing commits include non-merge commits reachable from no `hotfix/*`/`release/*` ref — out-of-cycle production changes ride a hotfix branch (`ama-hotfix`), master only receives `--no-ff` merges. `~/.claude`/`ama-claude-harness` excluded (they live on master). See "Commit & ticket discipline" above. |
| `octopus-lambda-delete-gate.sh` | `Bash`/`PowerShell` | A `POST .../Spaces-N/deployments` with no `aws lambda delete-function` recorded this session — deploying over an existing Lambda can leave the OLD code running while Octopus reports Success and `LastModified` moves (cost ~40 min re-diagnosing an already-correct fix, 2026-08-17). Non-Lambda target → prefix `OCTOPUS_TARGET_NOT_LAMBDA=1`. Same file wired `PostToolUse --record` to remember the delete (2h window). See `ama-octopus-deploy`. |
| `skill-bloat-gate.sh` | `Edit`/`Write` | A `skills/*/SKILL.md` paragraph containing "confirmed real" that exceeds ~35 words — mechanical backstop for `write-a-skill`'s own anti-narrative rule. |
| `standup-empty-section-gate.sh` | `Edit`/`Write` | Writing a `standup-notes-<date>.md` whose "Couldn't summarize" heading has no real bullet under it (or just `None`/`N/A`) — an unearned empty section is a false all-clear. `ama-standup-notes`'s own rule: omit the heading entirely when the sweep found nothing. |
| `symlink-write-gate.sh` | `Edit`/`Write` | Writing to a `~/.claude` path that resolves elsewhere — these are symlinks/junctions into this repo and Edit/Write can't write through them. Fires BEFORE the tool's own generic refusal and hands back the resolved real path, so the retry lands first try. Shell counterpart: `inplace-edit-gate.sh` above. |
| `native-memory-gate.sh` | `Edit`/`Write` | Writing to Claude Code's native `~/.claude/projects/*/memory/` store — durable memory belongs in this repo's git-tracked `memory/` instead (that store is gitignored and scoped to one cwd hash). See the `harness-memory` skill. |
| `confluence-media-gate.sh` | `updateConfluencePage` | A `contentFormat="html"` body write to a page listed in `.atlassian.pagesWithNestedMedia` — the HTML→ADF converter silently drops a `<figure data-type="media-single">` nested inside a `<li>`, so such a page loses its image on EVERY html write: body written faithfully, version bumped, image gone, no error. Confirmed live 2026-08-17 on the AMA Backlog page (v88 destroyed it, v89 restored it via ADF). Write the body as `contentFormat="adf"` instead; recovery path in `ama-confluence-api`. Inert when the config list is empty. |
| `slack-brevity-gate.sh` | `slack_send_message`/`_draft`/`slack_schedule_message` | Two Slack message rules (the filename predates the second). **(a)** over 120 prose words — standing user instruction 2026-08-18, every Slack message uses as few words as possible; the DM that prompted it ran ~250 words of background the recipient already had, its accepted rewrite ~50. Fenced blocks and inline-code spans are excluded from the count. **(b)** 3+ addresses in a list not individually backticked — Slack renders each `` ` `` span as its own chip, so per-item backticks give an orderly row; bare text runs together and ONE span around the whole list becomes a single wide chip (both denied). Scoped to lists: one or two addresses in prose pass, a lone inline `sg-…` id passes, a fenced block passes. Rule and rationale in `memory/slack-messages-terse.md`; Jira comments and replies to the user are explicitly NOT in scope for either rule. |
| `jira-ticket-fields-gate.sh` | `createJiraIssue` | Ticket creation where assignee doesn't match your own cached `jiraAccountId` — see "Commit & ticket discipline" below. |
| `harness-ticket-gate.sh` | `createJiraIssue` | Creating any new ticket whose Epic Link is <harnessEpicKey> — harness work never gets its own sub-ticket, see "Commit & ticket discipline" below. |
| `jira-fixversion-confirm-gate.sh` | `createJiraIssue`/`editJiraIssue` | Tagging a `release/*`/`hotfix/*` Fix Version before it's confirmed via `confirm-jira-version.sh` — see "Commit & ticket discipline" below. |

Wired in `settings.template.json`'s `hooks.PreToolUse` (merged into your real
`settings.json` by `scripts/install.ps1`) — that file is the source of truth for the
exact matcher/command/timeout for each; this table is the map, not a duplicate of it.

**Touched a gate? Run `bash scripts/check-gates.sh`** (exit 0 = all asserted). It feeds each
gate real payloads and asserts the decision — behavioural, not a source-grep for whether the
file mentions a pattern. Not auto-run: 89 gate invocations per pass is too much for every
turn. **Coverage: 17 of the 27 gate/nudge hooks.** The remaining 10 need git/session/transcript
fixtures (`bare-cd`, `git-commit-scope`, `git-commit-ticket`, `master-push-direct`,
`publish-scrub`, `deploy-verify-confirm`, `parallel-fanout`, `octopus-lambda-delete`,
`chrome-verify-compact-nudge`) — add them the same way, never by asserting less.

**A FAIL means a FAIL — don't re-run past it.** An earlier revision of this note said a cold
environment produced one spurious `readme-currency-gate.sh` failure; that was a state-isolation
bug in the suite, since fixed. Each readme-family case now gets its own fresh probe session id
with probe state cleaned either side, and three consecutive runs — two deliberately cold —
were 78/0.

Three traps that make a case pass or fail for the wrong reason, all hit while writing these:
- **`jq -e` exits 0 on EMPTY input** on this box's jq 1.5rc1, so a block-shape probe reports
  "block" for a hook that said nothing. `decide()`/`decide_block()` test `-z "$raw"` FIRST.
- **Some gates self-resolve the harness** from `~/.claude/skills` and ignore this script's
  `$harness` argument, so their payloads must name the real harness (`$real_harness`) even when
  `$hooks` is a relocated copy. Otherwise they fall through to "pass" and read as gate bugs.
- **State-carrying gates are one-shot or thresholded**: the readme family records per-session
  state and `readme-currency-gate.sh` only nudges above 5 accumulated changed lines;
  `jira-fixversion-confirm-gate.sh` reads `~/.claude/.confirmed-jira-versions`, so test versions
  must be absurd (`release/999.0.0`) rather than real ones that may already be confirmed.

Add a case for any match rule you add or remove, **especially a false-positive case**. Both
faults found in these gates so far were false positives, not missed denials — the in-place
gate's first version denied its own commit, because the message described the hazard and a
quote-blind matcher can't tell prose from an invocation.

**`bash scripts/mutate-gates.sh`** is what proves the suite: it neuters one gate at a time
(`exit 0` after the shebang, in a throwaway copy — never the live hooks, other sessions run
against those) and asserts the suite NOTICES. Every covered gate is currently detected, 0
undetected, with per-gate failure counts matching its deny-assert count. A case that cannot
fail is worse than no case, so run this after adding cases — a green `check-gates.sh` alone
does not tell you the new case does anything.

Fixtures live inside that script, never inline in a Bash command — a real-looking fixture in
command text self-triggers the gate under test, and hand-escaped JSON collapses in transport
(both in the `bash-command-style` skill).

**Hook fork budget** — process creation costs ~60ms on this machine (Intune-managed
Sysmon64 with `CheckRevocation` + HVCI; per-exec certificate checking, confirmed by
signed binaries costing ~3x unsigned and warm re-runs not getting cheaper — not
Defender, whose CPU stayed flat under a spawn loop, and not hardware). A single Bash
tool call matches 11 PreToolUse + 4 PostToolUse hooks (unaffected by
`human-readme-edit-gate.sh` below, which matches `Edit`/`Write`, not `Bash`/`PowerShell`);
the full stack measured **11.7s per tool call** before de-forking, **~2.2s** after
(<harnessEpicKey>). The floor is
~0.8s of unavoidable `bash` launches. Conventions that keep it that way:
- Every `Bash`-matched gate opens with a pure-bash `case` needle test on the RAW
  payload (precedent: `aggregation-secret-gate.sh`) before any `jq` fork — a
  non-matching call exits on zero forks. The needle must be a literal substring of
  everything the gate's real regex can match; false positives fall through harmlessly.
- One `jq` per payload, never one per field (`// ""` for fixed line positions) — and
  **strip `\r` after `read`**: jq.exe emits CRLF, `$(...)` strips it but `read` does
  NOT (confirmed the hard way; a stray `\r` in a path breaks every comparison).
- No `$(cat "$f")` in loops over `.session-chatfiles/` (380 files ≈ 18s) — `IFS= read
  -r var < "$f"` and test the VARIABLE (statefiles have no trailing newline, so `read`
  exits 1 while still populating it). Skip bookkeeping files by "basename contains a
  dot", not an enumerated suffix list (lists drift; the old ones were six behind).
- `$(shell_function)` is a full process under MSYS (no real `fork()`) — hot-path
  helpers assign a global instead of printing (`statusline.sh`'s `color_for`).
- `statusline.sh` renders continuously: it dropped ~2.3s → ~0.3s per render
  (one merged jq, bash-arithmetic thresholds, own-format statefiles parsed with bash
  regex instead of jq).

**Not a gate, run on demand:** `hooks/redact-secret.sh <literal|-> [replacement]` strips a
leaked literal out of local Claude Code state — transcripts (incl. `subagents/`),
`file-history` snapshots, chat logs, hook logs — walking the whole `~/.claude` tree plus
this repo rather than an enumerated subset. Uses `perl`, not `sed` (a secret containing `&`
would corrupt a `sed` replacement), prints per-file counts and never the value, and is
idempotent. Pass `-` to read the secret from stdin so it never enters a command line. It's
**hygiene, not containment** — if the value is committed in a repo or live on a server,
rotation is the only real fix.

## Portability — general harness vs AMA_APP-specific content

This harness isn't tied to one machine — see **"Installing on a new machine"** at the top
of this file for the clone/install/personalize flow (`scripts/install.ps1` +
`/harness-setup`). Org-specific identifiers (email, Jira/Confluence IDs, AWS account/
region, Octopus server/space/environment IDs, Graylog host/alert stream, Bitbucket org/
repo-slug prefix, CodeArtifact domain/repo, app domains per environment, library prefix,
release recipients/approvers) live in one file, `~/.claude/harness-config.json`, not
scattered across scripts and skill prose (PROJ-15143, both waves — repo
locations/naming, then every remaining hardcoded identifier, fully done). That file is
**untracked** (gitignored) — the cross-machine source of truth is the org's
**"Claude Harness" Octopus library variable set** (one JSON-blob variable,
`HarnessConfigJson`, which must stay non-Sensitive-typed: Sensitive is write-only via
the API, a fetch would get a mask). Sync via `scripts/octopus-config-sync.sh fetch|push`
— setup-time only, nothing fetches at runtime; the per-person `user` block is never
pushed and never overwritten by a fetch. A fresh clone gets the file seeded from
`harness-config.example.json` by `install.ps1`. **The push-after-edit half is
mechanically enforced, two channels:**
- `octopus-config-push-reminder.sh` (`PostToolUse` on `Edit`/`Write`/`Bash`/`PowerShell`)
  content-hashes the config against `~/.claude/.harness-config-synced-hash` whenever a
  tool call names the file (or runs the sync script — a bare `push` command must reach
  the re-baseline branch or the statefile goes stale the moment the nudge is obeyed).
  An actual change nudges: own mid-task edit → push when the edits are complete; a
  picked-up manual/external change → push immediately and tell the user. Mere reads
  stay silent; the sync script's own fetch/push runs re-baseline without nudging.
- `on-prompt.sh` catches manual edits no tool call ever names: a zero-fork `-nt` mtime
  test against the statefile per prompt, one confirming `md5sum` only when the config
  is newer, then injects "push NOW automatically, then tell the user" — re-injected
  every prompt until the push happens (which re-baselines the statefile). A same-bytes
  rewrite just refreshes the statefile mtime to quiet the `-nt` test. Two read
behaviors, chosen per key: most fall back to a default (missing/malformed field →
original hardcoded value, no error) so an unconfigured harness still runs with this org's
values; a smaller set (`hr_config_required` in `lib-harness-repos.sh`) that decides WHICH
COMPANY'S infrastructure a call actually hits — Bitbucket org, AWS region/account,
Graylog host, Jira project key — fails loud instead, since a silent default there means
querying the wrong org's real infrastructure, not just using a placeholder.

Not everything is swappable this cheaply, though — some skills assume AMA_APP's actual
fleet shape (ECS-deployed .NET services, Octopus, Bitbucket, Jira/Confluence via the
Atlassian MCP), not just its identifiers:

**AMA_APP-specific — opt-in, skip if your fleet looks different:** every skill prefixed
`ama-` (`ama-architecture-notes`, `ama-debugging-notes`, `ama-cut-release-branch`,
`ama-deploy-release`, `ama-release-notes`, `ama-library-version-sync`,
`ama-search-shared-version-sync`, `ama-library-pr-propagate`, `ama-octopus-deploy`,
`ama-bitbucket-api`, `ama-cloudwatch-search`, `ama-graylog-search`,
`ama-team-meeting-notes`, `ama-hotfix`, `ama-postgres-access`, `ama-ui-verify`,
`ama-report-debug`, `ama-jira-api`, `ama-confluence-api`, `ama-embs-reminders`), plus
`company-slides` (YourCompany-brand-specific rather than AMA_APP-fleet-specific — not
prefixed `ama-` for that reason, but equally opt-in/skip-if-different). Four of these
have no dedicated section above — one line each:

- `ama-octopus-deploy` — resolves/triggers Octopus deployments directly (space/project/
  environment, task polling), and the Bitbucket-branch workaround if Octopus itself is
  unreachable.
- `ama-confluence-api` — direct Confluence REST for what MCP has no tool for at all:
  uploading/embedding an image on a page (`contentFormat="adf"` bypasses an HTML→ADF
  converter bug that drops media nested in a list item), and archiving a page (no
  delete/trash tool exists anywhere).
- `ama-team-meeting-notes` — the weekly "This week" Confluence update: Open→To Do
  promotion for the tickets selected to work on.
- `ama-deploy-release` — release-day cutover itself: master merge, production deploy,
  main cache update, verify, revert path, branch cleanup (the stage AFTER
  `ama-cut-release-branch`).
- `ama-embs-reminders` — reads the eMBS publishing calendar for GNM/FNM/FHL
  monthly-file arrival dates and creates next-day all-day Google Calendar reminders
  carrying the AMA ETL runbook. Config: `harness-config.json`'s `embs` block
  (`calendarUrl`, `googleCalendarId`). Auto-nudged via `hooks/embs-coverage-check.sh`
  (sourced from `on-prompt.sh`, throttled to once/day) once the published tag window
  is about to run out — the calendar page itself is evergreen/rolling, never goes
  stale, so no URL-verification prompts are needed. A created reminder looks like this:

  ![eMBS reminder event](docs/embs-reminders-images/image-1.png)

- `ama-embs-notices` — sibling of the above, and the other half of eMBS coverage: that one
  reads arrival DATES off the calendar, this one triages the CONTENT of `eMBS Data Notice:`
  emails for AMA relevance. Exists because a vendor WARM/WALA basis change announced three
  months ahead — as one closing note under a Reperforming-Loans subject line — was missed
  and became a production incident (PROJ-15307 tracks the impact work). Hence its
  first rule: subject identifies, never scores; scope is judged per paragraph. Tiers
  T1–T4, no numeric score and no suppression threshold.
  **The sender sweep is the primary net, not a backstop** — a 2025-11-05 notice dropped
  `eMBS` from its subject entirely and the prefix search would have missed it (also why
  `noticeSubjectPrefix` is the looser `DATA NOTICE:` now). Backfill runs
  also established that AMA reads eMBS **Database** format, not Agency Aligned format, so
  position-keyed/Agency-scoped notices are usually moot for us (evidence in
  `AMA-SURFACE-MAP.md`), and that opt-in format upgrades ("Submit a Request", ~3-month
  window, no reminder, silent absent columns) are the recurring expensive trap.
  Product scope carries two axes because notices name **files** while the calendar names
  **tags** — the map holds both, and its loan-level file list is closed (2026-08-12,
  entitlement `REFINITIV-1`). Two things stay deliberately open there rather than being
  inferred into the confirmed-exclusions list: the stratification family
  (`GNM_LDST`/`LoanDist`, PROJ-15310) and the pool-level product list. Also encoded:
  "we don't report field X" retires VALUE changes only — a column-count change on an
  ingested file still breaks the load.
  The seen ledger enforces disposition: `embs-notices-record.sh add` refuses a T1/T2 row
  without a ticket key, `stale`, or `pending`; `settle` resolves a pending row once its
  answer arrives; the plan script re-emits `pendingIds` every run so pending rows can't
  be forgotten. `finish <candidate ids>` (or `finish --none`) stamps `lastrun` only when
  every candidate has a seen row — coverage is checked against the ledger, an interrupted
  run re-fires; the candidate list itself is still caller-supplied (Gmail is MCP-only).
  Final row field is `intact|clipped` body completeness, not a size guess.
  Config: the `embs` block's `noticeSenders`, `noticeSubjectPrefix`, `noticeCheckDays`,
  `noticeLookbackDays`, `noticeOverlapDays`, `noticeSlackMinTier`, `noticeReportTarget`
  (the user's Slack DM today — flip that ONE value to a channel id to broadcast: a `U…`
  id DMs, a `C…` id posts to the channel, same `slack_send_message` call; delivery
  verified live 2026-08-17). State: `~/.claude/.embs-notices-{seen,lastrun,nudged,digest,pinged}`,
  dedupe on Gmail message id. Nudged via `hooks/embs-notices-check.sh` (sourced from
  `on-prompt.sh`, once/day) — the PRIMARY scheduler. Headless `claude -p --allowedTools
  mcp__claude_ai_…` executes connector calls for real (verified 2026-08-17: Gmail search
  and Slack send both ran), so a weekly task (`AMA-Harness-EMBS-Notices-Ping` →
  `skills/ama-embs-notices/scripts/embs-notices-unattended-ping.sh`) backstops the
  no-session-for-weeks hole: DETECTION only — candidate counts → Slack DM + one
  `.embs-notices-digest` line (surfaced then truncated by the nudge hook). It never
  triages and never writes seen/lastrun; an unattended wrong verdict would suppress a
  notice forever, so judgment stays in-session. Same schtasks caveat as fleet-health:
  InteractiveToken, runs only while logged on. Gmail read tools (`search_threads`/
  `get_thread`/`get_message`) are allowlisted in `settings.template.json`, per the
  "list what skills call" rule.
- `ama-followups` — works a durable ledger (`~/.claude/.pending-followups`) of multi-week
  Slack-reply escalation chains (e.g. "remind at +1wk, escalate to someone else at +2wk,
  act at +4wk if still silent"). `CronCreate` can't carry these — it's session-only and
  auto-expires after 7 days — so the ledger is plain on-disk state instead, same shape as
  `ama-embs-reminders`'s coverage file. Nudged by `hooks/followup-check.sh` (sourced from
  `on-prompt.sh`, throttled to once/day) whenever a row's due-date has passed.

`skills/ama/` is a browsing-only index — real symlinks (not junctions; a junction inside
this same repo would double-track the files under two paths) back to each `ama-`-prefixed
skill directory above, purely so `ls skills/ama/` shows the grouped set at a glance. Claude
Code's own skill discovery never looks inside it (it only scans exactly one level under
`skills/`), so it's inert to invocation — the real directories stay flat. Adding a new
AMA_APP-specific skill means creating both the real `skills/ama-<name>/` directory *and*
its symlink here.

**General-purpose — applies regardless of org/fleet:**
`commit-ticket`, `resource-efficiency`, `chat-log-reads`, `caveman`, `karpathy-guidelines`,
`rename-topic`, `relocate-session`, `open-chat-file`, `process-prompt-queue`, `write-a-skill`, `verify`,
`grill-me`, `context-hygiene`, `grep-usage`, `bash-command-style`, `slack-search`,
`usage-monitor`, `harness-setup` itself, `gmail-drafting` — email draft/send requests
must `ToolSearch` for the Gmail MCP first, never CLI-only text or `claude-in-chrome`
browser automation as a substitute; also carries the signature-refetch step (API drafts
get no Gmail auto-sig) and a sonnet proofread pass for external recipients — which you
must WAIT for, not launch and then declare the draft ready.

---

## Public GitHub mirror

This repo has a **public**, sanitized mirror at `https://github.com/rsryanstephen/AMA-Harness`.
The mirror is a fresh single-commit snapshot, never this repo's history.

- **Republishing is automatic** — `hooks/on-stop.sh`'s `publish_public_mirror` fires
  right after `auto_commit_push_harness` confirms a real harness commit landed on
  Bitbucket, sha-marker gated (`~/.claude/.harness-last-published-sha`) so a quiet Stop
  is a no-op, never blocks Stop on a slow/offline GitHub (`timeout 90`, failure logged
  to `harness-gaps.md` + `~/.claude/.harness-publish-public.log`, not raised as an
  error). Manual refresh still works the same way: `bash scripts/publish-public.sh`
  (add `--dry-run` to build + gate without pushing; the export tree is kept for
  inspection).
- **A forbidden token is caught pre-commit, not after** — `hooks/publish-scrub-gate.sh`
  denies a `git commit` in this repo whose staged content would abort the gate. It calls
  `scripts/publish-public.sh --check-paths <staged paths>`: same combined map, same scrub,
  same gate, but against the WORKING-TREE copies, because the normal path exports
  `git archive HEAD` and pre-commit that would inspect the previous commit. Added after
  the gate aborted every publish for a day and the only trace was a `harness-gaps.md`
  line. ~2s per harness commit.
- **Fix a gate hit by MAPPING the literal, not by rewording prose.** That includes a
  deliberately generic placeholder: `ec2-*.<region>.compute.amazonaws.com` is a wildcard, not a
  hostname, and leaks nothing — but the gate pattern `compute-1\.amazonaws` matches inside
  it and no literal hostname covers it, so it aborted the publish. It now has its own
  entry in the generic-placeholder block of `scripts/public-scrub-map.txt`. That's a
  rewrite, not a gate exemption — the gate stays absolute, anything else matching still
  aborts, and there is no marker or bypass anyone could paste onto a line that carries
  something real. Reword only when a token has no business in the repo at all.
- What the scrub does: excludes `harness-config.json` (real values), `memory/`,
  `harness-gaps.md`, `docs/` screenshots, `.skill` ZIP bundles, and
  `skills/company-slides/assets/reference-deck.html` (internal deck content;
  the skill dir itself ships renamed `company-slides`); then replaces every sensitive
  literal with a placeholder. Half the map is generated live from
  `harness-config.json` vs `harness-config.example.json` (new config values are
  auto-covered), the other half is `scripts/public-scrub-map.txt` for literals that
  were never config keys (client names, bare hostnames, colleague names). Both that
  map and `scripts/public-scrub-gate.txt` are themselves excluded from the export —
  they enumerate the secrets.
- The gate aborts the push on ANY residue: an idempotency check (re-running the scrub
  must change nothing) plus case-insensitive forbidden-pattern greps over content and
  file paths, then `bash -n` on every script and `jq` on the example config to prove
  the substitution broke no syntax. The snapshot commit uses the GitHub noreply
  identity, not the work email.
- **The private Bitbucket history DOES contain real `harness-config.json` values**, from the
  initial import (`959ee93`) until it was genuinely untracked on 2026-08-17 — 18 commits, and
  two earlier commits *claimed* to untrack it without succeeding. Assessed 2026-08-17 and
  **deliberately not rewritten**: no credentials in any blob (org identifiers only — emails,
  Jira/cloud ids, AWS account number, Octopus URL, Graylog host), Bitbucket is private, and
  the public mirror provably never carried it (`git ls-remote` on the GitHub repo returns a
  single commit, and the one raw full-history push predates the delete-and-recreate below,
  while the repo was still private). A rewrite would change every hash in the repo's life and
  invalidate the hashes cited across `AGENTS.md`, `harness-gaps.md`, skills and Jira. Don't
  re-litigate this without a new reason — and if one appears, the decision is a rewrite of
  Bitbucket only; GitHub needs nothing.
- **Never add a `github` remote to this repo / never push working history to GitHub**
  — the remote added earlier for the private mirror was removed deliberately; the
  publish script pushes by URL only. If sensitive history ever lands on the GitHub
  repo again, delete and recreate the repo there — a force-push is NOT enough (GitHub
  keeps force-pushed-away commits fetchable by SHA).

---

*All of this lives in plain markdown files — nothing depends on remote or cloud state.*
