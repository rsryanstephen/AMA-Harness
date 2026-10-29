# AMA Claude Harness

**This file is for AI agents.** It is the operational source of truth for this harness —
every hook, gate, skill and confirmed failure mode. For humans, see `README.md` (brief
install/usage guide, updated only when human-visible behavior changes — never
auto-updated the way this file is).

**This file loads into EVERY session's context — keep it a terse operating manual + index
(diet 2026-08-31: 253KB → 69KB).** Routing for new content: a one-line rule/pointer bullet
belongs here; incident narrative and per-hook rationale → the hook's own header (or
`GATES-AND-HOOKS.md` for suite/authoring guidance); install/setup detail → `INSTALL.md`;
org-portability, notice-monitor and scheduled-task mechanism detail → `PORTABILITY.md`;
skill mechanics → that skill's `SKILL.md`. When the currency nudge fires, add the
one-liner here and put the substance where it belongs — never a writeup in this file.

## Symptom index — route by the problem you have (PROJ-15363)

| You've hit… | Go to |
|---|---|
| No tone / silent chime / unexpected ding | "Notification sounds" below; silent-chime → `notify-sound-play.ps1` header |
| A tool call frozen for minutes / spinner with nothing running / every terminal slow | `memory/frozen-tool-call-check-suspended-hook-orphans.md` |
| A permission prompt or denied call you didn't expect | Gate table under "Reducing permission prompts"; the hook's own header has the full rule |
| git push failing/rejected (DNS, SSH, port 22, pre-receive), Bitbucket API timeouts, push with no pipeline | `commit-ticket`'s transport section; resolver errors → `ama-vpn-dns-outage` |
| Writing/wiring/testing a hook or gate | `GATES-AND-HOOKS.md` |
| Installing on a new machine / missing credential | `INSTALL.md` |
| A scheduled task that didn't run, flashed a console, or config sync | `PORTABILITY.md` |
| Ticket/commit/transition rules | "Commit & ticket discipline" below + `commit-ticket` skill |
| Drafting a ticket for the IT department | `it-ticket` skill (Markdown file in `IT Tickets/`, terse body) |
| Chat file renamed / queued prompts / finding past sessions | "Chat Logging & Session Management" below |
| Jira/Confluence REST calls | `ama-jira-api` / `ama-confluence-api` skills (MCP retired) |
| Context/cost ballooning | `resource-efficiency` + `context-hygiene` skills |
| Public-mirror publish aborted | "Public GitHub mirror" below |
| Changing a shared builder/lib/template; "it inherits the change" | `ama-debugging-notes` SHARED-CHOKEPOINT-CHANGES.md (EXPLAIN every shape: `rs-explain-shapes.sh`) |
| Writing/re-applying a DB migration, backfill, datafix or bulk update | `ama-debugging-notes` PERSISTED-DATA-REWRITES.md (sequence test, real shapes, dry-run diff, reader census) |

`scripts/findability-eval.sh` tests this routing (headless "where's the guidance?" probes,
PROJ-15365) — run it after any doc restructure; log misses to `harness-gaps.md`.

## Model tiering — skills, not just subagents

- **Policy (user, 2026-10-22, memory `regulation-tasks-on-sonnet`)**: regulation work
  (deploy, monitor, sync, log check, Jira writes) runs on Sonnet whatever the session model;
  reasoning stays on the session model; a subagent needing judgment gets the SESSION model,
  never a fixed opus.
- **Subagents** — default Sonnet via `settings.json` env `CLAUDE_CODE_SUBAGENT_MODEL=sonnet`
  (every agent type AND Workflow `agent()`; omitted `model` no longer inherits the parent).
  Opt down `model:"haiku"` for mechanical work, opt UP to the session model only for real
  judgment -- `subagent-model-tiering-gate.sh` (warn-only, the one `Agent` hook) nudges for
  an output-budget line and names the live session model when `model` is omitted.
- **Skills** — `model:` in SKILL.md frontmatter engages ONLY on user `/slash` invocation
  (whole turn on the tag); Skill-tool invocation by Claude ignores it (probe 2026-10-22, CLI
  2.1.308; the 2026-08-31 "inert" verdict was a Skill-tool turn). A tag = "when the user
  runs this by hand, run it on X". Claude-initiated cheap execution still needs
  `context: fork` + `model:` + `background: false`. Which skills carry which tag, and why:
  `resource-efficiency`'s "Skill-level model tiering" (14 regulation runbooks -> sonnet
  2026-10-22; `ama-hotfix` untagged, its ship leg is `ama-deploy-release`).
- **Injection refresh (2026-09-01)**: `on-prompt.sh` sends the full memory-note list and
  the chat-log rules on prompt 1 then every 10th, a short pointer between (492 -> 59 words
  measured). Chat FILENAME still every prompt -- it changes on rename. Counter:
  `$STATED/<sid>.promptn`.
- **`commit-ticket` progressive disclosure** (2026-09-01): still 12% of a usage window after
  the fork split, because its own description says load it at the START of every substantive
  task -- so the fix was loading, not model. Core 315 -> 154 lines; five on-demand reference
  files (`GIT-TRANSPORT`, `REGRESSIONS`, `QUERYING-TICKETS`, `SHARED-REPO`, `LEAVING-CONTEXT`),
  each left a one-line pointer naming its trigger. Zero rule text lost (content-set diff).
- **`commit-ticket` split** (2026-08-31): core = judgment + git mechanics + anything that
  talks to the user; `commit-ticket-jira` = FORKED cheap-model executor, Jira WRITES only.
  Core decides and DRAFTS, fork posts; fork has no session context and never asks the user
  (missing field → returns `NEEDS: <field>`). `TICKET-TEMPLATE.md` stayed with the core,
  `BACKLOG-PAGE.md` + `scripts/` moved to the fork.

## Installing on a new machine

Full install/setup reference — prerequisites, per-capability credentials table, installer
mechanics, verification checklist — moved to **`INSTALL.md`** (repo root, 2026-08-31).
`scripts/install.ps1` + `/harness-setup` is the flow (re-run install adds new example config blocks to a live config; `/harness-setup <block>` fills them; it also adds the `~/.secrets` loader + `ros` to `~/.bashrc` -- credentials go in `~/.secrets`, never `.bashrc`). `scripts/` is junctioned to
`~/.claude/scripts/` alongside `hooks/` (2026-09-01) — docs and skills may hand out a
`~/.claude/scripts/<name>.sh` command; before that link existed every one of them failed.
Two platform traps that matter in NEW
CODE any day, not just install day (this box's jq is 1.5rc1; both nudged live by
`msys-command-traps-nudge.sh`, PROJ-15361):
- **`jq -r` output is CRLF** — piping one `jq` into another, or into a `while read` loop whose
  values reach a native exe, needs `| tr -d '\r'` (every line but the last gets a CR and
  silently matches nothing; AWS rejects a CR-suffixed ARN naming anything but whitespace).
  `lib-harness-repos.sh`'s `_jqr()`
  strips it and reads via stdin.
- **No `--slurpfile`** (exits 2) — read the second document on stdin, or `--argfile`.
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
- **Headless/`-p`/SDK sessions get none of this.** `on-prompt.sh`, `on-stop.sh`,
  `on-session-end.sh` and `session-name-sync.sh` all early-exit, and
  `log-session-start.sh`'s cross-session sweep skips them, when
  **`session_is_headless`** (`hooks/lib-session-kind.sh`) says so. No chat file, no
  `sessions.txt` row, nothing to sync or rename. Exists because the harness's own
  unattended scheduled runs (standup-notes, support-notices, embs-notices,
  team-meeting-notes, harness-gaps) and `scripts/findability-eval.sh` each spawn a brand-new session,
  and none of them is something the user started, named, or wants to see in their session
  list — confirmed real: once a cwd fix let these succeed at writing a chat file instead
  of failing in System32, they cluttered `sessions.md` with unnamed
  `ama-claude-harness-NN` rows.
- **Use `session_is_headless`, never a hand-rolled entrypoint read.** Claude Code stamps
  `"entrypoint":"sdk-cli"` (headless) / `"entrypoint":"cli"` (real terminal) on the
  transcript itself, so nothing has to cooperate — but *how* you read it has bitten this
  harness twice. A `head -c 4000` window looked obviously fine and matched **nothing**:
  the field is on line 3 in almost every transcript but at byte 4403–4730 in unattended
  runs and byte 86061 in one interactive session, so the whole suppression above was dead
  code for days without a single symptom. The lib is line-bounded (20, against a deepest
  observed 7), fork-free (process spawn here is ~0.55s, and this runs on every prompt and
  every tool call), and matches `sdk-cli` explicitly so an unknown future interactive
  entrypoint fails toward *keeping* a real session's chat file. Own session → env
  `CLAUDE_CODE_ENTRYPOINT` (trusted only when `CLAUDE_CODE_SESSION_ID` names the transcript),
  no read; other sessions → `[[ =~ ]]`, never a `*…*` case glob (CLI 2.1.306's 234 KB line-7
  record took the glob 127-190 s: every prompt stuck 2-3 min, 2026-10-21, 371a602).
- **`log-session-start.sh`'s own per-session init still runs for headless sessions** — at
  `SessionStart` the transcript has no user message yet, so the signal doesn't exist that
  early. `on-prompt.sh` therefore *undoes* that init the moment it does know: it deletes
  the statefile, its sidecars, and the (dangling) `Local Chat Files/<shortid> Chat.md`
  symlink before exiting. Only ever unlinks a symlink whose target doesn't exist.
- **Backstop: `scripts/prune-headless-sessions.sh`** removes any headless residue that
  slips past — `sessions.txt` row, central chat file, symlink, statefile+sidecars. Dry-run
  by default, `--apply` to act, `--time-budget SECONDS` to bound the classification pass.
  Verdicts are cached in `.session-chatfiles/<sid>.entrypoint`; a session whose transcript
  was written in the last 600s is left alone (a run still in flight owns its files); a
  chat file another session also records is never deleted. A second pass catches
  **orphaned** chat files — ones no statefile records any more, which is most of the
  visible clutter, since statefiles get deleted and aged out while the file they pointed
  at never does. It recovers the sid from the `(shortid)` collision suffix, the
  `claude --resume <uuid>` line `on-session-end.sh` appends inside the file, or a
  shortid-only name, and deletes only what classifies headless — anything unresolvable is
  kept. That guard earns its keep: `ama-claude-harness-f0 Chat.md` looks exactly like
  automation and is in fact the user's own session `533450a8`. `hooks/headless-prune-check.sh`
  (sourced from `on-prompt.sh`) detaches it once per calendar day, logging to
  `~/.claude/scratch/sessions/headless-prune.log`. The user's standing instruction: they
  should never have to ask for this cleanup again.

## Naming the chat file

- **Default:** `<shortid> Chat.md` in the current directory — but that's a symlink. The
  real file lives in `Chat files/` in this harness repo (centralized, greppable, safe to
  open/edit directly) via `lib-chatfile-link.sh`; the session's own bookkeeping still
  points at the cwd path, so nothing else about the workflow changes. `Chat files/` is
  also junctioned into `~/.claude/Chat files/` (`scripts/install.ps1`), so every
  session's log is browsable from there too without cd-ing into the harness repo.
- **Name it yourself:** write your task into `<your name> Chat.md`, then submit `` See prompt in `<your name> Chat.md` `` — the pointer text itself is never streamed. That name is adopted as the log, but since the file always follows Claude Code's own session name (see "One name per session" below), it only *sticks* once you run `/rename <your name>` — Claude tells you to.
- **Otherwise:** the file follows Claude Code's own session name automatically, and stays in sync as that name changes.
- **Still unnamed?** A mechanical fallback renames it once the CLI has a real name to give it — no model turn needed.

## Pointing back at what you wrote

- Pre-write your task in the chat file, then submit a short pointer: `See latest prompt`.
- **No filename given, exactly one unclaimed chat file in the directory** → adopted automatically, no new file created.
- **More than one unclaimed candidate** → Claude asks which one you mean.

## Renaming a topic

There is one name — Claude Code's own session name — so the only real rename is `/rename`
(client-side; no tool/hook can invoke it). Claude never renames the file directly.

