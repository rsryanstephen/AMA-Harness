---
name: bash-command-style
description: How to shape a Bash/PowerShell command so it doesn't trigger an avoidable permission prompt, and what to do when a call gets denied anyway. Use before running a command against a path outside cwd (cd, git, ls, grep), before firing several shell calls in parallel, and immediately after any tool-call denial.
---

# Bash command style

## Rule 0: beyond a simple pipeline → Write a script file, run `bash <file>`

Inline compound scripts are how permission prompts happen. Claude Code static-analyses every
Bash command; can't parse it → won't delegate to the auto-approval classifier → manual
prompt, every run, subagents included. `bash <file>` is analyzable **by construction**, no
matter what's inside the file.

So: one command or one pipeline inline. Anything more — loop, multi-line string, embedded
awk/perl program, a dozen chained statements — goes in a file (`Write` to the session
scratchpad or the repo's `scratch/`), then `bash <that path>`.

Free wins: real line numbers on error, re-runnable, editable without retyping.

Gates below (`unanalyzable-script-gate.sh` etc) are a BACKSTOP for forgetting this, not the
primary mechanism. Three shapes have slipped past them already — each was analyzable-by-
construction the moment it moved into a file.

## Default: pass the path as an argument, no `cd`

`ls -la <path>/`, `git -C <path> ...`, `jq ... <path>`, `bash <path>/script.sh`. No
`cd`, no compound (`&&`/`;`/`|` around a `cd`) — this is the form that never prompts
(`cd ~/X && ls -la | grep foo` gets denied; `ls -la ~/X/ | grep foo` runs clean).

`cd` genuinely unavoidable → `(cd X && cmd)` subshell, never a bare `cd` (see
[[grep-usage]] for the separate binary-file/`-I` grep gotcha, don't restate it here).
**Gate-enforced**: `bare-cd-gate.sh` denies a leading, unparenthesized `cd` outright.

## Don't fan out several prompt-triggering calls in parallel

One denial rejects the whole batch (7 calls fired at once → all 7 denied together,
including one already inside the allowed directory). Prove
a form works on a single call first, then parallelize. **Gate-enforced**:
`parallel-fanout-gate.sh` denies the 2nd+ Bash/PowerShell call in a genuine batch.

## Testing a hook with synthetic JSON

Piping hand-written JSON into a hook to test it — hand-escaped backslashes (e.g. a
Windows path) reliably collapse to invalid JSON going through the tool-call transport
layer, so `jq` fails silently and the test looks like a false
negative in the hook itself. Build test JSON with `jq -n --arg` instead of hand-writing
escaped strings — sidesteps the problem entirely.

## On a permission denial: never go silent

State what was denied and what you're trying instead, then retry an alternative form.
Keep going a couple of attempts — if it isn't converging, stop and say plainly what's
blocked and what you need. A denial rejects that *form*, not the task; "STOP and wait"
in a deny message means stop that action, not stop talking.

## Native exes mangle `/`-leading args on git-bash (`MSYS_NO_PATHCONV=1`)

git-bash silently rewrites any argument starting with `/` into a Windows path before a
native exe (`aws.exe`, `jq.exe` — not MSYS programs) sees it → baffling errors on values
that obviously match (e.g. AWS "must satisfy regular expression pattern"). Fix:
`MSYS_NO_PATHCONV=1` on the call. Pipelines: each command gets its own env — prefixing
only the first command doesn't protect a downstream `jq --arg`; `export` once at the top
of the script that needs it. Never export session-wide: a native exe elsewhere (e.g.
`jq.exe` reading a config file path) gets the same mangled `/c/...` path and fails to
open it. AWS-specific call sites: see [[ama-cloudwatch-search]].

## Large one-off scripts: Write tool, not a bash heredoc

A large heredoc gets silently mangled/truncated mid-file. Any substantial one-off script
(Playwright, Python, whatever) → Write tool, then execute the file.

## Inline shapes that force a prompt

Gate-enforced, `unanalyzable-script-gate.sh`. Claude Code can't statically analyze these →
refuses classifier delegation → manual prompt every run, subagents included.

1. **Any loop** (`for`/`while`/`until` + `done`), **even a one-liner** → Write it to a file,
   run `bash <file>`. `for k in A B C; do ...; done` prompts exactly like a 20-line loop
   ("Contains simple_expansion"). No `xargs` alternative — it's deny-listed here.
   Single-line `if [ -f x ]; then ...; fi` is fine and stays allowed.
2. **`if`/`case` spanning lines**, or a multi-line embedded awk/perl program → same fix.
3. **A quoted string left open across a newline** — i.e. `git commit -m "multi-line msg"` →
   use `git commit -F - <<'EOF'`. Heredoc bodies are exempt (only the region before the
   first `<<` is measured).
4. **An ALL-CAPS env var the analyser can't resolve** (`$ATLASSIAN_API_TOKEN`,
   `$OCTOPUS_API_KEY`, `$GRAYLOG_PAT`) → "Contains simple_expansion". `$HOME` and friends are
   fine; it's the unknown ones. Put the command in a script file — the analyser never reads
   the file's contents, and the value stays out of the command line and the transcript, which
   matters for a token. Usually the real fix: call the harness script WITHOUT passing the
   secret, since those scripts read their own credentials. Detection skips single-quoted
   regions and non-caps refs (`$p`, `$hi` in a jq/awk program aren't shell vars — that was 37
   of 40 false hits before narrowing).

Each rule was added after a shape slipped past the previous ones and cost a real prompt. The
set is incomplete by construction — Claude Code's parser isn't documented from outside.

### New prompt shape appears → triage in one turn, don't re-research

1. **Get the exact command**, don't retype from the screenshot. Main-thread calls:
   `~/.claude/projects/<slug>/<session-id>.jsonl`. Subagent calls (most of them):
   `<session-id>/subagents/agent-*.jsonl`. Filter `tool_use` + `name=="Bash"`, match on a
   distinctive substring, `@base64` out, `tr -d '\r\n' | base64 -d` in (jq's base64 output
   carries CRLF and breaks the decode otherwise).
2. **Replay it through the hook** — `jq -Rs '{session_id:"s",cwd:"x",tool_input:{command:.}}'
   < cmd.txt | bash hooks/unanalyzable-script-gate.sh`. Confirms whether it's an uncovered
   shape or a stale session, before theorising.
3. **Read the prompt's own reason string** — it names the trigger (`Contains
   simple_expansion`, `Tilde in assignment value`, `Contains shell syntax (string)`). That's
   better evidence than any guess about size or complexity.
4. **Cost the candidate rule against real corpora, both directions** — replay whole
   transcripts, yours AND the flagged session's, before shipping. Size-based rules were tried
   and rejected this way: legitimate calls reach 11 lines / 1034 chars against flagged ones
   at 10-16 / 1074-1463.
5. **Check the prefilter** — the cheap pre-jq `case` guard shipped requiring a newline, so a
   one-line loop exited before any rule ran. A new rule that widens what counts must widen
   that guard too.
6. **Live-probe it**, not just synthetics: run a real command of that shape and confirm a
   hook deny comes back instead of a prompt.

Quote-blind by design (precedent: `bare-cd-gate.sh` reverted quote-aware matching). So
multi-line script text passed as DATA also denies — hook-test fixtures go in files, or
`jq --rawfile`. No bypass marker exists: skipping the gate wouldn't skip Claude Code's own
refusal, so the command would prompt anyway.

## 8.3 short paths (`RYAN~1.STE`) → long form

Gate-enforced: `short-path-gate.sh`. Tilde reads as unresolved expansion → same manual
prompt. Both forms name one directory, so rewrite freely — prefer `$HOME/...`.

Root cause was `TEMP`/`TMP` = `C:\Users\RYAN~1.STE\AppData\Local\Temp`, so every injected
scratchpad path carried it. Fixed 2026-08-17:

```
setx TEMP "C:\Users\<longname>\AppData\Local\Temp"
setx TMP  "C:\Users\<longname>\AppData\Local\Temp"
```

New processes only — a running session keeps the old value until restart. Not a fresh
finding: `sandbox-allow.sh` already noted a PreToolUse `allow` can't suppress Claude Code's
own path guard. A `deny` fires first though, which is why the gate works.

## PowerShell here-strings (`@'...'@`) are a parse no-op in the Bash tool

Wrong shell → `@` lands in the string. A commit message passed that way committed
with subject `@ PROJ-...`; gate saw the ticket ref, let it through. Bash tool
multi-line string → heredoc (`-F - <<'EOF'`). Each tool takes its own syntax.

## `python`, not `python3`

`python3` on this machine resolves to the Microsoft Store stub and errors out.

## Non-ASCII in a bash argument silently corrupts on this machine

Console codepage is 437, not UTF-8. An em dash, curly quote, or emoji typed as a
literal character inside a bash command argument gets mangled before the command
even runs (`—` → replacement char, `🤖` → `??`). `jq -n '"—"'` does not save you; the
corruption happens in the argument, upstream of jq.

Working recipe: write the text with the **Write tool** (not shell redirection), then
build JSON from that file with `jq -Rs` — see [[ama-bitbucket-api]]'s PR-comment
section for the exact form. Applies to any outbound non-ASCII text, not just PR
comments — commit messages, Jira/Confluence bodies, Slack messages.

## `sed -i` DESTROYS a symlink — never use it on a `~/.claude/` path

Every file under `~/.claude/` is a SymbolicLink into `ama-claude-harness` (dirs are
Junctions). `sed -i` writes a temp file and **renames it over the target**, and rename
replaces the link with a standalone file. The edit then lands outside the repo, git sees
nothing, and the two copies silently diverge.

Confirmed live 2026-08-17 on `harness-gaps.md`: `sed -i` "succeeded", the file held the
new text, `git status` was clean, and `Get-Item` showed `LinkType` empty. Same rename
hazard `on-prompt.sh` already comments on for its own state writes.

Use the **Edit tool**, or write through the resolved repo path. Suspect it whenever an
edit appears to work but `git status` shows the file clean:

```bash
# is it still a link?
powershell -c "(Get-Item '$HOME/.claude/<file>' -Force).LinkType"
# repair: content to repo first, then re-link
powershell -c "Copy-Item <local> <repo> -Force; Remove-Item <local> -Force;
  New-Item -ItemType SymbolicLink -Path <local> -Target <repo>"
```

## Negative results — measured, don't re-derive

All of these ran CLEAN (no prompt), so they are not triggers and `TEMP`/`TMP`/`TMPDIR`
belong on `unanalyzable-script-gate.sh`'s safe list: `ls "$TEMP"`; `T="${TEMP:-/tmp}"`;
`echo x > "$TEMP/f"`; `T="${TEMP:-/tmp}/f"; echo x > "$T"`; `for_test=1` (a var whose name
starts with a keyword); `jq -n --rawfile b "$T" '$b|length'`;
`echo x > /tmp/f 2>/dev/null || echo x > "$TEMP/f"`. A write target reached through an env
var is fine — the refusal text's "relative write targets" wording is not the trigger.

**Statement count does not separate** analyzable from not, so don't add a count threshold:
flagged commands measured 14 / 6 / 5 top-level statements against ordinary traffic at
median 3, p90 9, max 17 (172 + 215 + 168 commands). Same trap as line and char counts.

**Not every shape is gateable.** A 14-statement jq capability probe (2026-08-18) prompted
while every one of its statements ran clean in isolation — aggregate unanalyzability with no
isolatable discriminator after 7 probes. Rule 0 is the answer there: a script file removes
it, a gate rule cannot without denying ordinary work.
