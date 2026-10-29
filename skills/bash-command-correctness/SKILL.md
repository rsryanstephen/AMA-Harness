---
name: bash-command-correctness
description: A Bash/PowerShell command RAN but produced wrong, empty, truncated or corrupted output — or silently edited the wrong file. Use when output is empty or garbled, a heredoc or here-string didn't land as written, a backgrounded job's log is empty, a path handed to a native exe (aws.exe, jq.exe) or to node was mangled or ENOENT'd, non-ASCII became ? or a replacement char, `python3` errored, or BEFORE any in-place edit (`sed -i`, `perl -i`) on a `~/.claude/` path. git-bash on Windows.
---

# Bash command correctness (git-bash on Windows)

Command ran, output wrong. Different problem from a permission prompt — that's
[[bash-command-style]]. This file = the machine lies to you quietly.

Two of these are gate-backed (`background-pipe-gate.sh`, `inplace-edit-gate.sh`); the rest are
prose, so read them before assuming your command did what it looks like it did.

## Native exes mangle `/`-leading args (`MSYS_NO_PATHCONV=1`)

git-bash rewrites any arg starting with `/` into a Windows path before a **native** exe
(`aws.exe`, `jq.exe` — not MSYS programs) sees it. Symptom: baffling errors on values that
obviously match (AWS "must satisfy regular expression pattern").

Fix: `MSYS_NO_PATHCONV=1` on the call. Pipelines: each command gets its own env — prefixing only
the first doesn't protect a downstream `jq --arg`; `export` once at the top of the script that
needs it. Never export session-wide: another native exe (e.g. `jq.exe` opening a config path) then
gets the same mangled `/c/...` and fails. AWS call sites: [[ama-cloudwatch-search]].

## A value read out of `jq` carries `\r` — strip it before a native exe sees it

Sibling of the above, different cause. `jq`'s output here is CRLF, so
`while read -r x; do … done < <(… | jq -r '.foo[]')` leaves a trailing `\r` on every value.
Feed that to a native exe and the error names anything but whitespace — an ECS task ARN with
a trailing `\r` gives AWS "Invalid identifier: Unexpected number of separators", and the
stripped-to-bare-id form gives "taskId length should be one of [32,36]" (a 32-char id plus
`\r` is 33). Cost 20 minutes in `verify-qa-deploy.sh` (2026-09-15).

Fix: `| tr -d '\r'` on the value, not just on the pipeline's final output, and build the
arg list as a quoted array (`"${arr[@]}"`) rather than an unquoted string.

## `IFS=$'\t' read` COLLAPSES runs of tabs — empty column shifts every later field left

Tab is whitespace-class in `IFS`. `read -r a b c d` on `1\tgate.sh\t\tPATS` gives
`c=PATS`, `d=""` — not `c=""`, `d=PATS`. Non-whitespace separators (`:`) do NOT collapse;
tab/space/newline do.

Bites TSV state files with an optional middle column. Silent: no error, fields just slide.
Cost 4x of a perf win in `dispatch.sh` (2026-09-18) — needle landed in the args slot, every
gate read as "no needle, always run", still denied correctly so a smoke test passed.

Fix: never write an empty column — placeholder (`-`) and translate on read. Not `IFS=$'\t'`
alone. Writer and reader must agree, so put the rule in both headers.

## Paths to `node` — convert them; and `node -e` shifts argv

Two footguns, each hit twice in one session (2026-08-18).

**1. POSIX paths.** `node` resolves `/tmp/x` and `/c/Users/...` against the drive root
(`C:\tmp\x`, `C:\c\Users\...`) → `ENOENT`. Convert anything passed to node:
```bash
to_win() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
node script.js "$(to_win "$dir/file.json")"
```
`cygpath -m` emits `C:/...`, accepted by bash, node, `aws`, `unzip`. `mktemp -d` output needs it
too. Flip side of the section above: under `MSYS_NO_PATHCONV=1` (needed so an `s3://` URI
survives) the **local** path of an `aws s3 cp` also stops being translated and the download lands
in a bogus relative dir — pass the local side as `$(to_win ...)`.

Same for any `file://` **parameter** value, not just `s3`: `aws secretsmanager put-secret-value
--secret-string "file:///tmp/tmp.X"` dies `Unable to load paramfile ... No such file or directory`
even though the file is there — aws.exe cannot see the MSYS mount. `file://$(to_win "$tmp")`.