- **"rename this topic to X"** — Claude tells you to run `/rename X`; the file follows automatically at the next turn end.
- **"rename topic"** (no name) — Claude picks a good one from the file's *current* content, not just its first prompt, and tells you to run `/rename <that name>`.

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
prompt uses `/btw`. Commit scope is FILE-level: two sessions editing the same harness
file (AGENTS.md, check-gates.sh) each carry the other's hunks in their pathspec commit —
accepted; `git diff -- <file>` before committing a shared file.

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
- The `Stop` ding is also **suppressed when the turn ended with live background work** (backgrounded Bash task, async agent, Monitor still running; never a reminder watcher or a TaskStop'd task) — that Stop is a hand-off; the completion turn's Stop dings. Launched IDs not yet paired with a terminal `<status>` notification; a Monitor past launch+timeout counts as dead. Logged `[bg-live: <ids>] [suppressed]`; grep read error fails open with `[bg-check-error rc=N]`. Detection mechanics (no process substitution — msys named pipes flaked, f7feade0) in `notify-sound.sh`'s header.
- The `Stop` ding is also **suppressed entirely for headless runs** (`claude -p` from a hook/unattended runner — e.g. `<amaSupportChannelName>-notices`/`ama-embs-notices`/`ama-standup-notes`/`ama-harness-gaps` sweeps) — confirmed real: 14/14 historical headless runs dinged, all `stop`, and the tone is indistinguishable from the user's own session finishing (one such sweep dinged 2s before an unrelated advisor result in another session and was mistaken for it). Detected via `session_is_headless` (`hooks/lib-session-kind.sh` — the one implementation every consumer uses; a second hand-rolled copy elsewhere is what silently broke the session-list suppression, see **How the streaming works**). `Notification` is untouched (headless can't prompt; muting it there would also kill the API-error-stall chime unasked-for). Logged as `[headless]`.
- **One exception**: `Stop` never fires on a turn that died on an API error (529/etc — confirmed real), so this same idle-timer notification is the only signal that a turn stalled. The hook checks the transcript tail for a trailing `isApiErrorMessage` entry and, when found, does NOT suppress — plays "Windows Critical Stop" (falling back to "Windows Hardware Fail" — never Ding or Notify Calendar, per explicit user instruction not to reuse those two — if the primary file isn't present) and logs `[api-error-stall status=<code>]` instead of `[suppressed]`. Paired with `CLAUDE_CODE_MAX_RETRIES` (see `settings.json`'s `env` block) riding out the retry-able window in-session first — this is only the backstop for what escapes that.
- The stock Windows chimes are mastered very quietly (Ding peaks at 7% of full scale — inaudible over music), so the hook volume-normalizes them to 95% once into `~/.claude/harness-state/logs/.notify-sound-cache/` (machine-local, gitignored) and plays the boosted copies. Pure sample scaling into real headroom — no clipping. Delete the cache dir to regenerate; a non-PCM or already-loud file falls back to the original untouched.
- Every invocation is logged to `~/.claude/harness-state/logs/notify-sound.log` (when, which event, which session, the Notification message if any) — the answer to "why did a tone just play?". A tone that seems to fire for nothing is usually a `Stop` at a mid-task turn end. Two lines per invocation: a `[start]` breadcrumb written first, then the full verdict line. **A `[start]` with no completion line after it means the hook was killed by its timeout** — before this existed (PROJ-15356) a killed hook wrote nothing at all, so "timed out" and "never invoked" were indistinguishable, and the log went blank in the one failure mode it exists to catch. The breadcrumb is deliberately fork-free (printf `%(..)T` builtin, bash substring for the sid, inlined path rather than `hstate`) and sits above the `jq` block: measured on MSYS, four `jq` forks alone delay it past 1.5s, which would miss the very kill it is meant to catch.
- **Silent chime while all other audio works = powershell's per-app Volume Mixer volume, NOT the output device** (PROJ-15360) — endpoint volume and per-app session volume are different things, measure both; `[console]::beep` still working proves nothing (renders through the system-sounds session). Self-heals: `hooks/notify-sound-play.ps1` repairs its own session volume after each tone (full mechanism, recurrence cause and design reasoning in that file's header — relocated there 2026-08-31, PROJ-15363).
- `scripts/fix-powershell-volume.ps1` is the on-demand remedy (forces 100%, reports before → after; plays one chime deliberately — no session exists to repair until something renders).
- **A hook that greps the transcript MUST bound the read to a tail window — never scan the whole file.** Transcripts only grow and never shrink: one long-lived session reached 96 MB / 48k lines while every other session on the machine sat under 10 MB. `notify-sound.sh`'s `Stop` branch scanned all of it for live-background-task IDs, which cost more than the hook's whole 5s timeout, so the hook was killed mid-scan every single turn — no tone, and (before the `[start]` breadcrumb) no log line either. Diagnosis signature: the *same* hook's cheap path still logs while its expensive path never does (here, `Notification` logged 2 entries the same day `Stop` logged 0, while smaller sessions logged 59). The fix is `tail -n <window> "$tr" | grep ...` with the window sized to "any turn in which this could still be true" (3000 lines for background tasks); it fails in the safe direction, since a record that scrolls out is simply not seen. Measured: 2.84s → 0.16s, same verdict. Same unbounded pattern still exists in `on-stop.sh` and `lib-fallback-rename.sh` — those need per-site judgement, see PROJ-15357. New hook edits that reintroduce the pattern are nudged by `transcript-scan-bound-nudge.sh` (PROJ-15361).

## Finding past sessions

`sessions.txt` = master index, one line per session, every repo:

```
<name> cd <dir> && claude -r <session-id>
```

Real files live at repo root (`sessions.txt`/`sessions.md`, gitignored, per-machine);
`~/.claude/` copies are symlinks. Every rewrite goes through `lib-sessions-lock.sh`'s
`sessions_write_through` (resolves the symlink, atomic `mv` — readers must never see a
truncated file).

- Grep by name or folder (`grep AMA sessions.txt`); copy from `cd` onward to resume. Field 1
  IS Claude Code's own session name (see "One name per session"), so txt and md always agree.
- **Sorted most-recently-active first** — no timestamp; `on-prompt.sh` re-prepends the
  touched session's line per prompt. Lock-protected, self-healing (a missing session is
  re-added on next prompt). Only sessions that received a prompt get a line; non-UUID-shaped
  sids never do (keeps hook-test fabrications out — keep fake sids non-UUID-shaped).
- **`sessions.md`** = same data rendered for viewing; never edit it. Only parser:
  `scripts/open-sessions.sh` (`ros [n]`) -- row-format change -> update its regexes.
  Resume handle, one-name-per-session collision rule, display-name override, `--chrome`
  suffix, context-size column, the three row-hiding clauses and the shared-name fixer
  (`scripts/session-name-dedupe.pl`, hourly from `on-stop.sh`): `GATES-AND-HOOKS.md`
  § "sessions.md rendering rules".
- **One perl process renders everything** (`session-ctx-sizes.pl` via thin
  `render-sessions-md.sh`): parses txt, reads the last ~300KB of each transcript for the
  usage blob (bounded 3MB fallback — one JSONL line can exceed 300KB; corpus includes a
  91MB transcript), writes md once. The old ~8-forks-per-row bash loop took 43s and blew
  every hook timeout, leaving md stale. Hash-guard skips the write if txt changed mid-render.
- Re-rendered on every txt change, on a changed name capture at Stop, and unconditionally at
  SessionEnd (a name captured on the last turn needs a render to ride on).

### One name per session

Chat file, `sessions.txt` field 1, and `sessions.md`'s bold field are all **Claude Code's
own session name** — no separate harness topic. Wrong name → `/rename <good name>`
(client-side, no hook can run it); the harness mirrors it everywhere on the next turn end.

- **Name-source priority** (`resolve_cc_name`, `lib-fallback-rename.sh`), freshest-wins from
  the live transcript: (1) latest `customTitle` (user-set — must keep winning); (2) whichever
  of `aiTitle`/`agentName` was written last by file position (they don't move together — a
  fixed tier order freezes on a stale one); (3) transcript unreadable → the
  `.explicitname`/`.claudename` snapshots, then `sessions/<pid>.json`. One combined grep,
  bounded to the last ~4MB with full-file fallback. Only with no transcript AND no snapshot
  does the old derivation (`away_summary` slug / first chat block) run — and only via
  `attempt_fallback_rename`, never `sync_session_name`.
- **A live session follows every name change mid-turn**: `sync_session_name` runs from
  `on-stop.sh` (last statement; Stop timeout is 30s to match its internal 25s ceiling) and
  from `session-name-sync.sh` (PostToolUse `*`, throttled 120s/session) — no-ops when the
  resolved name already matches the chat-file basename. The mid-turn hook exists because a
  multi-hour turn re-titled 4 times with nothing reaching sessions.txt until turn end. On an
  actual mid-turn rename it emits `additionalContext` (not `decision:block` -- that renders as a red "blocking error") naming the new chat-file path
  (`flush-reply.sh`'s reverse lookup hard-fails on the stale path exactly in the
  dequeue-before-turn-end window). Accepted cost: an editor tab can detach mid-turn.
- `on-prompt.sh` nudges toward `/rename` when `.customtitle` is absent — only from the
  session's SECOND distinct auto-title (deduped via `.renamenudge`; first name is seeded
  silently). **Nudge text frames retitling as intended Claude Code behavior, never a harness
  defect** (both per explicit user instruction 2026-08-20).
- **`attempt_fallback_rename`** = older, once-only sibling for sessions still on the bare
  `<shortid> Chat.md` fallback — used by `log-session-start.sh`'s sweep of stale sessions
  and `on-session-end.sh` at clean exit. Dead sessions keep their old names.
- **A suggested name states the OUTCOME, long and plain** (user instruction 2026-09-04):
  what was established or fixed plus the ticket key, never the topic area, never a
  two-clause and-join of two unrelated things, never abbreviated for brevity. A harness
  session ends `- Harness`, not the epic key. Claude Code's
  own auto-title is a starting point to expand, not the recommendation. Rules:
  `rename-topic/SKILL.md`.
- **Superseded names are logged, not lost**: every rename passes through `rename-topic.sh`,
  which appends `<slug> <sid>` to `~/.claude/session-names.txt` — where an older name is
  still greppable.
- **Session names are NOT unique, and nothing enforces it.** `/rename <name>` typed in two
  sessions gives both that name with no warning (confirmed: `cb8b1004` and `0bb7c2c3` each
  hold their own `custom-title` record for `harness-findability-wave`). Then
  `claude -r "<name>"` opens the resume picker instead of resuming, and both rows in
  `sessions.md` fall back to a raw id. Two halves to this: `scripts/session-name-taken.pl`
  (run by the `rename-topic` skill before it recommends anything — exit 0 = taken, prints
  the colliding shortids) stops the harness's own path creating one; the "name(s) shared"
  footer in `sessions.md` reports the ones it can't prevent, since a `/rename` typed
  straight into the client is invisible to every hook.
- A pointer-named file (``See prompt in `X Chat.md` ``) is adopted as the log but `X` only
  survives if the user runs `/rename X` — `on-prompt.sh` says so in both pointer branches.

---
## AMA library version-sync skills

Three skills keep AMA library NuGet references up to date across `~/Repos/AMA_APP/`:

- **`ama-library-version-sync`** — any push to `master` on a library repo. **Step 0 first:
  do consumers NEED the change?** Dead code nothing references, comments, formatting,
  test-only, internal refactor with public API and behaviour unchanged → stop, no bump, no
  sync, don't even mention version bumps (standing user rule 2026-09-08: a code clean gets
  no version ceremony; CI publishing a package on push is not a reason to chase consumers).
  Otherwise: confirm it publishes a NuGet, bump every consumer (gated on green
  `dotnet build` + `test`), confirm per repo before pushing. Cascades fully (a consumer
  that's itself a library keeps the chain going); the consumer list is free text to pick
  from, never the question-picker (it caps at 4 and truncates silently).
- **`ama-search-shared-version-sync`** — `product-service-search` special case: publishes
  from `develop`; auto-scopes to whichever of Search.Shared/Search.Cache changed, then its
  step 0b applies the same consumers-need-it gate as above.
- **`ama-library-pr-propagate`** — *paused* (solo dev, direct push is standing default).
  Kept for a future team workflow: Phase A opens the library PR, Phase B propagates via
  per-consumer PRs. Branch names slash-free (`/` breaks the pipeline's NuGet suffix step).

Setup: `BITBUCKET_API_KEY` in `~/.secrets` (never in a chat prompt); unreachable API
with no auth error → check for a `Bash(curl *)` DENY rule (deny beats allow). Key unset →
the skills stop and wait, never skip the check.

**Nightly fleet health check** (`AMA-Harness-Fleet-Health-Check`): pipeline-YAML validity +
library build-counter reset risk + **scheduled-task liveness** (+ stale one-shot resume-task
sweep) + QA/Staging **ECS rollout stall** + Jira **tester bounce** (2026-10-05) + Production
**post-load** cache-update/DLQ monitor (`check-post-load.sh`, P21A, 2026-10-28), results in
`~/.claude/fleet-health/` (`results.log` =
deltas only; `latest-build-counter.txt` = full snapshot — `ama-library-version-sync` reads
it before computing a version). New `RISK`/`FAIL` lines ping `fleetHealth.reportTarget`
(deduped, never on `OK` churn); `hooks/fleet-health-check.sh` nudges in-session when
`run-history.log` goes >2 days stale (the task itself silently stopping). History + the
stream-read deadlock story: `PORTABILITY.md`.

`check-scheduled-tasks.ps1` is the liveness half: **registration is NOT liveness** — a task
can be `State: Ready` with a future `NextRunTime` and have never once run (confirmed
2026-09-01: two tasks dead for weeks on `LastTaskResult 0xFFFD0000`, incl. PROJ-15367's
own VPN-DNS probe). It flags, per `AMA-Harness-*` task: stored `Arguments` containing `\"`
(the bug — Windows needs a doubled `""`), a launch-failure result class (`0xFFF…`/`127`, the
payload never ran) vs the payload's own non-zero exit, staleness past a multiple of the
task's own cadence, and an action bypassing the hidden wrapper (closes
`scheduled-task-hidden-gate.sh`'s documented split-across-two-tool-calls limit). Its output
must stay diff-stable — no timestamps or raw ages, or results.log churns nightly. A forced/
manual run never updates `LastTaskResult`, so a runner stamps `notices/.task-ok-<TaskName>`
on success and a stamp newer than `LastRunTime` clears `script-exit` RISK (only
`team-meeting-notes-unattended-run.sh` stamps today).

### Scheduled tasks — the rules (detail + evidence: `PORTABILITY.md`)

- **Never a visible console**: every task's action routes through `scripts/run-hidden.vbs`
  (bash payloads) or `run-hidden-generic.vbs` (anything else) via `wscript.exe` — the ONLY
  confirmed zero-flash mechanism (`-WindowStyle Hidden` still flashes; console allocation
  precedes the host). Gate-enforced: `scheduled-task-hidden-gate.sh`. Paths inside the inner
  command line must be SPACE-FREE: embedded quotes do not survive the hop (2026-10-15).
- **In-session spawns are already hidden** (verified live 2026-09-15: hook bash, Bash-tool
  bash, Claude Code's `taskkill`, the PowerShell-tool pwsh all get a windowless console).
  Visible blank consoles appear only mid hook-timeout storm; the resident task
  `AMA-Harness-Console-Window-Watch` (`scripts/console-window-watch.ps1`) logs the owner
  chain to `harness-state/logs/console-windows.log`, relayed once by `on-prompt.sh`. Same
  watcher logs Defender for Endpoint investigations (SenseIR start/end + preceding processes)
  to `harness-state/logs/defender-activity.log` — the correlation evidence for IT.
  `dispatch.sh` samples the hooks' own `bash` start + a fresh-file scan probe once a minute to
  `proc-start-latency.log` (never from this hidden task: an EDR-shaped chain), the watcher logs
  Defender/total CPU, queue, memory to `engine-cpu.log`; `scripts/proc-start-latency.sh [date]
  --spells` joins them under a fixed rule; `spell-milestones.sh` reminds the owner session (probe, verdict).
- **Defender is recorded DURING a spell, unattended** (2026-10-15): `AMA-Harness-Defender-Hot-Record`
  is an on-demand ELEVATED task (user registers it once: `scripts/register-defender-hot-record.ps1`
  from an elevated PowerShell; a limited process may start it, nothing non-elevated can change it
  or what it runs — admin-only copies, admin-owned outputs, retires itself after 3 recordings).
  A bash-start sample ≥700 ms, or two of the last three ≥400 ms (`dispatch.sh` →
  `hooks/defender-hot-trigger.sh`), or MsMpEng >1 core for 2 min (the watcher) start
  `scripts/defender-hot-record.ps1`: 120 s recording + report + window-average CPU, one line in
  `%ProgramData%\AMA-Harness\defender-hot\defender-hot.log`, relayed once (`defender-hot-check.sh`);
  30-min cooldown, 2 starts a day. ANY Defender note any session gives -> one line in
  `harness-state/notices/defender-notes.md` (like harness-gaps.md); the owner session gets them relayed. Detail + threat model: `PORTABILITY.md`.
- **Orphans reaped every 15 min** — `AMA-Harness-Orphan-Conhost-Reap` (`scripts/reap-orphan-conhost.ps1`
  `-DryRun`): parent-gone conhost, dead-chain dev servers/Playwright Chromium, stuck hooks, extra pr-review-watch, reminder watchers only as a LAST resort (closed session AND nothing pending for it; unsure = keep + ask the user); a slow spell kicks it at once (`defender-hot-trigger.sh`); header has guards.
- **Three Task Scheduler defaults silently lose runs** — set on every new task:
  `DisallowStartIfOnBatteries=False`, `StopIfGoingOnBatteries=False`,
  `StartWhenAvailable=True`. `scripts/register-hidden-task.ps1` sets all three (and is the
  way to register dynamically from bash — no quote nesting; the old `/tr "bash \"...\""`
  shape collapsed quotes into an exit-127 no-log failure). `WakeToRun` is per-task:
  True on the two generative note tasks, False on detection-only monitors.
- **Catch-up fires race the network post-wake** — generative runs go through
  `lib-unattended-ready.sh`'s `wait_until_online` + `RestartCount=3`/`RestartInterval="PT15M"`
  (ISO-8601 string, not a TimeSpan).
- **`schtasks.exe` from git-bash needs DOUBLED slashes** (`schtasks.exe //query //tn ...`) —
  MSYS rewrites `/query` to a path and under `2>/dev/null` that reads as "no task found".
  Registration already routes through PowerShell; only query/delete are affected. Nudged
  live by `msys-command-traps-nudge.sh` (PROJ-15361).
- **A run refused by a spend/usage limit must say so**: every `claude -p` runner appends to
  `harness-state/notices/unattended-blocked.txt`; `on-prompt.sh` surfaces it once.
- **A run that will spend real tokens checks the weekly budget BEFORE starting** —
  `hooks/lib-claude-usage.sh` (`claude_usage_weekly` → `<pct>\t<reset-epoch>`, live from the
  OAuth usage endpoint, account-wide weekly figure; `capped` lists models at their own cap; unknown
  is never 0%). First consumer: the weekly harness-gaps review (`skills/ama-harness-gaps`,
  task `AMA-Harness-Gaps-Review`, daily 15:00 — the runner decides "reset is tomorrow" from
  `resets_at`, so no re-registration if the reset day drifts; account ≥90% → postponed a week; a capped model is dropped, opus runs).
  Plan-then-execute headless: leg 1 `--permission-mode plan` on a `--session-id`, leg 2
  `--resume`s it — Claude Code can't approve ExitPlanMode headless, and two legs on one
  session keep the plan's context without a second read. Digest relayed once by `on-prompt.sh`.
- **Withholding a tool to make a runner safe also withholds what it needs to do the job —
  split the run instead** (<harnessEpicKey>, 2026-08-31). `<amaSupportChannelName>-notices` was one
  `claude -p` leg denied `Bash` so it couldn't post/ticket/commit. But every investigation
  capability in this harness is a bash script, so the runner could not check anything, and
  its prompt hardcoded `Investigated: no, no tool to investigate from here` onto every item
  it reported — a constant dressed as a finding, on errors that were all checkable.
  Granting plain `Bash` back is not the fix (raw `Bash` can `curl` Slack and commit code —
  it reopens the whole hole). Two legs, each unable to do the other's job:
  - **leg A** — `Bash` scoped to ONE read-only script (`Bash(bash <abs path>:*)`) plus read
    tools. No Slack, no `Write`. Investigates, decides, drafts.
  - **leg B** — `slack_send_message` and nothing else. Relays leg A's text verbatim.
  Build the allowlist entry and the prompt's command text from the SAME shell variable so
  the prefix can't drift; a drift then fails safe (tool denied), not silently. The scoped
  form is confirmed working under `claude -p`. The read-only script is read-only **by
  contract** — adding a mutating subcommand hands an unattended run write access.
  Give any such runner a `*_DRAFT_ONLY=1` mode that runs leg A for real and stops before
  sending or recording: without it, testing a prompt change means a live send plus a seen
  ledger that then suppresses the next real report.
  Batch the scoped script's work into ONE call. A tool round-trip costs 2-3 min here, so
  the leg's budget is spent in round-trips, not in the checks — one call per item blew a
  900s ceiling, then a 1500s one twice more, on runs of only 3 items. Give the read-only
  script a `*-batch` subcommand that loops inside the file and tell the prompt to make
  exactly one call (<harnessEpicKey>, 2026-09-03). Raising the timeout only moves the wall.
- **Parse a headless leg's reply by a whole LINE, not a prefix — and scope any id
  extraction to the region after it** (<harnessEpicKey>, 2026-09-03). `case "$reply" in
  DONE*)` discarded a complete, correct run because the model opened with one line of
  prose before the sentinel; the wrapper reported it to the user as a monitor failure.
  Match a line that is exactly `DONE`, check `FAILED:` first so an explanation can't read
  as a success — and note the coupling: a prefix anchor is often also what keeps a
  `grep -oE` over the whole header safe. Loosen one, narrow the other in the same edit.
  Keep the reply itself even when the process exits non-zero (`|| raw=""` throws away a
  finished reply from a kill during `claude -p`'s teardown lingering); record the exit code
  and put it in the failure message rather than asserting "likely a timeout" for every
  empty reply. Fixtures: `skills/<amaSupportChannelName>-notices/scripts/support-notices-parse-test.sh`.
- **An unattended monitor pings a human only when there is an ISSUE — never an all-clear**
  (2026-09-08). `<amaSupportChannelName>-notices` sent a "nothing new since last check" DM every run;
  on post-processing days that is every 3h, so the user got eight of them a day and asked
  for it to stop. Reliable-looking noise is worse than silence — it teaches the reader to
  skim the channel, and the one message that matters goes with it. Three constraints when
  suppressing: key it on an EXPLICIT nothing-to-report signal from the run (`NONE`), never
  on "my parse found nothing" — a run that saw something it could not settle is NOT a
  clean window and must still reach a human, which is what the old "never silence a clean
  window" rule was protecting; do NOT relocate the noise into the digest, which
  `*-check.sh` injects into the next session's prompt and drains; and keep stamping
  `lastrun`/`lastday` on a suppressed run or it re-fires forever. Also make the runner's
  `*_DRAFT_ONLY` mode print the send/suppress verdict — otherwise it exits just short of
  the decision most likely to break on a prompt change.
- **Support monitor never fails to send** (user rule 2026-10-15): over-limit -> summarize -> deterministic truncate, real gate as oracle; detail `<amaSupportChannelName>-notices` Output.
- Diagnostic tell: `Last Run Time` older than today + `Next Run Time` tomorrow = today's
  slot was SKIPPED (defaults above), not failed — a failure leaves today's date + nonzero
  `Last Result`.
- `scripts/` is NOT symlinked into `~/.claude` — resolve the repo root via
  `git -C "$HOME/.claude/hooks" rev-parse --show-toplevel`; never a relative `..` through a
  junction (PowerShell resolves it against the junction's apparent location).

## Commit & ticket discipline

Applies everywhere, no trigger phrase needed — just ask Claude to commit/push/merge/raise a PR/transition a ticket.

- **No ticket named** → Claude stops *before* committing and asks (existing ticket, or create one) — never commits first and flags it after. A later push/cherry-pick carrying a no-ticket commit forward has the same obligation.
- Commit format: `PROJ-XXXXX: <short, imperative description>`.
- **New tickets:** assignee defaults to you; status stays at Jira's raw default **Open** (not To Do — that's a later, explicit promotion), or the real status if the work's already done. See `commit-ticket-jira/SKILL.md`'s "Creating a new ticket" section.
- **Actively working a ticket** → moved to "In Progress."
- **Transitions:** PR→develop = Review · push/merge→develop = QA · push→master = Test Complete · prod deploy = Done (unconditional, not gated on asking first — reversed 2026-08-11). Hotfix: own prod deploy → Done only; → Closed only when the NEXT release deploys to prod, not before.
- **Infra-only work (no code artifact) has its own row**: an SG rule, DNS record, or
  Octopus var going live in prod IS the deploy — no build, no Fix Version, never in the
  Test Complete sweep (nothing to tag). Verify live, then: nothing outstanding → Done
  direct; blocked on a third party confirming → Ready to Test + comment + an
  `ama-followups` ledger row, Done when they confirm or at the ladder's terminal stage
  regardless. Confirmed live 2026-08-26: PROJ-15312's whitelisting sat at In Progress
  after going live on two prod LBs until the user pointed it out — no code event, so
  nothing in the table above would ever have moved it. See `commit-ticket-jira/SKILL.md`'s
  transition table and `prod-infra-change-ticket-reminder.sh` below.
- Lives in a skill, not `CLAUDE.md` — costs nothing until it triggers.
The mechanics below are the terse map — full write-ups (incident history, predicates,
escape hatches) in `GATES-AND-HOOKS.md`'s "Commit & ticket hooks" section and each hook's
own header. Core rules first:

- **Harness work never gets its own ticket** (flip-flopped twice before settling): every
  harness change commits against **<harnessEpicKey>**, no transitions, no comments —
  `AGENTS.md` updates only (`README.md` only when human-visible). `harness-ticket-gate.sh`
  denies any new ticket Epic-Linked to it.
- **Recent regressions route to one generic ticket** (`atlassian.regressionsTicketKey`,
  <regressionsTicketKey>) — unless the causing ticket is identifiable: reopen it ONLY if unreleased;
  already on a released `release/*`/`hotfix/*` Fix Version → NEW linked Bug instead
  (`jira-fixversion-confirm-gate.sh` denies a new `release/*` tag onto such a ticket).
  Parked at Open, never transitions/tagged/commented. Unsure → ask.
- **Column/status queries default to `assignee = currentUser()`** — drop only when
  explicitly asked for everyone's.
- **Release tagging (Step 3a) is a Jira query, not a code search** (assignee in you/Reviewer One +
  status QA/Ready to Test/Test Complete). Any code sweep for a ticket ref must cover
  `AMA_APP` + `AMA_ETL` + `~/.claude`; some tickets have no code at all.
- **Fixes on a live `release/*`/`hotfix/*` branch reach develop through the merge, never a
  parallel cherry-pick** — gate-enforced (`cherry-pick-release-gate.sh`; header has the why).
- **Leave context for future sessions** per repo/topic — `ama-debugging-notes` /
  `ama-architecture-notes`, skills not `CLAUDE.md` (a skill only loads when relevant).

Mechanical enforcement map (gates deny, reminders nudge):

- `git-commit-ticket-gate.sh` — no-ticket commits blocked (gate table). Harness auto-commit
  (`on-stop.sh`) needs `set-session-ticket.sh` <harnessEpicKey> first and stages only this
  session's own Edit/Write paths.
- `jira-ticket-fields-gate.sh` / `jira-ticket-description-gate.sh` — assignee = your
  `jiraAccountId`; template headings present (`commit-ticket/TICKET-TEMPLATE.md`); create via
  `jira-create-issue.sh`. `jira-search-assignee-reminder.sh` — status/sprint JQL with no
  assignee clause.
- `readme-currency-gate.sh` — a `hooks/`/`skills/` edit nudges until AGENTS.md is touched or
  `readme-nudge-ack.sh <key> <sid>`; over `AGENTS_SIZE_LIMIT` (100KB) it says relocate, not
  append. `human-readme-edit-gate.sh`, `alwaysloaded-size-gate.sh` — same pressure on
  README.md and the other always-loaded surfaces (PROJ-15364). Headers have the detail.
- `config-key-parity-reminder.sh` — a `harness-config.json` key means THREE files (live,
  example, `harness-setup/SKILL.md`), checked both directions.
- `git-push-ticket-reminder.sh` — after a push to master/develop/release/hotfix, names the
  tickets **in the pushed commits** (`origin/<branch>@{1}..HEAD`) not already at/past target
  (live status via `lib-jira-status.sh`, fails open) and the branch-derived
  expected status; can't read Jira, check the real status yourself. Session-ticket file is
  a fallback, not a precondition. `set-session-ticket.sh` lists known chat filenames on a
  no-match (retry is one step; it never auto-picks).
- Ready to Test: regression check is Claude's in-session job, routed on BLAST RADIUS not
  UI-testability; separate brief comment only if the UI tester can run it from the UI.
  `regression-comment-brevity-gate.sh` asks over 800 chars/6 steps and DENIES over 1200/10
  (every real firing was 1.7x+ over and an ask never produced a trim), at BOTH the payload
  `Write` and the `jira-add-comment.sh` call. Triggers on the word-anchored NOUN
  `\bregressions?\b`, not any `regress*` substring — the substring caught the verb and denied
  an implementation-outcome comment about a deploy "regressing" a config fix
  (PROJ-15378). `ready-to-test-regression-reminder.sh` keeps the broad substring
  deliberately: there, over-matching costs a nudge, not a denial. **Exempt: ONE `^Regression:` line <=400 chars
  inside a body >2x its length** — that's the prescribed non-UI-testable form, and measuring
  the whole testing-steps comment against the budget denied exactly what the rule asks for
  (238eb2a; cases in `check-gates.sh`). Standalone regression comments still measured — the length rule is also stated in
  `ama-jira-api/SKILL.md`, the skill a commenting session actually loads;
  `ready-to-test-regression-reminder.sh` backstops (asks Jira the live status, never
  matches transition ids; a comment on an Open/Blocked/Done/Test Complete ticket is silent —
  no diff in play). `ticket-in-progress-reminder.sh` reads status the same way (silent when
  already In Progress or resolved); both via `lib-jira-status.sh`, fail open on no read.
  Rule: `memory/ready-to-test-regression-comment.md`.
- `ready-to-test-readiness-gate.sh` — DENIES a transition to Ready to Test unless the ticket
  has all four: template-heading description, testing steps, regression notes, where to
  test (QA/Staging/Prod). Destination via `/transitions` `.to.name` (ids per-ticket); **fails
  CLOSED** on no token/unreachable Jira, unlike every other Jira hook here. A fail-closed deny
  records the owed transition (`hstate tickets pending-transitions`, seam `RTT_PENDING_FILE`)
  — but NOT when the live `/transitions` list simply doesn't offer the id passed: caller
  error, no IOU. Key + id come from the invocation's own args;
  `pending-transition-check.sh` surfaces it via `on-prompt.sh`, the gate clears it on the next
  transition it can evaluate. Headers have the why.
- `test-complete-tester-gate.sh` — DENIES a transition to Test Complete when the changelog
  shows the TESTER moved the ticket out of Ready to Test (a bounce): Claude posts the finding
  and goes back to Ready to Test; the tester closes it (user rule 2026-10-05, PROJ-15417).
  Fails CLOSED like its sibling; seams `TCG_TRANSITIONS_FILE`/`TCG_CHANGELOG_FILE`.
- **Cross-session shared-clone guards** (one clone per repo; `git checkout` is global
  state) — all warn-only, never deny: `lib-session-liveness.sh` (transcript mtime),
  `lib-repo-claims.sh` (`.repo-claims` TSV — who was last seen where, NOT a lock),
  `cross-session-repo-claim.sh` (checkout over a live session's branch; committing onto
  another session's branch; two sessions on `hotfix/*` in the SAME repo = Octopus channel
  contention), `foreign-worktree-changes-gate.sh` (`git add -A` or ANY pathspec-less commit,
  bare/`-a`/`-am`, with another live claimant),
  `worktree-branch-conflict-gate.sh` (a branch checked out in one worktree can't be checked
  out/deleted in another — mid-cleanup `fatal:` reads as breakage), `worktree-junction-remove-gate.sh` (DENY),
  `file-claim-record.sh` + `lib-file-claims.sh` (`.file-claims` TSV — which session last
  edited which FILE; recorded on Edit|Write, read back by `cross-session-repo-claim.sh` as its
  second check, which warns at commit/`add -A` time only — see below). Worktrees are separate
  claims BY DESIGN. `scripts/fleet-repo-state.sh` = read-only sweep; a recorded claim is a
  snapshot, re-verify before acting. Known blind spot: `lib-harness-repos.sh path` always
  resolves the main clone, not a worktree.
- **Harness hook/settings work = worktree by default** (user 2026-10-22; replaces "one session at a
  time", PROJ-15368): `~/.claude/{hooks,skills,scripts}` symlink into the main clone = LIVE
  install. Multi-file/`hooks/` work -> `scripts/worktree-add.sh ama-claude-harness <slug> <branch>`,
  `check-gates.sh <tree>` there, `merge --ff-only`, remove tree same turn; small single-file edit
  stays direct. `file-claim-record.sh` nudges once/session/repo (`fclaims_nudge`); `FILE_CLAIMS=off`
  disables. Detail: `commit-ticket/SHARED-REPO.md`, `GATES-AND-HOOKS.md` § "Worktree by default".
- **One worktree root `~/Repos/AMA_APP/.worktrees/<repo>-<slug>`** via `scripts/worktree-add.sh`;
  sweep with `scripts/worktree-prune.sh` (Claude runs `--apply` UNPROMPTED -- standing rule, user
  2026-10-22: its checks ARE the approval; report removed/kept); weekly sprawl nudge `worktree-prune-check.sh`, `WORKTREE_PRUNE_NUDGE=off`.
- `ticket-worked-while-open-gate.sh` — post-commit, reads real HEAD: ticket still
  Open/To Do (should be In Progress), or release/hotfix branch without matching Fix
  Version. Harness epic + Regressions ticket exempt. Repo path in a shell variable →
  generic reminder, never a ticket read off the cwd (that named a worktree's wrong ticket). `prod-infra-change-ticket-reminder.sh`
  = its infra twin (mutating SG/DNS/LB `aws` calls); CloudFront/WAF/S3-bucket/log-delivery → "do it in yourproduct-backbone".
- `shared-input-contract-nudge.sh` — post-commit, warn-only, once/ticket: shared code gains text parsing/interface change → producer census + real-producer fixtures + per-consumer runs; postmortem in a commit body → record it (15416→15808). `rs-explain-shapes.sh` prints `FAMILY` lines (measure kinds never run).
- `persisted-data-rewrite-nudge.sh` — its DATA twin, post-commit, warn-only, once/ticket: a migration/backfill/datafix path or bulk-write op (IMigration, UpdateMany, `UPDATE … SET`) → whole-SEQUENCE test on real shapes + dry-run diff + fleet reader census + rollback snapshot (15274→15835: 1.0.10 undid 1.0.8, Spark reader broke six weeks). Protocol: `ama-debugging-notes` PERSISTED-DATA-REWRITES.md.
- `repo-followup-nudge.sh` — post-commit, warn-only, once/repo+branch: "next change to repo X also does Y". Row in `hstate tickets repo-followups` = `<slug>\t<ticket>\t<file>:<string>\t<todo>`; silent once the branch has the string, row self-clears once the default branch does. Defer a per-repo chore there, not in a memory note (PROJ-15915: SBOM step rides each master-only library's next change).
- `hotfix-version-claimed-gate.sh` — denies cutting `hotfix/X.Y.Z` whose Jira version is
  already described/tagged by someone else's ticket (create the NEXT version via
  `jira-version.sh create`, never ask the user). Fails open — a hotfix is urgent.
  `hotfix-stowaway-gate.sh` — denies committing onto a never-pushed hotfix branch carrying
  >2h-old foreign commits; ack file pinned to exact HEAD.
- `develop-backmerge-reminder.sh` — after a master push, `git cherry` (patch-id, immune to
  cherry-pick SHAs and release-branch fan-out — both obvious predicates were wrong) reports
  master patches missing from develop. Resolution precedent in the reason text (`.csproj`:
  latest by CodeArtifact publish DATE; hotfix code beats develop on BEHAVIOUR only — where
  master's shape is a branch artifact, ancestry-only merge + separate commit, see
  `ama-hotfix`). Dead-develop skip (tip >1yr old AND zero develop-only patches). Also checks
  every LIVE `origin/release/*` (tip <90d) the same way — the hotfix→release leg (2026-10-05).
- Hotfixing a published NuGet lib: consumers need own hotfix -- `ama-search-shared-version-sync`.
- `git-commit-scope-gate.sh` — denies `git add <files> && git commit` with no pathspec
  (commits the whole shared index). In the HARNESS REPO ONLY it denies any pathspec-less
  commit, `-a`/`-am` included — every session edits this clone (header has the why). Note the recommended `git commit -- <paths>` has
  `--only` semantics — it commits WORKING-TREE content, overriding staged state (see
  commit-ticket's synthetic-blob rule for shared files).
- `master-push-direct-gate.sh` — see gate table.
- `octopus-prod-deploy-ticket-sweep-reminder.sh` — after a verified prod deploy: Fix-Version
  ticket sweep to Done + prior hotfix tickets Done→Closed + mark the Jira version Released
  (`jira-version.sh release`) + `reminder.sh` re-checks at +4h/+24h (`error-signature-diff.sh
  production`) — all unconditional (reversed 2026-08-11); also relays owed
  follow-ups from `hstate tickets post-prod-deploy-actions` (one line each, delete when done).
  Sweep spans Open/To Do/In Progress too — REPORTED, never auto-swept.
  `octopus-staging-cache-update-reminder.sh` — QA/Staging sibling: nudges the cache-update
  when a `hotfix/*`, `release/*` (Staging) or `develop` (QA) push's diff touches report
  fields, SqlTemplates, Search.Shared builders, search's result post-processing (Services /
  Search.Domain — the cache stores the processed result) or fieldtablemapper (grep of the push
  reflog; paths in `lib-sql-emitting-paths.sh`; bare Octopus POST = decision-nudge; also names the
  `rs-explain-shapes.sh` sweep). Rule: `memory/ama-cache-update-after-deploy.md`.
  `octopus-prod-cache-update-reminder.sh` — the Production twin (decision-nudge after a
  prod deploy POST). `deploy-verify-slack-reminder.sh` — after a clean PRODUCTION
  `verify-qa-deploy.sh`/`verify-deployment-e2e.sh` run, nudges the #<amaSupportChannelName> summary
  post (QA/staging: none). All Octopus deploy detection is `lib-octopus-deploy-detect.sh`'s.
- `vpn-dns-outage-logger.sh` — wired under PostToolUse AND PostToolUseFailure (a failing
  command never reaches PostToolUse). A resolver-error failure in tool output → CLASSIFY first
  (`nslookup <host> 10.1.0.4`): resolves = slow resolver, log to the latency draft ticket, do
  NOT ping <name>; fails = IT-7829, invoke `ama-vpn-dns-outage` (claims via
  `vpn-dns-ping-claim.sh`). No-failing-command case is `vpn-dns-probe.ps1` + task
  `AMA-Harness-VPN-DNS-Probe`, which splits the same two faults, appends latency occurrences
  to the ticket itself, and watches PanGPS crashes. Detail: that hook's header and
  `GATES-AND-HOOKS.md` § "VPN/DNS outage logger".
- `backlog-page-reminder.sh` — new Open tickets go on the AMA Backlog page (`atlassian.backlogPageId`)
  at a slot Claude JUDGES by priority (`backlog-section.sh` → `BACKLOG_POSITION`); epic children stay
  off, their epic sits in the page's top Epics index (`backlog-epics-sync.sh`, 2026-10-22); also the "pick up tasks" source (+ the
  Deferred child page) — pickup reads go through `commit-ticket-jira/scripts/backlog-candidates.sh`,
  re-run at EVERY pick; default = TAKE the top Open row (or an Epic's `.1` child), claim it
  In Progress, no ask; finished one → pick the next (user rule 2026-09-21); `backlog-move-first.sh KEY [--section NAME] [--before KEY2]` re-tops an
  existing entry in its (or another) section, or slots it just above KEY2 for a priority-fit position (2026-10-22). A row another
  LIVE session has claimed prints `<-- CLAIMED by live session <sid>` — skip it; record your
  own pick with `set-session-ticket.sh` BEFORE investigating, or nothing warns the next
  session (PROJ-15318 picked twice, 2026-09-22). Mechanics:
  `commit-ticket-jira/BACKLOG-PAGE.md`, `memory/ama-backlog-page.md`.
- `backlog-qa-sweep.sh` — biweekly task `AMA-Harness-Backlog-QA-Sweep` adds the QA reporter's (`backlogQaSweep`, <uiTesterName>) new Open tickets to the backlog; PORTABILITY.md.
- `ama-feedback-notices` — daily 08:00 task `AMA-Harness-Feedback-Notices`: each new client-feedback form mail (`feedbackNotices.*`) → Jira Task under the feedback epic + Slack DM with the link; digest via `hooks/feedback-notices-check.sh`; PORTABILITY.md. Fixes ship as HOTFIXES unless regression risk is high; on QA/Staging, `feedback-prod-watch.sh` watches Production and wakes a session to draft the reply to Dan, DM the user and add a self-closing action item (`feedback-reply-item.sh`); "pick up the next feedback task" = `feedback-next.sh --claim <sid>` (never a claimed/started one; unchecked mail first). Skill "Fix route"/"Prod follow-up"/"Pick up".
- `backlog-stale-check.sh` — the other direction: nudges (every `backlogStale.checkDays`,
  default 7) to run `commit-ticket-jira/scripts/backlog-prune-resolved.sh`, which sweeps
  BOTH backlog pages for every STARTED or finished ticket — status name in `In Progress`,
  `Review`, `QA`, `Ready to Test`, `Test Complete`, `Done`, `Closed`, `Canceled` — and
  removes them. Standing user rule: nothing started or done on the backlog anywhere, so two
  sessions can't pick up the same ticket. `Blocked`/`on hold` deliberately stay (parked, not
  taken). Scheduled rather than transition-triggered — most closures happen in another
  session or the Jira UI, where no PostToolUse hook can see them.
- `stale-in-progress-check.sh` (on-prompt, daily) — nudges `commit-ticket-jira/scripts/stale-in-progress.sh`: own tickets idle 3+ days in In Progress/Review/QA → skip live-claimed, transition only what live state proves, list the rest for the user; correctly parked → `--ack KEY` (14 d; QA never On Hold, the cut tags by QA), other waiting → Blocked/On Hold; Epics excluded (user rule 2026-10-27: ten RDS tickets sat In Progress a week after the work). A deferred transition gets a `reminder.sh` naming the keys + target status.
- **Status NAMES, never `statusCategory`, decide backlog membership** (both this sweep and
  `jira-transition-issue.sh`'s per-transition add/prune). PROJ reports
  `statusCategory=new` for `QA`, `Test Complete`, `Review`, `Blocked` and `on hold` as well
  as `Open`/`To Do`, so category-based routing silently re-added finished work and swept
  almost nothing (2026-09-10).
- **The main backlog page does not grow.** Promoting a ticket up from the Deferred child
  page costs an existing main-page entry, one for one:
  `commit-ticket-jira/scripts/backlog-demote-ticket.sh KEY [deferred-section] [--dry-run]`
  moves an **Open** entry down (prune only handles `Done`), carrying its hand-written
  annotation verbatim so the note that justified the demotion isn't lost. It refuses a key
  listed twice on the page (`14729`, `14731` both are) and writes Deferred first, so a
  half-failure leaves the key on both pages rather than neither. Which entries are
  demotable, and why Jira `priority` is not a cross-page comparator:
  `commit-ticket-jira/BACKLOG-PAGE.md` "Rebalancing".
- Old/foreign tickets (>2y or someone else's report) get a premise check before work —
  verified gone → cancel automatically; couldn't verify → ask. See `commit-ticket`.
- `jira-fixversion-confirm-gate.sh` — a release/hotfix Fix Version must be confirmed
  (`confirm-jira-version.sh`) before tagging; Claude creates versions itself
  (`jira-version.sh create`) and then sets the version DESCRIPTION (surfaces as Octopus
  Releases' Description column).
- `lib-harness-repos.sh` resolves any repo by slug/folder via its own `git remote get-url`
  (folder names untrustworthy); roots in `~/.claude/.harness-local.json`. Its `index`
  emits a 4th fleet column — `ama-pr-review` loops it for app + ETL coverage.


## AMA debugging notes

Reoccurring-bug-class context gathered from past sessions, for `shared`, `search`, `cohortdata`, `fieldtablemapper`, `manage`, `exporterplus`, and fleet-wide conventions — read automatically when relevant, not injected into every session.

## AMA architecture notes

Companion skill to the above: how the AMA_APP fleet is actually structured (libraries, API services, auth, frontend, shared-infra, messaging, Selenium/cache-crawler internals, the dedicated testing repos, `search`'s SQL/LIMIT/stitch/GC-memory pipeline (`SEARCH-SQL-PIPELINE.md`) + CPRn-under-stitch arithmetic (`CPRN-STITCH-ARITHMETIC.md`; human doc `developer-docs/docs/servicer-stitch.md`)) from a full fleet survey — not bug patterns, structural facts. Same on-demand loading, same skill-not-`CLAUDE.md` reasoning. Both skills' descriptions cross-reference each other so finding one surfaces the other.

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
master+develop+any live `release/*`, deploy to Production, ticket to Done. No notes (not a
scheduled release). `admin`/`exporterplus` fixes go through `ama-ui-verify`'s
self-verify loop before pushing — see below.

## AMA UI verify skill

**Launch UI-project (`admin`/`exporterplus`) sessions with `claude --chrome`.** Playwright's
synthetic clicks hit real dead ends (PROJ-15260: a MatDialog overlay that never opened);
a session without `--chrome` has no fallback. `chrome-verify-nudge.sh` catches this
mid-session (fires on the verify-family skills AND on shell commands mentioning
`playwright`/`verify-ui.mjs`/`chromium.launch`): chrome-by-default ON → the browser tools ARE
in the deferred list, don't claim otherwise without a no-match `ToolSearch`, don't re-litigate
install-time prerequisites — Chrome not running → ask the user to open Chrome and retry, never
a silent headless fallback. OFF → suggests relaunching with `--chrome`.

**Fresh adopters/machines: run `/chrome` once, pick "Enabled by default"** — interactive
client-side command, sets `claudeInChromeDefaultEnabled: true` in `~/.claude.json`; nothing in
the installer can do it for you. Tradeoff: browser tools load every session (context cost) —
`/chrome` toggles back off. `statusline.sh`'s unattended auto-resume always passes
`--no-chrome` (a stalled browser prompt there would hang forever).

- Drives a real `admin`/`exporterplus` page headlessly (Playwright, six dedicated Cognito
  test users, no MFA). `claude --chrome` also runs unattended (already-logged-in browser
  state); Playwright's remaining edge: works with Chrome closed or without the opt-in.
- **`run-ui-verify.sh` screenshots on `networkidle`, BEFORE ag-grid rows load** — a grid URL
  yields a correct-looking shell with an empty grid at exit 0. Wait on a non-empty `.ag-cell`
  in a scratchpad script instead (skill's "Running the full flow" caveat).
  `scripts/drive-report-fromcache.mjs` checks `FromCache`; Curve Analyzer traps in
  `CURVE-ANALYZER-DRIVING.md`; MCF report fixture (cohort + report via API, soft deletes) in
  `MCF-REPORT-DRIVING.md` + `scripts/mcf-report-fixture.mjs`; aggregation-report traps (Criteria not grid filters, stale refs, silent save 500) in `AGGREGATIONS-DRIVING.md`.
- **`chrome-verify-compact-nudge.sh`** (`PostToolUse` on `tabs_close_mcp`): verify tab closed
  → its base64 screenshots are done being useful → one-shot `/compact` recommendation.
- **`chrome-activity-track.sh`** (`PostToolUse` on `mcp__claude-in-chrome__.*`): stamps the prompt
  number of every browser call; `on-prompt.sh` nudges "close tabs + `/compact`" after 2 prompts
  with no browser call — the forgotten-tab case the close-only trigger missed. Both share one
  per-session guard, re-armed by `chrome-compact-rearm.sh` (`SessionStart`, matcher `compact`)
  so a later verify loop in the same session nudges again; `/clear` needs nothing (new sid).
- **`dev-server-teardown-reminder.sh`** (`PostToolUse` on `Bash`): KILLS any session's
  Claude-started dev server (any free port at launch) idle 20 min — no command/browser call naming
  `:<port>`, no open connection, PID still the one recorded, no `scripts/devserver-hold.sh` hold (header has the guards).
  `on-session-end.sh` then kills any still-listening port THIS sid recorded — never another session's.
- **`dev-server-tab-close-teardown.sh`** (`PostToolUse` on `tabs_close_mcp`): verify tab closed →
  kills THIS sid's recorded server(s) now, says what it killed (shared predicate
  `lib-devserver-teardown.sh`). One-shot headless verify → `scripts/with-dev-server.sh` owns start/wait/kill.
- **Debugging**: screenshot/CSS/console the actual current UI as a FIRST step, not only to
  confirm a fix.
- **Standing rule, all UI work**: self-verify → fix/re-verify loop → user's own local
  sign-off → only then push/deploy.
- `tier1800` test users can't reach Dynamic Cohorts/Cohort Reports (plan limit) — use
  `tier3500`. Elevated view access to another's report doesn't add it to your own folder
  listing — only direct `/aggregations/view/<id>` reaches it (see the skill file). A bug
  only reproducing on a real person's own report: have them log into local dev, then
  `claude --continue --chrome` drives their authenticated tab.

## Comms & session hooks (detail: `GATES-AND-HOOKS.md`)

One line each; full write-ups moved to `GATES-AND-HOOKS.md` 2026-08-31:

- **`gmail-reply-thread-reminder.sh`** — after create/update_draft: verify the draft's
  `threadId` via `list_drafts`. `replyToMessageId` at an inbound message detaches to a new
  thread; `update_draft` DETACHES a reply draft outright — recreate, never update.
- **`gmail-draft-sig-gate.sh`** — denies the stale-sig misspelling `SturctureIt`; asks when
  `create_draft`/`reply` `htmlBody` lacks `class="gmail_signature"`. Verify STORED drafts on
  style markers, not the class (Gmail strips it on save); source sigs from SENT mail.
- **`audience-policy-gate.sh`** + **`audience-policy-check.sh`** — inject the `.audiences`
  depth policy (level = MIN over `to`, `avoid` = UNION, cc/bcc ignored); never deny/ask.
  Name matching treats `-` as a word character, not a boundary — a name inside a kebab
  slug (`clientcorp-cc-contactone`) names a thing, not an addressee (false positive, 2026-08-31).
  See `memory/audience-communication-levels.md`.
- **`slack-draft-existing-reminder.sh`** (`slack_send_message_draft`, warn-only) -- Slack drops a new draft silently when the chat already holds one and no tool can list drafts: injects "also hand over the paste text", naming any unsent draft the follow-up ledger records for that chat. Rule: `memory/slack-message-edit-request.md`.
- **`client-mail-cc-gate.sh`** — asks on any mail with an `@client.example.com` recipient missing the
  standing cc; own `<secondaryEmail>` alone is exempt; empty-recipient `reply`/
  `forward` payloads ask unconditionally. See `memory/clientcorp-cc-contactone.md`.
- **`self-checkable-ask-reminder.sh`** (`Stop`) — flags a reply that handed the user a
  question the harness can answer itself (ask-phrase + readable-system keyword in one
  paragraph) into `harness-gaps.md`. See `memory/self-check-before-asking.md`.
- **Reminders are DURABLE** (2026-10-13): `scripts/reminder.sh add <sid> "<local time>" <task>` —
  fires in whichever open session claims it first (atomic, never twice), waits if none open
  (unclaimed 15 min -> one Slack DM, still queued: `slack-unclaimed`, 2026-10-29);
  `reminder-check.sh` (on-prompt) + per-session `reminder-watch.sh` (bg, idle sessions; runs a copy so reminder.sh stays editable; ONE per session -- a re-arm over a live watcher exits at once, 2026-10-22).
  `cron-oneshot-durable-gate.sh` denies one-shot `CronCreate`. Design: `reminder.sh` header.
  Ack a finished one: `reminder.sh done <id>` (unacked + claimer cut off by the usage limit = re-queued).
- **Monitors are DURABLE the same way** (user rule 2026-10-22): a long-lived poller is registered via
  `scripts/durable-monitor.sh add <name> [--until D] <script> [args]` (a poller taking args registers
  ITSELF with `--pid $$`, e.g. `octopus-task-watch.sh`; exit 0 = finished -> deregistered, anything
  else = restarted), never a bare nohup/Start-Process
  (`durable-monitor-nudge.sh`). `hooks/pr-watch-check.sh` is the ONE restart pass for every watcher
  and monitor -- on every prompt AND from task `AMA-Harness-Watchers-Ensure` (logon, resume, every
  30 min; `scripts/register-watchers-ensure-task.ps1`), so they come back after a crash with no
  session open. Liveness = `hooks/lib-proc-cmdline.sh` `proc_alive_running` (pid alive AND its
  command line names the script) -- never `kill -0` alone, pids restart after a reboot.
- **Usage-limit cut-off = audit + resume, nothing left unfinished** (user rule 2026-10-21):
  `scripts/limit-resume.py` keys on the transcript's `"apiError":"usage_limit_reached"` record.
  `limit-resume-check.sh` (on-prompt) injects its checklist on the first turn after a hit (CLI
  auto-continue, watcher wake, task notification or user prompt) -- request, last words, unread
  tool result, open bg work, claimed reminders; `limit-resume-stop-check.sh` (Stop) sends a reply
  without a `Limit-resume audit` section back once. Idle open session: its watcher (now asked for
  in every session) exits `LIMIT-RESET-WAKE` at reset+5 min. Sweep (any session, 10 min): stalled
  past reset+30 min -> surfaced once, closed ones queued, unacked reminders re-queued.
  `resume-rate-limited.sh` drains the queue ONE AT A TIME, skips open windows and sessions not really cut off (`limit-resume.py cutoff`: the queue fills at 99%, before any hit), never by age, and
  resumes READ-ONLY (`--permission-mode plan`): audit + proposed actions saved to `limits/reports/`, re-shown
  in every session once a day until `limit-resume.py clear <sid>` after the user decides; nothing runs without the user (2026-10-21); `scripts/limit-resume-review.py <sid>`
  lists what a resumed run did. Trigger: `statusline.sh` writes
  `harness-state/limits/window-hit` at >= 99% (zero-fork gate). CLI auto-continue is NOT reliable.
- **Deploy outcomes come back on their own** (user rule 2026-10-14): `scripts/octopus-task-watch.sh
  <ServerTasks-N> <sid>` (bg Bash; `--next <project> <Environments-N>` when no task exists yet)
  reports SUCCESS / FAILED + error lines + cause. `octopus-deploy-watch-reminder.sh` (Post,
  dispatched) nudges after a deploy POST; `octopus-approval-watch-check.sh` (Stop) blocks a reply
  that hands the user an Octopus approve/deploy link with no watcher OR no fresh SAFE/REVIEW stamp
  from `scripts/octopus-approval-preflight.sh` (stale plan, other session, network change, tags removed -- `mnd-*` = BLOCKED);
  `octopus-approve-preflight-gate.sh` (Pre) denies Claude's own approve on the same stamps; Claude approves
  Backbone Dev/QA/Staging only, via `scripts/octopus-approve.sh` (detail: `ama-terraform-backbone`). FAILED → debug at once.
  `terraform-plan-approval-review-check.sh` (Stop) blocks any plan-approval recommendation not
  preceded by `ama-terraform-backbone/scripts/plan-review.sh` on that task + the skill's checklist.
- **`learned-lesson-check.sh`** (`Stop`, blocks once) — a reply paragraph that reports a
  learned lesson ("I was wrong", "the real cause", "the fix was") about a harness-known system
  (terraform/octopus/aws/jira/docker/msys/hook…) with no `~/.claude`/harness Edit/Write and no
  `harness-gaps.md` line in the turn is sent back to record it first (CLAUDE.md Gotcha/Lesson
  Placement decides where). User rule 2026-10-14. Resumed turn is silent.
- **`deferred-window-reminder-check.sh`** (`Stop`, blocks once) — deferral past Mon–Fri 9–5 ET
  with no reminder set → sent back to `reminder.sh add` (next weekday 08:00 local). Rule: `memory/business-hours-deferral-reminder.md`.
- **`subagent-model-tiering-gate.sh`** (`Agent`, warn-only) — reminds to give the prompt a
  word cap (unbudgeted agents return 3-5k-token reports), per `resource-efficiency`. Model
  tiering left this hook 2026-09-14: `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` in the env block does
  it mechanically. Honors `SUBAGENT_MODEL_TIERING=off`.
- **`skill-model-tiering-gate.sh`** (`Edit`/`Write`, warn-only) — a `skills/*/SKILL.md`
  write with no `model:` frontmatter; restates `resource-efficiency`'s whole-turn rule.
- **`check-gates-unfiltered-gate.sh`** (`Bash`/`PowerShell`) — denies an unfiltered
  `check-gates.sh` run (~10 min) and a bare `mutate-gates.sh` (~35 min); escape hatch
  `CHECK_GATES_FULL=1`. Matches an invocation, never a mention, so reads of the file pass.
- **`check-gates-currency-gate.sh`** (`Edit`/`Write`) — edited a file `check-gates.sh`
  asserts about? Names the filtered command, and arms the run-owed reminder as a LEDGER of
  the gate sections your edits touched (`G:<gate>` / `N:`), so `run-check-gates-full.sh`
  sweeps only those (~1 min) instead of a full pass, and refuses entirely while other
  sessions are live. Details in those two files' headers.
  Honors `SKILL_MODEL_TIERING=off` (silences the WARNING only — an env var cannot disable a
  `model:` already in frontmatter).
- **`statusline.sh` context gauge** — `ctx:NN%` segment + one-shot 60%/80%
  `/compact`-or-`/clear` notice via `.ctx-notices-<sid>`, relayed by `on-prompt.sh`. See
  `context-hygiene`. (The 5h/weekly `USAGE THRESHOLD CROSSED` relay and its
  `usage-monitor` skill were removed 2026-09-08 — the bar already shows both windows.)
- **`security-cost-confluence-reminder.sh`** (Post `Bash`, dispatched) — security/cost-looking Jira transition or comment → add a dated row to the security or cost Confluence record (`ama-confluence-api` "Security / cost records").
- **`jit-pointer-nudge.sh`** (`Edit`/`Write`, warn-only, once/session/key) — editing
  `hooks/*.sh` / `memory/*.md` / scheduled-task infra injects a one-line pointer to
  GATES-AND-HOOKS.md / `harness-memory` / PORTABILITY.md. `on-prompt.sh` twin: first
  prompt injects a repo-keyed reference-doc pointer set (PROJ-15362).

## IT ticket drafts

Say **"draft an IT ticket"** (or ask for anything only IT can action) -> `it-ticket` skill.
Output is always a Markdown FILE in `IT Tickets/` for the user to submit himself, never
CLI-only and never sent by Claude. Paste-ready (one line per paragraph, no `#`/indent/tables
-- `it-ticket-paste-format-check.sh`). Body stays terse -- every required fact, minimum words
(audience is IT/security, `memory/audience-communication-levels.md`). Verify infra claims
live before writing; if the fault is ours to fix, say so instead of drafting.

## AMA report debug skill

Say a ticket describes a report that fails to load/hangs/errors — triggers this
sequence: offer the user a chance to self-serve first (load it, hand over a Graylog
link); if declined, Claude loads it via `ama-ui-verify` and checks Graylog
(`ama-graylog-search`); for a custom band (dynamic column), check Postgres
(`ama-postgres-access`) — its data lives in the **export API's** DB, not
`querybuilder`'s own, even though querybuilder serves it (see `ama-architecture-notes`).

## AMA user-data copy skill

"copy user data" / "migrate a user's reports to a new account" (PROJ-15474) ->
`ama-user-data-copy`: inventory, dry-run, copy (SQL clone + real cohort API; received shares opt-in)
OR `move.sh` owner switch in place (no regeneration; source left empty), manifest, verify x3 (DB,
as-user API, browser), rollback, `rehearse.sh`; prod rehearsal onto a test user first.

## AMA env sleep (QA/Staging cost saving)

`ama-env-sleep` (PROJ-15653): AWS Scheduler+Lambda scale QA+Staging ECS to 0 nightly 22:00 SAST; task `AMA-Harness-Env-Wake` wakes them weekdays 07:00/logon/resume-from-sleep (`wake-first.txt` deps first; `ensure-awake.sh <env>` wakes+waits before ANY test/sweep -- `run-pipeline.sh` and the release preflight call it); `hooks/env-sleep-check.sh` (on-prompt) says wake unasked off-hours; a woken env stays up for the day, the nightly shutdown sleeps it — never nudge about, or do, an early scale-down (user rule 2026-10-21).

## AMA Terraform on yourproduct-backbone

`ama-terraform-backbone` (PROJ-15658/15791, 2026-10-14): worker parity (TF 0.13.3, shared
hosted workers, apply re-plans with `-auto-approve`), the read-only plan recipe
(`scripts/tf-plan-readonly.sh` renders Octopus `#{tokens}` from `variables/preview`), the
Windows/TF-0.13 traps (`TF_DATA_DIR=C:/tfd/<label>`, no plugin cache, `git archive` not `cp`),
`-/aws` legacy provider → `state replace-provider` not `state rm`, the fleet drift classes
(`mnd-*` tags via provider `default_tags`, stale RDS engine vars, gp2→gp3, `new_*` RDS rename
never applied to Production → `state mv`), `_build/build.sh`'s substring component match, and the
fleet sweep tooling (`scripts/sweep/README.md`: every state indexed, AWS inventory joined, 113 plans in a container).

## AMA Release Notes skill

Say **"create AMA release notes"** to run the full pipeline: next release number → Done/Test Complete tickets → mark Resolution Done (Fix Version is already tagged at cut time by `ama-cut-release-branch`, not here) → Confluence page → PDF → email draft.

- Jira version create/release is scripted (`jira-version.sh`, see the skill) — nothing here
  is a manual Jira-UI step except a version's start date. **Generalisable lesson: "cannot be
  automated" usually meant "no MCP tool for it"** — re-test any remaining "manual step"
  against direct REST before repeating the claim.
- Config (recipients, greeting names, board, space, footer, approvers) is
  `harness-config.json` `atlassian.*`/`releaseNotes.*` — edit, then
  `octopus-config-sync.sh push`. **Greeting names come from `releaseNotes.greetingNames`,
  never inferred from the email address** — a missing recipient is an ask-the-user.
- Distributing to Claude.ai: package a `.skill` zip and upload manually; rebuild on any
  `SKILL.md` change (goes stale silently).

## Graylog search

Ask to search/check Graylog logs (e.g. "search graylog for errors in qa in the last day excluding exportproducer/ping") — Claude turns it into a Lucene query and runs it against `http://your-graylog-host:9000`.

- **One-time setup:** `echo 'export GRAYLOG_PAT="your_actual_graylog_pat_here"' >> ~/.secrets && source ~/.secrets` — a Personal Access Token, not your account password.
- Uses the legacy `/api/search/universal/relative` endpoint — confirmed the newer Graylog "Search Scripting API" 404s on this instance's version (4.2.6).
- **Falls back to CloudWatch automatically** when Graylog has nothing — infra-level failures (container crash, ECS task issues, Lambda cold-start) never reach Graylog at all. No setup needed, uses your existing AWS CLI credentials.
- **Recognizes known error patterns** instead of re-diagnosing them every time — a stale-cache condition that just needs an admin-panel refresh, and a historic library bug that only matters if the affected repo hasn't picked up the fix yet.
- **Cache-update failures get traced end-to-end**: Graylog → the AWS Step Function that ran it → CloudWatch logs for whichever Lambda actually failed (the failing one is rarely named after the step that failed — Claude resolves the real target instead of guessing).
- **`scripts/classify-stitch-sql.sh`** reads recent search-api `ExecuteAsync::SQL` lines and prints, per query, whether the servicer stitch was applied (CTE present, servicer column swapped in the SELECT, WHERE on `.servicer`, per-period table joined, GROUP BY) — the top-row signal is `whereOnServicer`, not `swapToPeriodServicer` (header has the legend). Pairs with the replay recipe in `ama-architecture-notes`' `SEARCH-SQL-PIPELINE.md`; built for the PROJ-15351/15352 audit.
- **Can WRITE pipeline (suppression) rules, not just search** — only via
  `graylog-rule-write.sh` + `graylog-pipeline-attach-rule.sh` (creating a rule does NOT
  attach it); raw curl writes denied by `graylog-write-gate.sh`. Full mechanics in the
  skill's `PIPELINE-RULES.md`. **Every new/changed suppression rule gets one Slack message
  to `#<amaSupportChannelName>`** — a suppression is invisible otherwise.

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

Postgres in any AMA env via ECS-resolved conn string + throwaway `docker run postgres:16`.
Engine down/hung → `docker-ensure.sh` starts/restarts Docker Desktop itself (user rule 2026-09-26) → `docker-wedge-diagnose.sh` verdicts NOT_RUNNING / RESOURCE_SAVER_SLEEP / WEDGED_OTHER.

**No Redshift-heavy work Mon–Fri 9am–5pm ET** (user instruction 2026-08-31) — QA,
Staging and Production share ONE Redshift cluster, so a load test there hits production
users. Heavy = executing report-scale queries or sustained load (automated API suites,
load tests, calibration matrices like PROJ-15359's). Light metadata reads and
`EXPLAIN` (planner-only, never executes) are fine any time. Urgent prod bug needing ONE
report-scale run on Staging → ask; the user's explicit yes covers that run only, separate from
any deploy override (2026-10-14). No gate — a gate on
`rs-query.sh` can't tell a light SELECT from a heavy one; the api-testing pipeline, the
other named example, is already covered by `prod-api-test-window-gate.sh`. Resolve ET via
`hooks/lib-et-now.sh` (`et_now`/`et_window_state`, python zoneinfo) — never `TZ=... date`,
which git-bash ignores, and never UTC arithmetic against a remembered start hour (9am ET is
13:00 UTC only under EDT). Same 9am–5pm ET Mon–Fri window gates Production deploys
(`prod-deploy-business-hours-gate.sh`) and applies to any CLAIM about the window, including
a conversational one.

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
- Trigger / poll / junit-summarise a pipeline, or prove a branch tip built green: `ama-bitbucket-api/scripts/run-pipeline.sh` and `pipeline-status.sh [--sha]` — never a hand-rolled curl. Which branch/commit built package `X.Y.Z`? Its tail IS the build number → `pipeline-build.sh <repo> <n>`, never publish date. Exception: a CUSTOM pipeline taking `variables` — `run-pipeline.sh` can't pass them, see `ama-bitbucket-api`. Push landed, no pipeline → `trigger-branch-pipeline.sh`.
- **Pipeline-variable APIs return unsecured values in PLAINTEXT** (AWS keys, Octopus API key here) — select `.key`, never `.value`; a dump reaches the chat log, which is a git repo. `ama-bitbucket-api`.
- A step that failed inside a CI helper script (`package.sh`, `create-release.sh`, …) is fixable: those live in the `pipelines` repo, `COPY`'d into the ECR image. Manual, un-propagated rollout — see `ama-bitbucket-api`.

### Opening a pull request — two standing rules (user instruction 2026-09-09)

- **The description must briefly say WHY** (two or three sentences). `create-bitbucket-pr.sh` refuses under 60 chars; **`pr-description-why-gate.sh`** denies a raw `curl -X POST …/pullrequests` with an inline `.description` missing/short (`-d @file` passes — fail open). Length is all a hook can measure.
- **Reviewers get a Slack DM with the link, immediately.** **`pr-created-reviewer-dm-reminder.sh`** fires on a real PR creation (response carries a PR URL) and hands you who + link; you send it with `slack_send_message` (no bot token exists), short, per the audience policy and `memory/slack-messages-terse.md`, with the AI-disclosure line.
- **Every PR Claude opens merges itself on approval** (user instruction 2026-10-14) **and the woken session then CONTINUES the work the PR blocked (deploy, non-prod approve, verify, next item) unasked** -- stop only where a gate needs the user (user rule 2026-10-27; state the post-merge next steps before ending the PR turn). `create-bitbucket-pr.sh` itself starts the watcher with `--sid` (a wrapper script skipped the hook, PR #34); the same hook starts `ama-bitbucket-api/scripts/pr-merge-watch.sh <slug> <id>` detached; it merges once a reviewer approves (nobody requesting changes) AND no build is still running on the source tip (commit statuses; waits up to 2h per tip, 2026-10-21), then wakes the origin session via a durable reminder with the follow-ups -- work left after the merge? the creating session records it (`--post-merge`, `ama-bitbucket-api`): reminder then says don't move the ticket + names the session to reopen (user rule 2026-10-28). `hooks/pr-watch-check.sh` (on-prompt) restarts a dead watcher from its `harness-state/prs/pending/` marker. `--once` = merge-now-if-approved, for PRs opened by hand (exit 5 = build running). Never poll a PR yourself. Review reminders: `pr-review-watch.sh --still-needed <slug> <id>` runs first AND again right before the verdict DM / any later mention (exit 1 = approved by ANYONE/merged/declined -> ack, say nothing; PR #35 merged mid-review, 2026-10-28); each sweep drops pending ones for such PRs (2026-10-22).
- **Claude never APPROVES a PR, may merge** (policy 2026-10-16; `bitbucket-pr-approve-gate.sh`). PRs naming the user as reviewer are picked up by `pr-review-watch.sh` (singleton, started by `pr-watch-check.sh`) → reminder → `ama-pr-review`: comment + advise, user approves.
- `create-bitbucket-pr.sh` (in `ama-library-version-sync/scripts`, but general) now also **sets reviewers** — until 2026-09-09 it set none, so every PR it opened was assigned to nobody. Defaults to `.bitbucket.defaultPrReviewers`; extra UUIDs can be passed as trailing arguments.
- **Gotcha, if you touch either:** `.bitbucket.defaultPrReviewers` stores full names ("Reviewer One") while `.audiences.people` stores the short name the audience policy speaks in ("Reviewer One"). An exact-name join across the two resolves nobody and silently reports "no Slack id" with the id sitting in the same file. Match on the first name, case-insensitively.

## Jira/Confluence REST API (direct, via API key) — Atlassian MCP RETIRED 2026-08-31

`ama-jira-api` + `ama-confluence-api` call Atlassian REST directly
(`-u "<email>:$ATLASSIAN_API_TOKEN"`, Basic auth — token is Jira/Confluence-scoped, NOT
interchangeable with `BITBUCKET_API_KEY`). The Atlassian MCP server is fully retired (user
instruction 2026-08-31, token cost: MCP results inject verbatim with untrimmable nested
overhead, once 42% of a usage window; the scripts jq-trim to just the needed value). Never
call an `mcp__claude_ai_Atlassian__*` tool even if the connector still appears (deny-listed
in `settings.template.json` since PROJ-15361 — was allow-listed prose-only for a day);
remind the user to disconnect it in claude.ai settings if it does. The last MCP-only holdouts are now
scripted: Confluence page read/create/update (`confluence-get/create/update-page.sh`,
atlas_doc_format or storage, verified live incl. a create+update+archive round-trip),
worklogs (`jira-add-worklog.sh`, untested-but-pattern-proven), and transition field
metadata (`jira-transition-fields.sh`, verified live).
**API version matters per script**: `jira-create-issue.sh`/`jira-edit-description.sh` are
v2 (wiki markup preserved); `jira-edit-issue.sh`/`jira-append-description.sh` are v3 (ADF —
rewriting a markup description with them renders literal `h2.` text). Writes go through a
per-call payload file (`JIRA_PAYLOAD_FILE=<path>`, written via the Write tool, deleted on
success only — **required since 2026-09-07**, the scripts exit 1 without it; the shared
default kept getting clobbered while it was merely advised) — the mechanism
also feeds the three ticket-write gates structured JSON. Full detail in the two skills.

## Verify before reporting a bug

`verify-before-reporting` — read the real post-change code (not a subagent's diff-only summary) and the schema/contract it writes into before telling anyone a bug exists. Applies to any report, not just PR review: a raw-diff read can overstate a finding (e.g. "always wrong" when it's actually "wrong only if two inputs diverge").

## Reducing permission prompts

- **`/fewer-permission-prompts`** scans transcripts and adds missing `settings.json` allow rules.
- **The sandbox (`sandbox-allow.sh`)** auto-allows calls whose cwd/target is under a trusted
  root. `~/.claude` + the scratchpad are always trusted; everything else is per-machine
  config — `~/.claude/.harness-local.json`'s `sandboxTrustedRoots` (see its `.example`, or
  `/harness-setup` step 5a). Debug logging off by default (`SANDBOX_ALLOW_DEBUG=1` to enable).
- A separate hardcoded "sensitive file" guard for `~/.claude/` re-prompts Bash/PowerShell
  regardless ("always allow" only persists for Write/Edit) — product limitation.
- **`plan-exit-auto-approve.sh`** (personal `settings.json` only, not the template) auto-allows
  `ExitPlanMode` so plan approval never blocks on a keypress.
- **On any denial, keep talking** — state what was denied and what you're retrying; never go
  silent waiting for the user.
- **Auto-mode classifier denials are non-deterministic** (clustered on parallel batches;
  identical call passed 40min later, 2026-08-28; also hit claude-in-chrome javascript_tool,
  2026-08-31) — retry is the fix, not a harness change.
- **A background Bash task marked "killed" may have completed anyway** — only the tracked
  wrapper bash.exe died; the payload can survive as a detached orphan (2026-08-31: two full
  suites finished after their wrappers were "killed"). Check its log file before re-running —
  and two check-gates/mutate-gates suites never run at once: `scripts/lib-suite-lock.sh` makes
  the second WAIT (up to 20 min) -- they interfered (437/2 vs 439/0) and three overlapping runs
  stalled every other session's hooks (2026-10-22).
  **And no terminal notification ever fires for it**, so "killed" is not a reason to stop
  watching: an `oct-wait.sh` deploy waiter declared dead wrote its Success line ~1h later, 7s
  after the deploy finished, and the session only learned from the user (3b471998, 2026-09-09).
  Re-check the underlying thing — the deploy, job or queue — not the task's reported status.
  **Now suppressed by `CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1`** in `settings.template.json`'s
  `env` block — the sole guard on the only code path that emits that reason (2.1.266). Undocumented,
  so if background shells start dying again check the flag still exists in the bundle. Applies from
  session start, and `Monitor`-kind tasks were never reaped anyway — prefer one for a very long wait.
  If pressure bites anyway, host-level relief is **recommended for approval, never applied** —
  `memory/machine-changes-recommend-not-apply.md`.
- **.NET build servers die after every foreground `dotnet build|test|publish`** —
  `dotnet-build-server-shutdown.sh` (Post, dispatched; header has guards + log) plus
  `MSBUILDDISABLENODEREUSE=1` in the env block: 18 idle MSBuild nodes held 2 GB while the box paged (2026-09-27).
  **Two builds never overlap while RAM is tight** — `dotnet-build-memory-wait.sh` (Pre, dispatched,
  warn-only) waits only while free RAM < 6 GB AND another build client runs
  (`lib-dotnet-inflight.sh`, process truth, no claim ledger); max wait pairs with block timeout — header.

### The `PreToolUse` gate hooks at a glance

Count is derived, never hand-maintained:
`jq -r '.hooks.PreToolUse[].hooks[].command' settings.template.json | grep -oE '[a-z0-9-]+-gate\.sh' | sort -u`.
These gates + the sandbox are what keep routine work off manual approval prompts — each
enforces one already-confirmed failure mode at the moment of the action. **This table is the
map**: full rationale, incident history, edge cases and match rules live in each hook file's
own header comment (and `GATES-AND-HOOKS.md` archives the pre-split detailed table).

**Suspected gate miss in auto mode** (a call ran that a gate should deny): before anything
else, save the exact `tool_input.command` from the transcript and replay it against the gate
offline — every 2026-08 "miss" that got re-tested either passed offline too (payload shape
differed from the fixture) or was observer error. No confirmed miss has survived a replay.
`settings.template.json` is the wiring source of truth.

| Hook | Fires on | Blocks |
|---|---|---|
| `bare-cd-gate.sh` | `Bash`/`PowerShell` | Leading unparenthesized `cd`; bare `cd` back to session home exempt. |
| `parallel-fanout-gate.sh` | `Bash`/`PowerShell` | 2nd+ shell call in a parallel batch. |
| `grep-memory-gate.sh` | `Bash`/`PowerShell` | Recursive grep without `-I`. |
| `deploy-verify-confirm-gate.sh` | `Bash`/`PowerShell` | Deploy-verify scripts before an explicit user yes this session; one-shot (spent post-run; e2e spends it only on reaching Stage 3, so a Stage-1 stop keeps it for the rerun), and an approval is scoped to `<repo>:<version>` so a CHANGED artifact asks again. |
| `ecs-running-image-gate.sh` | `Bash`/`PowerShell` | Warn-only: `describe-services` mined to answer "is my build live" — read the RUNNING task. |
| `aggregation-secret-gate.sh` | `Bash`/`PowerShell` | `get-aggregation-connection.sh` with output unconsumed. |
| `unanalyzable-script-gate.sh` | `Bash`/`PowerShell` | Inline loop / multi-line control flow / open quote / unresolvable env var → `bash <file>`. |
| `short-path-gate.sh` | `Bash`/`PowerShell` | An 8.3 short-path segment. |
| `background-pipe-gate.sh` | `Bash` | Backgrounded call piping into a buffering filter. |
| `substitution-stdin-hang-gate.sh` | `Bash` | A filter whose only file operands come from an unquoted `$(…)`. |
| `inplace-edit-gate.sh` | `Bash`/`PowerShell` | Anything that would UNLINK a `~/.claude` symlink (`sed -i` incl. `s|…|` delimiters, `mv` over, `rm`). |
| `shell-write-bypass-gate.sh` | `Bash`/`PowerShell` | Shell write to a path an `Edit`/`Write` deny-gate covers, or `sed -i`/`perl -i` on a `~/.claude` link. Hatch `HARNESS_BULK_EDIT=1` (logged). |
| `publish-scrub-gate.sh` | `Bash`/`PowerShell` | Harness commit whose content (staged, or named by a pathspec/`-a` commit) fails the public-mirror scrub. Fails CLOSED on an unresolvable harness root. |
| `skill-model-tiering-gate.sh` | `Edit`/`Write` | Warn-only: `SKILL.md` without `model:`. `SKILL_MODEL_TIERING=off`. |
| `git-commit-ticket-gate.sh` | `Bash`/`PowerShell` | Non-harness commit without `PROJ-XXXXX:`. |
| `master-push-direct-gate.sh` | `Bash`/`PowerShell` | Non-merge commits pushed to `master` off no `hotfix/*`/`release/*` ref. |
| `fleet-owner-push-gate.sh` | `Bash`/`PowerShell` | Push to master/main/develop/release/hotfix in a fleet whose owner (`.fleetOwners`, `lib-fleet-owner.sh`) isn't the user -- PR route; `pr-merge-watch.sh` merges only on the owner's approval. Rule `memory/fleet-owner-approval.md`. Hatch `AMA_FLEET_OWNER_APPROVED=1` after owner OK. |
| `cherry-pick-release-gate.sh` | `Bash`/`PowerShell` | `git cherry-pick` onto develop of a commit that lives on a `release/*`/`hotfix/*` branch. Hatch `AMA_ALLOW_CHERRY_PICK=1`. |
| `octopus-lambda-delete-gate.sh` | `Bash`/`PowerShell` | Octopus deployments POST with no `delete-function` recorded this session. Hatch `OCTOPUS_TARGET_NOT_LAMBDA=1`. |
| `bitbucket-pr-approve-gate.sh` | `Bash`/`PowerShell` | Any Bitbucket PR approve (`pullrequests/<id>/approve` POST, incl. via a script) -- policy: AI may merge, never approve. No hatch; unapprove/merge pass. |
| `octopus-task-cancel-gate.sh` | `Bash`/`PowerShell` | Cancelling an Octopus task this session's own deploy POST didn't create (`--record` ledger); names live sessions mentioning it. Hatch `AMA_CANCEL_FOREIGN_TASK=1` after user/owner yes. |
| `skill-bloat-gate.sh` | `Edit`/`Write` | Narrative-shaped `SKILL.md` paragraph. |
| `standup-empty-section-gate.sh` | `Edit`/`Write` | Standup file with an empty section or a bare movement bullet. |
| `running-script-edit-gate.sh` | `Edit`/`Write`, `Bash`/`PowerShell` | Editing a script a live process is running. |
| `symlink-write-gate.sh` | `Edit`/`Write` | Never denies: REWRITES a `~/.claude` link path to its real harness path (`updatedInput`). |
| `native-memory-gate.sh` | `Edit`/`Write` | Writing Claude Code's native memory store. |
| `claude-dir-clutter-gate.sh` | `Edit`/`Write`, `Bash`/`PowerShell` | A NEW top-level `~/.claude` entry — see "Where harness state lives". |
| `github-remote-gate.sh` | `Bash`/`PowerShell` | This repo gaining a github.com remote, or a direct push there. |
| `msys-command-traps-nudge.sh` | `Bash` | Warn-only: jq `--slurpfile`; jq→jq without `tr -d '\r'`; `schtasks` single-slash flags. |
| `transcript-scan-bound-nudge.sh` | `Edit`/`Write` | Warn-only: a hook edit scanning the transcript with no bound. |
| `redshift-window-context.sh` | `Bash`/`PowerShell` | Context-only: `rs-query.sh` inside Mon–Fri 9am–5pm ET. |
| `trace-secret-gate.sh` | `Bash`/`PowerShell` | `bash -x`/`set -x`/`Set-PSDebug -Trace` on a harness script (prints API-key headers into the transcript). Hatch `AMA_ALLOW_TRACE=1`. |
| `dotfile-secret-print-gate.sh` | `Read`/`Grep`, `Bash`/`PowerShell` | Printing `~/.secrets` (the harness's keys, sourced by `~/.bashrc`) or a profile still holding a key export; names-only `grep -o '^export [A-Za-z_]*='`, `-c`, sourcing, `sed -i`, `>>` pass. No hatch. |
| `output-secret-leak-gate.sh` | `Bash`/`PowerShell` (Post) | Warn-loud: AWS key id / Octopus API key / cleartext `"Password":` / credential-named env var (`*_pw=`, `*TOKEN=`) in tool OUTPUT. Fires ONCE per shape per session (repeating it cannot clear the condition), and ignores placeholder/regex values like `"<cleartext>"` — it used to block on its own header. |
| `advisor-standard-process-gate.sh` | `advisor` | Denies `advisor()` during a standard process (deploy/hotfix/release-cut/octopus/release-notes/standup/team-notes/commit-ticket) or a backlog pick. No hatch. Fails open with no readable transcript. |
| `backlog-pick-no-ask-gate.sh` | `AskUserQuestion` | Denies a which-ticket question (>=2 PROJ keys, or "which task/ticket/item" wording) while the turn's prompt is a backlog pick and no claim (`set-session-ticket.sh`/`jira-transition-issue.sh`) has landed since the last `backlog-candidates.sh` run — the pages are priority-ordered, take the first row, skip an unactionable one in-reply. Mid-work judgment questions pass. No hatch. Phrase list: `lib-backlog-pick.sh` (shared with the advisor gate). |
| `harness-config-unsynced-stop-gate.sh` | `Stop` | Own `harness-config.json` edit still differs from the last-synced Octopus copy. Hatch in header. |
| `confluence-media-gate.sh` | Confluence page writes | Storage-format body to a page in `.atlassian.pagesWithNestedMedia` — write ADF. |
| `slack-brevity-gate.sh` | Slack send/draft/schedule | >150 prose words, none on a DM to the user themselves (standup 320, support triage 400, team-meeting 480; counting in `lib-slack-words.sh`); 3+ addresses not individually backticked; send/schedule to the user's own DM without `<@user.slackUserId>` (runners prefix `hr_self_mention`). |
| ~~`slack-signature-gate.sh`~~ | — | Retired 2026-08-25; never type the Slack signature manually. |
| `audience-policy-gate.sh` | Gmail + Slack sends | Context-only: injects the resolved `.audiences` policy. |
| `hotfix-number-comms-gate.sh` | Gmail + Slack sends | A hotfix NUMBER in comms — say "a hotfix". |
| `jira-ticket-fields-gate.sh` | `createJiraIssue` | Assignee ≠ your cached `jiraAccountId`. |
| `harness-ticket-gate.sh` | `createJiraIssue` | New ticket Epic-Linked to <harnessEpicKey>; security-looking ticket not under `atlassian.securityEpicKey`. |
| `jira-fixversion-confirm-gate.sh` | `createJiraIssue`/`editJiraIssue` | Tagging an unconfirmed `release/*`/`hotfix/*` Fix Version. |
| `prod-api-test-window-gate.sh` | `Bash`/`PowerShell` | PRODUCTION api-testing trigger Mon–Fri 9am–5pm ET. Fails CLOSED. Hatch `AMA_ALLOW_PROD_API_TESTS=1`. |
| `prod-deploy-business-hours-gate.sh` | `Bash`/`PowerShell` | PRODUCTION Octopus deploy in that window, or with no literal environment id. Fails CLOSED. Hatch `AMA_ALLOW_PROD_DEPLOY=1`. |
| `prod-deploy-preflight-gate.sh` | `Bash`/`PowerShell` | PRODUCTION Octopus deploy with no `release-preflight.sh` run <12h (Staging API tests + error sweep, incl. the catch-all-tagged Staging errors by source — the untagged sweep alone is blind there, 2026-10-14; + infra Octopus projects whose commits name a ticket in this Fix Version but are not live in Production, `infra-paired-check.sh`, 2026-10-15; + EXPLAIN of every SQL shape the Staging build emitted, `sql-shape-preflight.sh`, + new error signatures, `error-signature-diff.sh`, 2026-10-15), or one with findings. Hatch `AMA_PREFLIGHT_ACK=1` after the user's explicit yes. |
| `graylog-write-gate.sh` | `Bash`/`PowerShell` | Hand-rolled Graylog pipeline writes; any pipeline write from a headless run. |
| `mongo-write-gate.sh` | `Bash`/`PowerShell` | Mongo writes. Hatches `AMA_ALLOW_PROD_MONGO_WRITE=1` / `AMA_ALLOW_MONGO_WRITE=1` (non-prod). Matching is fork-free bash `=~` — it was silently not enforced live until de-forked (cause unestablished), see GATES-AND-HOOKS.md's fork budget. |
| `psql-write-gate.sh` | `Bash`/`PowerShell` | Postgres writes; denies what it cannot classify. Matches `pg-connect.sh` by name as well as `psql` (2026-09-18 — the skill's own entry point names no psql, so every write through the documented path, production included, passed silently), and reads the `-f` SQL file. Matching is fork-free bash `=~` — ten grep forks measured 12-22s against its own 15s timeout and it was silently not enforced live until de-forked (GATES-AND-HOOKS.md, fork budget). Hatches `AMA_ALLOW_PROD_PG_WRITE=1` / `AMA_ALLOW_PG_WRITE=1` (non-prod). |

Shared libs, not gates — one copy of each predicate, headers carry the incidents:
`lib-command-text.sh` (`command_scan_region` — heredoc body counts only when the same command
runs the file it wrote; `command_text_stripped`), `lib-git-target.sh` (`git -C`/`cd`/cwd
resolution, `~`/`$HOME`/`$VAR` handling), `lib-octopus-deploy-detect.sh`,
`lib-scan-script-refs.sh`, `lib-et-now.sh`. A gate needing one of these sources it; a private
copy is how the 2026-09-15 bypasses happened.

### Where harness state lives (PROJ-15342)

Two rules, both mechanical (`claude-dir-clutter-gate.sh` enforces the first):

- **Durable hook/session state** → `~/.claude/harness-state/<category>/<name>` via
  `hstate <category> <name>` (source `hooks/lib-claude-paths.sh`) — creates the parent dir,
  absorbs a leftover pre-migration top-level file on first touch. Categories: `notices`,
  `standup`, `sessions`, `tickets`, `harness`, `settings-backups`, `logs`.
- **Disposable notes/diagnostics** → `~/.claude/scratch/<purpose>/<name>` via `hscratch`.

**Test seams — a test must never touch live state.** `CLAUDE_STATE_DIR` redirects every
`hstate` path and `HR_CONFIG_FILE` (`lib-harness-repos.sh`) redirects every config read; set
both at a `mktemp -d` and the scripts under test follow, because they resolve through the same
libs. The absorb branch is skipped whenever `CLAUDE_STATE_DIR` is overridden — unguarded it
`mv`'d real `~/.claude` leftovers into the throwaway dir. This is what both notices selftests
use instead of backing up and truncating live ledgers: that pattern lost real data whenever the
Bash tool's 2m timeout SIGKILLed a run mid-restore (2026-08-28).

Both gitignored. Never a bare top-level `~/.claude/.foo` again — that flat dir is a git repo
pushed to a personal remote, and ~90 strays accumulated there before this policy. Hooks that
render every keystroke/prompt (`statusline.sh`, `on-prompt.sh`) inline the guard instead of
sourcing the lib (fork cost — see their comments); `lib-file-claims.sh` does the same for
`sessions/.file-claims` (it is read on the Edit path, `hstate` forks `dirname` and the
substitution around it forks again, and there is no pre-migration file to absorb). All three
still honour `CLAUDE_STATE_DIR`, so the test seam works unchanged — that is the part an inline
path must not drop.

### Writing, wiring, and testing hooks — see `GATES-AND-HOOKS.md`

The short version; the file has the full detail and every trap's evidence:

- **A hook wired or rewired mid-session does NOT fire until restart.** Test by piping a
  `jq -n` payload into it (or a `check-gates.sh` case), never by attempting the action.
- A `PreToolUse` hook can inject guidance without deciding: `additionalContext`, no
  `permissionDecision` (an explicit `allow` can override a sibling gate). Plain stdout is
  NOT shown to the model for `PreToolUse`.
- **Touched a gate? Run it FILTERED: `bash scripts/check-gates.sh --gate <gate.sh>`** — now
  gate-enforced by `check-gates-unfiltered-gate.sh`, not just advised.
  (~60-80s, of which ~30s is suite-level assertions that always run). A full pass is ~10 min
  / ~615 asserts / 72 gates and can be killed by a low-memory supervisor — background it and
  keep it for a final check. Progress prints per gate to stderr; a filter matching no gate
  exits non-zero rather than reporting green. Then `mutate-gates.sh <gate.sh>` targeted, to
  prove the new case can fail — ONE gate name self-filters both of its suite passes (~70s;
  it used to run two full passes and get supervisor-killed). Neutered-gate failures should
  equal that gate's `deny`/`block` case count; a mismatch means a case isn't exercising it. Assert reasons, not just decisions; always add a
  false-positive case; fixtures live inside the suite script. Every gate run is also timed
  against its `dispatch-*.manifest` timeout — reaching it is a FAIL (would fail open live).
- **Hook fork budget**: process creation ~60ms here — needle-test the raw payload before any
  `jq` fork, one `jq` per payload, strip `\r` after `read`. Full conventions in the file.
- **Every hook runs through `hooks/hook-run.sh`** (isolates stdio so an orphaned fork can't
  freeze the session — the 50-min "Percolating…" incident). Wire new hooks the same way,
  always with a `timeout`.
- **Both `Bash|PowerShell` blocks (Pre AND Post) are DISPATCHED** (`hooks/dispatch.sh` +
  `dispatch-pre-bash.manifest` / `dispatch-post-bash.manifest`), not wired gate-by-gate: a
  new gate for either block goes in its manifest (`gen-dispatch-manifest.sh --event`), with
  the usual `case "$payload"` needle opener. `check-dispatch-equivalence.sh [--post]` proves
  no gate silently stopped firing; `dispatch-needle-currency-gate.sh` demands it on any such
  edit. Every gate run leaves a line in `harness-state/logs/gate-invocations.log`. Detail:
  GATES-AND-HOOKS.md "Hook fork budget". Needles never see `transcript_path`/`scratchpad_dir`/
  `description` (2026-10-22: those made bare-cd + short-path fork every call). Needles also see a referenced scratch script's text,
  so a script-scanning gate spawns only on its real keyword (2026-10-14). A gate its timeout
  kills (`timeout -k 2`: TERM, then KILL) fails OPEN (`rc 124` in the log) -- except one whose header says
  `# dispatch: fail-closed-on-timeout` (the three production gates), which is DENIED (2026-10-15).
- **Write the needle in the canonical shape or the gate forks on every shell call** —
  `case "$payload"` block, `*) exit 0` catch-all. GATES-AND-HOOKS.md "Hook fork budget" has
  the full rules and the 2026-09-22 frozen-cache incident.
- `hooks/redact-secret.sh <literal|-> [replacement]` — on-demand secret scrub across
  transcripts/chat logs/hook logs. Hygiene, not containment: committed or live values need
  rotation.

## Portability — general harness vs AMA_APP-specific content

Full detail: **`PORTABILITY.md`** (repo root, split out 2026-08-31) — read it when
installing for a new org, syncing config to/from Octopus, working an unattended Ping
scheduled task, or triaging one of the notice monitors (<one entry per line; this element only declares the type>/AWS/support). Summary:

- Org identifiers live in `~/.claude/harness-config.json` (untracked). Cross-machine
  source of truth = the org's **"Claude Harness" Octopus library variable set**, one
  variable per scalar (`HarnessConfig:<colon-separated path>`). Sync:
  `scripts/octopus-config-sync.sh fetch|push|verify` — setup-time only, never at runtime;
  the per-person `user` block is never pushed/overwritten.
- **`harness-config.example.json` IS the schema** — push refuses a live key with no
  example counterpart; every example array carries one element so its type is knowable.
- Push-after-edit is mechanically enforced (`octopus-config-push-reminder.sh` +
  `on-prompt.sh` mtime check + `harness-config-unsynced-stop-gate.sh`, which BLOCKS the
  turn ending on an own unpushed edit). The reminder carries the unpushed diff vs a last-synced
  copy (`harness-state/harness/.harness-config-synced-copy.json`); a change this session
  didn't make is reviewed with the user before any push, never pushed blind. The installer
  refuses to replace a real config that differs from the (routinely stale) repo copy —
  reconcile via `octopus-config-sync.sh` first. Most keys read with fallback defaults;
  `hr_config_required` keys (which org's infra a call hits) fail loud instead.
- **AMA_APP-specific — opt-in, skip if your fleet differs**: every `ama-*` skill, plus
  `company-slides` and `it-ticket` (brand/org-specific). **General-purpose**: `commit-ticket` (+ its forked `commit-ticket-jira`),
  `resource-efficiency`, `chat-log-reads`, `caveman`, `karpathy-guidelines`,
  `rename-topic`, `relocate-session`, `open-chat-file`, `process-prompt-queue`,
  `write-a-skill`, `verify`, `grill-me`, `context-hygiene`, `grep-usage`,
  `bash-command-style`/`-correctness` (split by SYMPTOM: prompts/denials vs
  ran-but-output-wrong), `slack-search`, `harness-setup`,
  `gmail-drafting`.
- `skills/ama/` is a browsing-only symlink index — skill discovery never reads it. New
  `ama-*` skill → create the real dir AND its symlink there (nudged by
  `ama-skill-symlink-nudge.sh` — first run found 12 missing, PROJ-15361).
- Per-skill mechanism detail (notice-monitor ledgers/cadence, unattended-runner traps,
  Zoom summary reads, config-sync internals) lives in `PORTABILITY.md` and each skill's
  own `SKILL.md` — not here.


## Public GitHub mirror

This repo has a **public**, sanitized mirror at `https://github.com/rsryanstephen/AMA-Harness`.
The mirror is a fresh single-commit snapshot, never this repo's history.

- **Republishing is automatic** — `hooks/on-stop.sh`'s `publish_public_mirror` fires
  right after `auto_commit_push_harness` confirms a real harness commit landed on
  Bitbucket, sha-marker gated (`~/.claude/harness-state/harness/.harness-last-published-sha`) so a quiet Stop
  is a no-op, never blocks Stop on a slow/offline GitHub (`timeout 90`, failure logged
  to `harness-gaps.md` + `~/.claude/harness-state/harness/.harness-publish-public.log`, not raised as an
  error). Deferred until this is the only live session (hourly max) or a day passes —
  each publish rewrites ~550 files Defender scans (header).
- **A forbidden token is caught pre-commit, not after** — `hooks/publish-scrub-gate.sh`
  denies a `git commit` in this repo whose staged content would abort the gate. It calls
  `scripts/publish-public.sh --check-paths <staged paths>`: same combined map, same scrub,
  same gate, but against the WORKING-TREE copies, because the normal path exports
  `git archive HEAD` and pre-commit that would inspect the previous commit. Added after
  the gate aborted every publish for a day and the only trace was a `harness-gaps.md`
  line. ~2s per harness commit. Also runs `bash -n` on scrubbed scripts: quote org
  literals in `case` patterns (`*'x'*`) — a `<...>` placeholder is shell syntax unquoted.
  And blocks a config person's name in any spelling, plus any email address not in
  `scripts/public-email-allow.txt` — checked as WRITTEN too, so `first.last@<company>` can't pass
  as `@example.com` (steps 2b/4c, 2026-10-28) — fix with a placeholder or a whole-address map.
- **`--dry-run` inspects `git archive HEAD`, not the working tree** — a fix you have not
  committed yet still shows as failing there; use `--check-paths <files>` to verify an
  uncommitted fix. `--check-paths` also mirrors the export's `company-slides` →
  `company-slides` rename (2026-08-28) — without it every path under that skill false-failed
  the path gate.
- **A token glued to a letter defeats the map.** The scrub uses letter/digit lookarounds, so
  a fixture ticket key written straight after a `printf` tab escape (backslash, `t`, then
  `PROJ-11111` with no separator) never matched `PROJ → PROJ` and aborted every
  publish from ~2026-08-21 to 08-28. Put such a token in a variable (`TK=PROJ` …
  `${TK}-11111`) so it stands alone in source. A comment that merely spells out the glued
  form hits too — describe it, don't quote it.
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
  (gate-enforced: `github-remote-gate.sh`, PROJ-15361)
  — the remote added earlier for the private mirror was removed deliberately; the
  publish script pushes by URL only. If sensitive history ever lands on the GitHub
  repo again, delete and recreate the repo there — a force-push is NOT enough (GitHub
  keeps force-pushed-away commits fetchable by SHA).

---

*All of this lives in plain markdown files — nothing depends on remote or cloud state.*