**2. `node -e` has no script-path argv element.** `node file.js a b` → `argv = [execPath,
scriptPath, a, b]` (user args from index 2). `node -e '...' a b` → `[execPath, a, b]` (from index
**1**). Reusing `const [,,a,b] = process.argv` in a `-e` one-liner shifts every arg by one.
Symptom is an `ENOENT` naming a *later* argument — reads like a missing file, not an off-by-one.

Args involved → use a real script file: normal argv, and analysable by the classifier (Rule 0).

## Large OR escape-heavy content → Write tool, not a bash heredoc

Large heredoc gets silently mangled/truncated mid-file. Substantial one-off script (Playwright,
Python, whatever) → Write tool, then execute the file.

**Size is not the only trigger — backslashes lose a level even in a short quoted heredoc.**
A regex char class written `[.\\[\\]]` landed as `[.\[\]]`, so the program was invalid; the
error was swallowed by a `2>/dev/null` and the function just returned nothing. Anything with
regex escapes, `\n`, or nested quoting → Write tool. For a jq program specifically, put it in
its own `.jq` file and use `jq -f` (see `hooks/lib-audience-policy.jq`): one reading, no shell
layer to lose an escape in.

## Long background run → redirect to a log, never pipe to `tail`/`head`/`tr`

`cmd ... | tail -20 &` buffers: nothing readable while it runs, everything lost if it's killed or
dies. Cost ~40 min across three occurrences in one session — a 20-min mutation pass died twice
leaving a 0-byte file, then a WSL probe piped to `tr` hung with an empty log.

Use `cmd > scratch/x.log 2>&1`, then read/`Monitor` the log. `grep --line-buffered` is fine (it
flushes per line). **Gate-backed**: `background-pipe-gate.sh` denies the pipe form.

**Don't wait on that log with `[ -s "$log" ]`.** Under `2>&1` the first stderr line (a git CRLF
warning, a pip notice) makes the file non-empty while stdout is still block-buffered and empty, so
an `until [ -s ... ]` gate fires instantly and whatever reads the log next finds nothing. Wait on
the actual finish signal: grep for the run's own summary line, or just let the background task's
completion notification arrive.

Also: don't edit a script while a background run of it is executing — bash re-reads the file at
stale byte offsets. Confirmed: a mid-run edit killed a mutation pass with exit 2, a parse error.

## Stopping a background task does NOT kill the shell it started

`TaskStop` kills the task wrapper; the `bash` it spawned, and that bash's own children, keep
running. Confirmed three times on 2026-09-14 (a stalled grep, a mutation run, a gate-suite
run) -- one kept forking for 20+ min after being "stopped", and the user had to flag it twice.
Worse, a still-running script BLOCKS editing itself (`running-script-edit-gate.sh`), so the
fix you want to apply is refused until the orphan dies.

After a TaskStop on anything long, confirm it actually died, and reap by command pattern:

```powershell
Get-CimInstance Win32_Process -Filter "Name='bash.exe'" |
  Where-Object { $_.CommandLine -like '*<script-name>*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

## `grep PATTERN $(find ...)` hangs forever when find matches nothing

Command substitution vanishes → grep has no file args → grep reads STDIN → blocks forever. Tool call
never returns, no output, no error. Confirmed 2026-09-14: a `grep -l ... $(find ~/.claude/debug
-newermt ...)` probe ran 10+ min on a `find` that legitimately matched zero files.

Fix: `</dev/null` on the grep, or `find ... -exec grep -l PATTERN {} +` (no-match → no exec at all).
Same trap for any stdin-reading filter fed by `$(...)`: `awk`, `sed`, `wc`.

## `grep -v ... || fallback` defeats itself on full dedup

`grep -v`/`grep -vFxf` exits 1 when EVERY line is filtered out — same exit code as "no
match" for any other reason. A `... | grep -vFxf seen.txt || printf '%s\n' "$all"` fallback
meant for a missing/broken file also fires on the "fully deduped, nothing new" case, silently
reprinting the whole input and defeating the dedup every time. Caught in a dry-run test
before it reached a real schedule (fleet-health-check.sh, 2026-08-25) — would have re-pinged
on every single run otherwise. Fix: don't fallback on grep's exit code; guarantee the seen-file
exists first (`touch`) so `-f` never errors, and drop the `||`.

## `Test-Path` says False for "access denied", same as "not there"

Any existence probe on a path inside a dir you cannot LIST reads as absent. `Test-Path`,
`[IO.File]::Exists`, `-f`: all False, no error. So "file gone" and "you're not admin" are
indistinguishable — and `Get-ChildItem -ErrorAction SilentlyContinue` hides the difference
too, returning empty for a denied dir exactly like an empty one.

Absence needs a listing with errors SURFACED: `Get-ChildItem $d -Force -ErrorAction Stop`
in a try/catch, and report `UnauthorizedAccessException` as UNKNOWN, never as absent.

Bit me 2026-09-01: reported a PanGPS crash dump "still on disk" under
`C:\ProgramData\...\WER\ReportArchive\` off that False plus a second error — WER Event
1001's attached-file list names what WER held AT REPORT TIME, not what survives (dump
lives in `ReportQueue`, purged after upload). Two independent false-positives for "the
artifact exists". Told the user to offer it to vendor support; it was not there.

## PowerShell here-strings (`@'...'@`) are a parse no-op in the Bash tool

Wrong shell → `@` lands in the string. A commit message passed that way committed with subject
`@ PROJ-...`; the ticket gate saw the ref and let it through. Bash tool multi-line string →
heredoc (`-F - <<'EOF'`). Each tool takes its own syntax.

## `python`, not `python3`

`python3` here resolves to the Microsoft Store stub and errors out.

## `[ -f x ]`, not `test -f x`

User profile aliases `test` (`eplus && ng test`) → inline `test -f` errors `Unknown argument: f`. Scripts unaffected.

## Non-ASCII in a bash argument silently corrupts

Console codepage 437, not UTF-8. An em dash, curly quote or emoji typed as a literal character
inside a bash argument is mangled **before the command runs** (`—` → replacement char, `🤖` →
`??`). `jq -n '"—"'` does not save you — corruption happens in the argument, upstream of jq.

Recipe: write the text with the **Write tool** (not shell redirection), then build JSON from that
file with `jq -Rs` — exact form in [[ama-bitbucket-api]]'s PR-comment section. Applies to all
outbound non-ASCII: commit messages, Jira/Confluence bodies, Slack messages.

**Same trap on the way OUT of python: its stdout here is the ANSI codepage, not UTF-8.** An
em dash printed by a script became a byte the next `json.load` rejected. First lines of any
python that emits text: `sys.stdout.reconfigure(encoding="utf-8")` (same for `stderr`). This
also means a bash-side string compare of non-ASCII taken from `python -c` fails on the harness,
not on the code under test — compare inside python and print an ASCII verdict.

## `sed -i` DESTROYS a symlink — never on a `~/.claude/` path

Every file under `~/.claude/` is a SymbolicLink into `ama-claude-harness` (dirs are Junctions).
`sed -i` writes a temp file and **renames it over the target**; rename replaces the link with a
standalone file. Edit lands outside the repo, git sees nothing, copies diverge silently.

Confirmed live 2026-08-17 on `harness-gaps.md`: `sed -i` "succeeded", file held the new text,
`git status` clean, `Get-Item` showed `LinkType` empty. Same rename hazard `on-prompt.sh` already
comments on for its own state writes. **Gate-backed**: `inplace-edit-gate.sh`.

Use the **Edit tool**, or write through the resolved repo path. Suspect it whenever an edit appears
to work but `git status` shows the file clean:

```bash
# is it still a link?
powershell -c "(Get-Item '$HOME/.claude/<file>' -Force).LinkType"
# repair: content to repo first, then re-link
powershell -c "Copy-Item <local> <repo> -Force; Remove-Item <local> -Force;
  New-Item -ItemType SymbolicLink -Path <local> -Target <repo>"
```

## Shell write to a gate-covered path — the gate never runs

Second, separate reason to reach for Edit/Write. Content gates match `Edit|Write` ONLY, so a
`sed -i`/`perl -i`, a `>`/`>>` redirect or a `tee` fires no hook at all — the rule silently
doesn't run. Bites hardest under auto mode, which prefers shell writes by default.

- Covered paths: `*/skills/*.md`, `CLAUDE.md` (`skill-bloat-gate.sh`), `standup-notes-*.md`
  (`standup-empty-section-gate.sh`), `~/.claude/projects/*/memory/*` (`native-memory-gate.sh`).
- **Gate-backed**: `shell-write-bypass-gate.sh` — denies, and names which gate was bypassed.
- Genuine bulk migration across many files → prefix `HARNESS_BULK_EDIT=1`, say why in the
  commit message. Logged to `harness-state/notices/bulk-edit-uses.txt`, never silent.
- **`${VAR:-x}` / `${VAR:+x}` print the VALUE**, not set-ness -- one such "probe" echoed a token into a transcript (2026-09-03). Set-probe is `[ -n "$VAR" ] && echo yes || echo no`.
