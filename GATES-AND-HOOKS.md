# Gate hooks & hook authoring — detail

Split out of `AGENTS.md` 2026-08-31 (<harnessEpicKey>). `AGENTS.md`'s "Reducing permission
prompts" section holds the terse gate map; this file holds the detail an agent needs when
WRITING or TESTING a hook, plus the archived full-rationale gate table.

## Hook wiring, injection, and lifecycle traps

**A hook wired into `settings.json` mid-session does not fire until the session restarts** —
settings are read at session start. Cost ~15 min to establish once: a newly wired recorder
wrote nothing across many real `git checkout`/`commit`/`push` calls while working perfectly
when invoked directly, which reads exactly like a broken hook. So **test a new hook by piping
it a `jq -n` payload (or via `check-gates.sh`), never by "run a real command and see"** — that
method can only produce a false negative until the next restart. Recurred 2026-08-19 with
`plan-exit-auto-approve.sh`.

**A `PreToolUse` hook can also inject guidance WITHOUT deciding anything**: emit
`hookSpecificOutput.additionalContext` and no `permissionDecision` at all. Use that when the
thing you want to influence is a judgement no hook can check (tone, depth, framing) — denying
or asking there builds a gate that cannot fail. Three traps:
- **Plain stdout is not shown to the model for `PreToolUse`** (only `UserPromptSubmit`,
  `UserPromptExpansion` and `SessionStart` surface stdout). It must be the JSON field.
- **Do not set `permissionDecision: "allow"` just to accompany the context.** An explicit allow
  can override a sibling gate's `ask` on the same tool call — several tools here have two hooks.
- `check-gates.sh`'s `decide()` reads `permissionDecision`, so a context-only hook reports
  `pass` whether it spoke or stayed silent. Assert on the text instead — `assert_ctx` in the
  `audience-policy-gate` block is the pattern.

**A gate created or rewired mid-session does NOT fire live in that session** — hook wiring
loads at session start (confirmed 2026-08-27: a freshly wired gate stayed inert for echo
probes and real calls alike until restart). Verify a new gate by piping payloads straight
into it (`jq -n ... | bash hooks/<gate>.sh`) and by suite case, never by "attempting the
action and seeing if it blocks" in the same session that wired it.

## Testing gates: check-gates.sh / mutate-gates.sh

**Touched a gate? Run it FILTERED — `bash scripts/check-gates.sh --gate <gate.sh>`**
(Enforced since 2026-09-14: `check-gates-unfiltered-gate.sh` DENIES the unfiltered form, and a
bare argumentless `mutate-gates.sh`. `CHECK_GATES_FULL=1` is the escape hatch; the gate matches
an invocation, not a mention, so `cat`/`grep`/`git diff` on the suite file are untouched.)
(or `CHECK_GATES_ONLY=<gate.sh>`), exit 0 = all asserted. It feeds each gate real payloads
and asserts the decision — behavioural, not a source-grep for whether the file mentions a
pattern. **~390 assert sites over 72 gates, ~615 assertions executed**; the filter skips each non-matching gate's whole
block, so its mktemp trees, git clones and PowerShell launches are skipped too, not just its
assertions.

**Measured 2026-09-09: full pass ~10 min, one gate ~60-80 s, of which ~30 s is a floor** —
about 23 assertions are suite-level rather than gate-scoped (the mutates-a-live-file
meta-test, the harness-gaps runner, set-session-ticket) and deliberately still run under a
filter, since they check the suite's own integrity. The summary says so; don't read a
filtered run's pass count as belonging to the named gate.

**Why a full pass is slow, so nobody re-derives it:** ~451 assertions × (1 `jq` payload +
1 gate process) and each gate is itself 5-20 processes ⇒ **5-10k fork-emulated processes**, at
~60 ms per exec on this host (the Sysmon per-exec certificate check in the fork budget below).
Nothing is leaking; it is just that long. That length is also why a background full run can
be killed by a low-memory supervisor — one was on 2026-09-09, on a box with ~4 GB free — so
prefer the filtered form and keep the full pass for a final check.

A run now prints `gate N: <name>` to **stderr** as it goes. Before that, a passing run
printed nothing at all until the final summary, so ten minutes of silence proved neither a
hang nor an absence of failures, and a killed run said nothing about how far it got.

**`--gate` takes a SET**, colon-separated (`--gate a.sh:b.sh`); one name behaves exactly as
before. `run-check-gates-full.sh` uses that to sweep only the sections the run-owed reminder
names — `check-gates-currency-gate.sh` records them as `G:<gate>` / `N:` lines as you edit,
and a non-gate file maps to the gate section that actually asserts about it, not to "suite-
level only". Anything unaccounted for (empty, legacy, or >8 sections) falls back to the FULL
pass: unknown state must cost time, never coverage. Measured 2026-09-14: 83s vs ~10 min.

**Both wrappers stream to a log now** rather than capturing into a variable. The captured
form produced a 0-byte log for the whole run, so a hang and progress looked identical for
20 minutes. `run-check-gates-full.sh` also **refuses** while more than `CHECK_GATES_MAX_LIVE`
(default 3) sessions are live — under contention the cases fail spuriously and prove nothing.
`CHECK_GATES_FORCE=1` overrides.

**Every shared `assert_*` helper belongs above the first gate section (~line 150).**
`assert_reason` sat ~480 lines below its first caller, so two cases died with
`assert_reason: command not found` on stderr and never asserted, while the suite still
reported green — the "a case that cannot fail is worse than no case" failure itself.

**Temp files survive a kill.** The EXIT/INT/TERM trap removes this run's own dirs, but a
supervisor kill is SIGKILL and uncatchable — verified, and 11 stale entries were sitting in
`/tmp`. So each run also reaps orphans older than 60 min on startup (age-bounded on purpose:
a concurrent run's files are minutes old and are left alone; a bare prefix glob would delete
a live run's state).

A filter that matches no gate **exits non-zero and says nothing was asserted** — a silent
green run there would be worse than no filter.

One case legitimately SKIPs while another session has staged files in the harness index —
that's the publish-scrub deny probe, which needs a clean index to stage into, not a failure.

**Coverage: 37 gates covered, of 43 gate/nudge/reminder hooks present** (2026-08-19; the count
moves as concurrent sessions add hooks — recount with `grep -oE '^G=' scripts/check-gates.sh | sort -u | wc -l`
rather than trusting this number). The longest-standing exception is
`hotfix-version-claimed-gate.sh`, deliberately uncovered: its deny path queries live Jira for
claimed versions, so a hermetic case can only assert its early exits — all PASSES, which the
mutation test would correctly report as cases that cannot fail. No case beats a case that
proves nothing.

**The suite runs from a private temp COPY of itself and exits nonzero from an `EXIT` trap**
(2026-08-28). Bash reads a script lazily, so an edit to `check-gates.sh` mid-run — own or a
concurrent session's — corrupted the remaining source twice on 2026-08-21 and the run died
early with FAIL lines printed but **exit 0** (the trailing `[ "$fail" -eq 0 ]` was never
reached). The copy is immune to later edits; the trap turns any early death, or any counted
failure, into exit 1. A **meta-test** at the end greps the ORIGINAL source for `sed -i`/`>>`
aimed at live `~/.claude` files — the 2026-08-20 case that turned the `harness-gaps.md` symlink
into a plain file would have failed it.

**Some gates were verified by a one-off scratchpad script instead of a suite case** — the
`hotfix-version-claimed` and `ticket-worked-while-open` fixes were proven against live-shaped
payloads and then the script was thrown away, so those specific proofs are not standing
regression tests (`develop-backmerge-reminder` and `git-push-ticket-reminder` gained hermetic
fixture-repo cases on 2026-08-28 — `git init` + `update-ref refs/remotes/origin/…` is enough
to make their predicates decidable offline). Reviewed 2026-08-19 and **accepted, not a debt to
pay down**: the remaining deny paths need live Jira state, which is the same reason `hotfix-version-claimed-gate.sh` is
deliberately uncovered above — a hermetic case for them can only assert early exits, and a
case that cannot fail is worse than no case. Add a suite case when a rule becomes decidable
from the payload alone, not to make a coverage count look better.

Four fixture patterns the newer cases use, reusable for anything added later:
- **Side-effect hooks** decide nothing and write state instead (`chrome-verify-compact-nudge`
  queues into `.ctx-notices-<sid>`) — assert the artifact via `assert_writes`/`assert_no_write`,
  never the exit code. Its one-shot GUARD lives elsewhere
  (`.usage-state/chrome-compact-nudged-<sid>`, shared with on-prompt.sh's idle-browser nudge, deleted by
  `chrome-compact-rearm.sh` on `SessionStart` source `compact`); clean both or the case passes
  exactly once.
- **Throwaway git repos** for `git-commit-scope`/`master-push-direct`. The latter excludes any
  path containing `ama-claude-harness` or `.claude`, so its fixture must live in `mktemp -d` —
  pointed at the harness it asserts nothing.
- **Payload-supplied state**: `parallel-fanout-gate` reads `transcript_path` from the payload,
  so a synthesised `.jsonl` is enough — no fake `HOME`. It also acts only in `default`
  permission mode, which is itself asserted.
- **One-shot approvals**: `deploy-verify-confirm-gate` CONSUMES its line in
  `.deploy-verify-approved` on its PostToolUse side, so the case asserts deny → approve → pass
  → pass (Pre never consumes) → Post → deny again.

**Assert reasons, not just decisions**, wherever a gate branches: `assert_reason` exists because
`bare-cd-gate` shipped a correct deny with a *false* reason (it told the reader a compound `cd`
to the session's own home "leaks cwd forward" — the target IS cwd), and a decision-only case
cannot see that. `bare-cd` and all four `unanalyzable-script` rules now assert their reason.

Run `mutate-gates.sh` **targeted** (`mutate-gates.sh <gate.sh> …`) after adding cases — a full
29-gate pass re-runs the whole suite per gate, so it costs ~35 minutes.

**It catches real mistakes, including in cases written by someone who knew the rule.**
`publish-scrub-gate` shipped with four cases that all expected PASS (two of them asserting
`publish-public.sh --check-paths` directly, which never invokes the gate), so neutering the gate
changed nothing and mutation reported "case cannot fail". The fix was a real deny: stage a file
holding a forbidden token, assert, unstage. Because the index is shared with concurrent sessions
that case **skips itself when anything is already staged** rather than touching a dirty index —
a legitimate skip, and the reason is printed.

**A FAIL means a FAIL — don't re-run past it.** An earlier revision of this note said a cold
environment produced one spurious `readme-currency-gate.sh` failure; that was a state-isolation
bug in the suite, since fixed (`3d7f22c`). Each readme-family case now gets its own fresh probe
session id with probe state cleaned either side, and three consecutive runs — one with probe
state deliberately wiped — were identically 135/0/0 at the time (150/0/0 now).

**And the direction that flake was reported in was backwards, which matters for diagnosing the
next one.** It was logged as "spurious FAIL on the FIRST run in a cold environment, passes
afterwards". Probing the gate with a genuinely never-seen session id shows the opposite: call 1
**blocks** (empty nudgefile → `already_nudged` unset → a `lines=999` edit clears the `total > 5`
threshold), and calls 2 and 3 are silent because the nudge was recorded. So a `want=block` case
fails on a **later** run, from state a previous run left behind — never on a genuinely cold one.
For any one-shot or thresholded gate, the suspect is leftover state, not absent state; wipe and
re-probe rather than pre-seeding, which would only make the case pass for the wrong reason.
Delete just `.session-chatfiles/check-gates-probe*` when doing that — **never** the directory,
which also holds `<sid>` files for LIVE sessions that `bare-cd-gate.sh` reads.

**Two passes at once used to corrupt each other — that IS the "spurious first run" story.** The
probe fixtures live at shared paths (`~/.claude/.session-chatfiles/<sid>`,
`~/.claude/harness-state/tickets/.deploy-verify-approved`), and the ids were fixed literals, so a second pass wrote and
then *deleted* the first's state mid-flight. Three routes reached it: `mutate-gates.sh` spawns a
full pass per gate, **another session in this shared clone can run the suite at any time**, and
an interrupted run leaves state behind. It presented as `bare-cd` denying a `cd` to its own
session home (chatfile gone between write and read, so the gate fell back to cwd and gave the
*foreign-path* reason) and as both `deploy-verify` cases inverting — intermittent, and visible as
172/3 in the mutation baseline against 175/0 on the real tree **from the same source**.

**Fixed, not merely forbidden**: probe ids now carry a per-run `$PROBE_TAG` (`$$`), and every
cleanup glob is tag-scoped through `probe_state_clean` — a bare `check-gates-probe*` wipe would
delete a concurrent run's state and cause the very failure it was meant to prevent. Concurrent
passes are independent now. Two real bugs surfaced underneath: `grep -v … && mv` skips the `mv`
when grep selects nothing, which is exactly a file holding only a stale probe line (so cleanup
silently did nothing), and `mutate-gates.sh` aborted on a red baseline printing only the count —
it now prints the FAIL lines, since a red baseline is a fault in the **suite or its fixtures**,
never in a gate, and a green run against the real tree does not clear it.

Three traps that make a case pass or fail for the wrong reason, all hit while writing these:
- **`jq -e` exits 0 on EMPTY input** on this box's jq 1.5rc1, so a block-shape probe reports
  "block" for a hook that said nothing. `decide()`/`decide_block()` test `-z "$raw"` FIRST.
- **Some gates self-resolve the harness** from `~/.claude/skills` and ignore this script's
  `$harness` argument, so their payloads must name the real harness (`$real_harness`) even when
  `$hooks` is a relocated copy. Otherwise they fall through to "pass" and read as gate bugs.
- **State-carrying gates are one-shot or thresholded**: the readme family records per-session
  state and `readme-currency-gate.sh` only nudges above 5 accumulated changed lines;
  `jira-fixversion-confirm-gate.sh` reads `~/.claude/harness-state/tickets/.confirmed-jira-versions`, so test versions
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

## Matching a command: data is not a command

A gate that greps a Bash command for an invocation matches **fixture text** too: a quoted
argument, a variable assignment, a heredoc body that merely CONTAINS the command. Four gates
have been bitten by it — `git-commit-ticket-gate.sh` (header has the original),
`check-gates-unfiltered-gate.sh`, and `ready-to-test-regression-reminder.sh`, which had no
exclusion at all and denied a call whose only Jira content was a quoted fixture.

- Source `hooks/lib-command-text.sh`, pipe the command through `command_text_stripped`, and
  match the STRIPPED text. It cuts heredoc bodies and single-quoted spans; double-quoted spans
  are kept (minus the quotes) because real invocations live in them.
- Strip for the DETECTION grep only. Anything that reads a value out of the command — a payload
  path, a ticket key — still reads the original.
- Anchor as well as strip: `(^|[;&|]|&&)\s*` before the command name. Stripping without the
  anchor still matches a path mentioned mid-argument.
- Every consumer is on the lib now (2026-09-15); there is no reason for a new private copy.

### Heredoc bodies: data, unless the same command runs what it wrote

A WRITE or DEPLOY gate must not use `command_text_stripped` (it drops single-quoted spans, and
the Mongo/psql write lives inside a single-quoted `--eval`). It must not use
`${command%%<<*}` either. That idiom strips from the first `<<` to the END of the command --
the heredoc body AND every command after the terminator -- so

    cat > x.sh <<'EOF'
    <the write>
    EOF
    bash x.sh

left ten gates looking at `cat > x.sh` and nothing else. Replayed 2026-09-15: mongo-write,
psql-write and graylog-write all silently allowed a production write in that shape; both
Octopus deploy gates had been bypassed by it live the same morning. The harness's own style
gates push commands INTO this shape, so it is the common case.

Use `command_scan_region "$command"` from `lib-command-text.sh`. It removes heredoc bodies,
then asks whether what is LEFT runs a file (`bash|sh|pwsh|powershell <path>`). Yes -> the
command wrote and executed in one step, the body is code, the whole command is returned. No
-> the body stays data. A doc edit never executes what it wrote, so the self-denial trap
stays closed. Pin BOTH shapes in check-gates.sh for every gate that uses it: heredoc+run must
deny, a commit message describing the hazard must not.

### Fail direction follows the reversibility of the guarded action

Not author instinct. A hook decides fail-open vs fail-closed on "what happens if I am wrong
and silent?": a denied commit or a delayed deploy is reversible; a secret on the public
mirror, a production write, a production deploy in business hours, a wrong clock are not.
`publish-scrub-gate.sh` failed open on an unresolvable harness root for a year (four `||
exit 0` in a row) while `prod-api-test-window-gate.sh` next to it failed closed for a lesser
hazard. Fail closed on the branch where you cannot tell whether the irreversible thing is
about to happen; fail open only on branches that prove it is not.

## Hook fork budget & hook-run.sh

**Hook fork budget** — process creation costs ~60ms on this machine (Intune-managed
Sysmon64 with `CheckRevocation` + HVCI; per-exec certificate checking, confirmed by
signed binaries costing ~3x unsigned and warm re-runs not getting cheaper — not
Defender, whose CPU stayed flat under a spawn loop, and not hardware). A single Bash
tool call matches 11 PreToolUse + 4 PostToolUse hooks (unaffected by
`human-readme-edit-gate.sh` below, which matches `Edit`/`Write`, not `Bash`/`PowerShell`);
the full stack measured **11.7s per tool call** before de-forking, **~2.2s** after
(<harnessEpicKey>). The floor is
~0.8s of unavoidable `bash` launches.

**Those counts went stale, and COUNT is what actually bit (2026-09-18, <harnessEpicKey>).**
Four weeks later the block had grown to **76 hook commands per Bash tool call** (49
PreToolUse + 21 PostToolUse on `Bash|PowerShell`, + 6 on combined Jira/`*` matchers). It
presented to the user as ~13 minutes to load four session-start skills. Measured on an IDLE
box: `bash -c true` ~40ms, a gate ~57ms — only ~4s of tax, so per-exec cost did NOT explain
it. The spawn storm does: under real concurrent load the same execs degrade to 777–8,739ms
(harness-gaps, session 9149fa95), non-linearly. **The fix is fewer processes, not cheaper
ones.** Sourcing gates into one process instead of exec-ing them was measured and rejected:
51ms vs 57ms, ~10%, for a rewrite of 44 gates.

**`hooks/dispatch.sh` — one hook command for the whole `Bash|PowerShell` PreToolUse block.**
Reads the payload once, evaluates each gate's OWN needle in-process, and spawns only the
gates that match. Needles are extracted from the gates by `hooks/build-needle-cache.sh`,
never hand-copied — a hand-maintained needle table goes stale on the first gate edit, and a
stale skip means the gate never fires while the call looks exactly like a pass. Measured: 44
unique gates → 6 run for `echo hello world`, 8 for a `cat`, 13 for a `git commit`;
**4,199ms → 1,036ms per block** on the benign case, same box, same load.
- A gate with no parseable needle is marked `@ALWAYS` and always runs (fail-open to the old
  behaviour). As of 2026-10-12 only `dev-server-teardown-reminder` is (trigger is "a marker
  file exists", which no payload needle can express). `parallel-fanout-gate` now opens with a
  `permission_mode` needle — it only acts in `default` mode, so auto/plan sessions never spawn it.
- **Needle traps (<harnessEpicKey>):** needles match the payload with `transcript_path` removed; second filter = `[[ $payload == … ]] || exit 0`, never a 2nd `case` (extractor ORs every block); a gate in a dispatch manifest must not also sit in a `Bash` settings matcher (runs twice).
  - Extractor drops scratch-root needles (`*scratch*|*Temp/claude*`); `dispatch.sh` matches remaining keywords against payload + referenced script text (64 KB cap).
  - `check-dispatch-equivalence.sh` is blind to this class (scratch fixtures gone on replay) -- use `check-gates.sh --gate dispatch.sh` (builds live).
  - `touch` a gate after installing it with an atomic `mv` (rename keeps edit-time mtime; incremental cache rebuild reuses the stale row).

**Writing a needle the extractor can actually read (2026-09-22).** The five gates the note
above called "the next easy win" were not missing needles — four had perfectly good ones that
`build-needle-cache.sh` silently refused to parse, and the cache they went into had been
frozen since the day it was written. Conventions, all now enforced by the extractor:
- It reads **`case "$payload"` blocks only**. A needle on `$command` or `$tool` is invisible
  to it, so the gate forks on every shell call. Mirror it as a `$payload` block rather than
  moving it — the payload is a superset of the command, so the mirror can only over-match,
  and over-matching costs one spawn while under-matching runs the call unguarded.
- The block needs a `*)` catch-all that `exit 0`s, or it is not treated as a prefilter.
- Every `case "$payload"` block in the file is OR-ed together, so one un-parseable block
  used to poison the gate's whole needle.
- Whole-line `#` comments inside the block are fine (they used to be concatenated onto the
  pattern line — this is why `shell-write-bypass-gate`, the most expensive gate in the set at
  1218ms, was `@ALWAYS`).
- Spaces inside quoted patterns are fine (`*" -x"*`, `*"ng serve"*` were both dropped by a
  branch-head filter that rejected any embedded whitespace).
- A metacharacter that the gate itself quoted is inert and accepted
  (`*'>'*harness-config.json*`); only an UNQUOTED `` ` ; & < > `` or `$(` is refused, since
  the pattern reaches `eval`.
- A needle whose alternatives are all fully single-quoted globs (`*'$('*|*'`'*`) is stored as
  `@LIT a|b` and matched with a quoted `case`, no `eval` at all.

**Staleness, and why it matters more than the parsing.** `dispatch.sh` decides the cache is
stale with `find -L "$HOOKS" -maxdepth 1 -name '*.sh' -newer "$cache"`. The `-L` is
load-bearing: `~/.claude/hooks` is a symlink, and `find <symlink>` without it treats the start
path as a file and matches nothing — which is how the cache stayed frozen from its first write,
with no gate needle edit taking effect since. `build-needle-cache.sh` additionally discards the
whole cache when it is itself newer than it, because incremental reuse is keyed on each gate's
mtime and is therefore blind to a change in the extractor.

**A gate that makes a live network call makes `check-dispatch-equivalence.sh` flaky.**
`ready-to-test-readiness-gate.sh` queries Jira, so its verdict depends on the issue's current
state: two runs over the same trace gave 132/132 OK and 133/134 FAIL, with the *pair count*
itself differing. Since 2026-10-05 such gates are listed in that script's `NETWORK_GATES` and
counted as skipped (stubbing the call would only test the stub) — add a new network-calling
gate there. On any other FAIL, read the crumb in `harness-state/logs/gate-invocations.log`
before theorising — `rc=124` is a timeout, `rc=0` means the gate ran and simply decided
differently, and only the first is a timeout problem.
- **Each gate keeps its own `timeout` INSIDE the dispatcher.** A single chain-wide timeout
  would fail every gate in the block open at once — the enforcement gap recorded below for
  psql/mongo, industrialised. `timeout` costs ~35ms per gate; pay it.
- **Never leave a manifest/cache column empty.** Bash classes a tab in `IFS` as whitespace
  and COLLAPSES runs of them, so an empty middle column shifts later fields left. That put
  each gate's needle into its args slot, leaving the needle empty → every gate fell back to
  `@ALWAYS` and ran anyway. It passed a smoke test and still denied correctly; it just
  quietly saved nothing (13%, vs 4x once fixed). `-` is the placeholder.
- The needle cache rebuild is incremental (reuses rows for gates not newer than the cache).
  A full rebuild forks per gate and measured ~8.4s — far too slow for the hot path, where
  ANY gate edit triggers it. Incremental: ~0.13s.
- Prove the prefilter drops nothing with `scripts/check-dispatch-equivalence.sh` — it
  replays every payload the check-gates suite exercises and fails if a gate that DECIDES on
  a payload loses that decision through the dispatcher. Over-broad needles only cost a
  spawn; too-narrow is the bug that matters. `--full` re-harvests the payload trace (~15
  min); bare reuses the newest trace (~10-40 min on Windows, per-pair gate+dispatch spawns); `--mutate` narrows a real needle and
  asserts the check goes red. `dispatch-needle-currency-gate.sh` demands it whenever a
  dispatched gate, the dispatcher or the extractor is edited — prose alone would not fire.

**Both halves are dispatched now (2026-09-18):** `dispatch-post-bash.manifest` covers the
PostToolUse `Bash|PowerShell` block (18 reminders → 1 command; 76 → ~10 hook commands per
shell call, the rest being combined Jira/`*` matchers). dispatch.sh reads
`hook_event_name` and emits the PostToolUse dialect (`{decision:"block", reason}`) when
merging that block. **Keep `decision:block` for PostToolUse reminders** (user decision
2026-10-12): the red "blocking error" label is wanted — it makes reminders visible and
separate from normal output. Don't migrate them to `additionalContext`. Regenerate with `gen-dispatch-manifest.sh --event PostToolUse`, rewire
with `wire-dispatch.sh --event PostToolUse --apply` (and `--template`), prove with
`check-dispatch-equivalence.sh --post`. `on-prompt.sh` is NOT a dispatch candidate: its 7
notice checks are already throttled to once per 30 min machine-wide (`notices/.nudge-checks-
lastrun`, 2026-08-31), the only per-prompt fork left is `render-sessions-md.sh` (perl, ~1s),
and the residual is measured under "Cross-session concurrency" below (~10s fixed, ~26s on a
nudge-due prompt). The old "~30 serial children / 66s" figure predates the throttle.

**`harness-state/logs/gate-invocations.log` — the breadcrumb.** dispatch.sh appends one
tab-separated line per gate it actually runs: epoch, event, gate, rc (`124` = killed by its
timeout), session shortid. Builtins only, no payloads (sandbox-allow.log became a
secret-at-rest for exactly that reason). Rotated at 5MB by on-session-end.sh. Use it when a
gate "should have fired": no line = the needle skipped it or the block never ran; rc 124 =
timing fail-open -- or a DENY when the gate's header carries `# dispatch: fail-closed-on-timeout`
(the three production gates, after 11 fail-opens in one day: standby plus a background suite,
2026-10-15); `-unless-nonprod` variant (psql/mongo write gates) denies unless the command +
referenced scripts name only qa/staging; a line with rc 0 and no output = it ran and allowed. A parent-side
reconciliation (tool calls made vs lines written) is still unbuilt — and it would not see
subagent calls, where hooks do not run at all (CLAUDE.md).

**Hook files are not edited atomically across sessions.** Another session mid-`Edit` on a
gate makes every concurrent Bash call die with `syntax error near unexpected token` naming
that gate for a second or two, then heal. Re-read the file before diagnosing a broken gate.

**A checker must never re-implement the thing it checks — it only tests itself then.**
Sibling of "a case that cannot fail is worse than no case" above, and it cost a full
re-write here (2026-09-18). `check-dispatch-equivalence.sh` v1 re-implemented dispatch.sh's
needle match in its own process for speed. It was blind in both directions at once: it could
not see the tab-collapse bug in dispatch.sh's OWN loop (it parsed the same cache with the
same wrong `read`, and agreed with itself), and its hand-rolled matcher disagreed with bash
about `*'\n'*`, so it reported 7 "silent drops" that the real dispatcher does not have —
sending the investigation after phantom bugs in correctly-working gates. Drive the real
binary and cache the expensive INPUT (the payload trace) instead of reimplementing the
logic. Same rule for any future gate-layer checker.

Conventions that keep the per-exec cost down:
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
- **A gate can be silently not enforced while its logic is perfect — the call runs
  UNGUARDED and looks exactly like a pass.** Observed 2026-09-18: `psql-write-gate.sh` and
  `mongo-write-gate.sh` both let a real `update` through live (twice each) while the
  identical payload replayed straight into the gate came back `deny`. Breadcrumb proof that
  the gates now run for the session (`case "$payload" in *<session-id>*) printf … >> log`)
  plus 2/2 live denials each came only AFTER de-forking them. **Root cause is not
  established.** The measured candidate: psql ran ten `printf | grep -qiE` probes and took
  12–22s against its own 15s timeout, so the CLI could kill it mid-run — but mongo measured
  2.5s and missed too, and one post-de-fork call still slipped, so timeout alone does not
  explain it. Delivery (a chain-wide budget, or a session-start snapshot) is the other
  candidate and is only testable from a fresh session. What IS established: de-forking made
  enforcement reliable in both, 22s → 0.4s.
- **Time a gate as part of testing it** — `time (bash <gate> < payload.json)` on a payload that reaches the DECISION, not one that exits on the needle. `gate_timing_check` in `check-gates.sh` times every gate and FAILs at its manifest timeout (`gate_timeout_of`); verdict goes through a file (a `fail++` inside `$(...)` is lost). Wall-clock miss may be machine asleep (`scripts/proc-start-latency.sh`): re-run first; `CHECK_GATES_NORMAL_PRIORITY=1` times as-live. A gate in neither manifest is not timed -- use manual `time`. Match
  with bash's own `=~` on a lowercased copy rather than a grep per check (bash ERE has no
  `\b` — spell word edges as `(^|[^a-z0-9_])`), and never `jq @tsv` for a field pair: it
  escapes backslashes, so Windows paths come back doubled and any `[ -f "$path" ]` on them
  silently fails.
- `statusline.sh` renders continuously: it dropped ~2.3s → ~0.3s per render
  (one merged jq, bash-arithmetic thresholds, own-format statefiles parsed with bash
  regex instead of jq).

**Every hook runs through `hooks/hook-run.sh`** (settings command shape:
`bash "$HOME/.claude/hooks/hook-run.sh" "$HOME/.claude/hooks/<gate>.sh" [args]`) — it is the
only process holding Claude Code's stdio pipes; the gate and everything it forks get
files (`~/.claude/scratch/hook-run/<pid>.{in,out,err}`) instead. Why (2026-08-28): a tool
call sat "Percolating…" 50+ min inside the PreToolUse chain. 13 orphaned hook `jq.exe`
were alive for days, 1 thread each in `WaitReason: Suspended`, CPU 0 — cygwin fork children
never resumed because the hook's bash.exe was killed first (Claude Code's per-hook timeout
kills one process, not the tree). The orphan kept the inherited stdout pipe open → Claude
Code waited for EOF forever. Worse with more concurrent sessions (spawn storm). Diagnose a
frozen tool call with `Get-Process jq,bash | ? {$_.Threads[0].WaitReason -eq 'Suspended'}`
and kill those. Wrapper costs one fork (the inner bash), passes exit code + stderr through
(exit 2 = block unchanged). Wiring a new hook: use the wrapper form, always set `timeout`.

## redact-secret.sh

**Not a gate, run on demand:** `hooks/redact-secret.sh <literal|-> [replacement]` strips a
leaked literal out of local Claude Code state — transcripts (incl. `subagents/`),
`file-history` snapshots, chat logs, hook logs — walking the whole `~/.claude` tree plus
this repo rather than an enumerated subset. Uses `perl`, not `sed` (a secret containing `&`
would corrupt a `sed` replacement), prints per-file counts and never the value, and is
idempotent. Pass `-` to read the secret from stdin so it never enters a command line. It's
**hygiene, not containment** — if the value is committed in a repo or live on a server,
rotation is the only real fix.

## Archived full-rationale gate table (point-in-time, 2026-08-31)

The living source for each gate's rationale and incident history is the hook file's OWN
header comment — update headers, not this archive. Kept because the split-out rows carried
narrative not yet verified present in every header.

| Hook | Fires on | Blocks |
|---|---|---|
| `bare-cd-gate.sh` | `Bash`/`PowerShell` | A LEADING, unparenthesized `cd <path>` (alone, or followed by `&&`, `;`, or `\|`) — shell cwd persists across separate calls, so either shape leaks it forward. Use `(cd X && cmd)` (a real subshell) or pass the path as an argument instead (`git -C X ...`, `ls -la X/`). Only the command's own first token is in scope — deliberate, keeps it quote-safe (a broader version was tried and reverted after it flagged `cd` text merely *quoted* inside an argument). Exempt: a **bare** `cd` back to the session's own home dir (corrective return). The COMPOUND form is denied even for home — Claude Code can't statically resolve a cd-compound's final cwd on git-bash, so it refuses to delegate the call to the auto-approval classifier and prompts manually every time. |
| `parallel-fanout-gate.sh` | `Bash`/`PowerShell` | The 2nd+ call in a genuine parallel dispatch batch — one denial otherwise rejects the WHOLE batch at once (7 fired together → all 7 lost). Detected deterministically from the transcript (consecutive `tool_use` entries with no `tool_result` between them), not a timing guess — a timing heuristic misfires on ~22% of ordinary fast *sequential* calls. Use separate `Agent` calls for genuinely independent parallel work instead — no shared shell state, not gated by this. |
| `grep-memory-gate.sh` | `Bash`/`PowerShell` | A recursive `grep -r`/`-R`/`--recursive` missing `-I` (binary-skip) — an unscoped recursive grep buffers a binary file as one giant "line" (hit ~2GB then ~6GB RAM). See the `grep-usage` skill for the fuller scoping guidance this doesn't hard-gate (`--exclude-dir`/`--include`). |
| `deploy-verify-confirm-gate.sh` | `Bash`/`PowerShell` | Launching `verify-qa-deploy.sh`/`verify-deployment-e2e.sh` before the user has explicitly said yes for THIS session — docs already said "never run unprompted" in three places and it still got skipped once. Confirmation is one-shot, not carried into a later push; consumed PostToolUse (dispatch-post-bash), so a call a sibling gate denied keeps it. |
| `aggregation-secret-gate.sh` | `Bash`/`PowerShell` | Running `get-aggregation-connection.sh` without consuming its output, so its `export PGPASSWORD=...` line would print the live DB password into the transcript. Allowed: the documented `eval "$(...)"` form, a variable assignment, a pipe, or a redirect. Querying that DB at all is better done via `rs-query.sh` (redshift-data API, no password involved). |
| `unanalyzable-script-gate.sh` | `Bash`/`PowerShell` | **Backstop for `bash-command-style`'s Rule 0** (beyond a simple pipeline → Write a script file, run `bash <file>`, which is analyzable by construction). Catches the INLINE command shapes Claude Code can't statically analyze — it then refuses to delegate the call to the auto-approval classifier and falls back to a manual permission prompt every run, subagents included. **(a)** any loop (`for`/`while`/`until` + `done`) **at any length**, including a one-liner ("Contains simple_expansion" — the loop variable and any path built from it are unresolvable) → Write it to a file, run `bash <file>`; **(b)** `if`/`case` spanning lines, or a multi-line embedded awk/perl program → same fix (single-line `if …; then …; fi` stays allowed); **(c)** a quoted string left open across a newline, i.e. `git commit -m "multi-line msg"` → use `git commit -F - <<'EOF'`; **(d)** an unresolvable ALL-CAPS env var (`$ATLASSIAN_API_TOKEN`, `$OCTOPUS_API_KEY` — `$HOME` and friends are resolved fine) → same script-file fix, which also keeps the token out of the command line and transcript. Only the region before the first `<<` is measured, so heredoc bodies are exempt. Each rule was added after a shape slipped past the previous ones and cost a real prompt — **don't assume the set is complete**; `bash-command-style` carries the 6-step triage recipe (get the exact command from the transcript, replay it through the hook, read the prompt's own reason string, cost the rule against both corpora, widen the prefilter, live-probe). Measured by replaying two sessions in full: mine 112/122 allowed, 55c72ae1 154/176 main and 155/162 subagent. The ~8% denied in ordinary work is concentrated in ad-hoc analysis one-liners, which belong in a file anyway — hence the loop rule at full strength rather than fitted to one trigger. Quote-blind on purpose (`bare-cd-gate.sh` reverted quote-aware matching), so script text passed as DATA also denies — put hook-test fixtures in files. No bypass marker: skipping this gate wouldn't skip Claude Code's own refusal. |
| `short-path-gate.sh` | `Bash`/`PowerShell` | A command containing an 8.3 short path segment (`RYAN~1.STE`, `PROGRA~1`) — the tilde reads as an unresolved expansion and costs the same manual prompt. Long and short name the same directory, so it always rewrites safely; prefer `$HOME/...`. Pattern requires a trailing path separator, so `HEAD~1`, `HEAD~1..HEAD` and `~/` are out of scope. Root cause (`TEMP`/`TMP` in 8.3 form) fixed on this machine 2026-08-17 — see the `bash-command-style` skill. |
| `background-pipe-gate.sh` | `Bash` | A **backgrounded** call (`run_in_background: true`) that pipes into `tail`/`head`/`tr` — those buffer when stdout isn't a terminal, so nothing is readable while the job runs and **everything is lost if it's killed**. Confirmed 3× in one session (2026-08-18/19): a 20-minute mutation pass piped to `tail -20` died twice leaving a 0-byte file, then a WSL probe piped to `tr` hung with an empty log; ~40 min lost. Keys off the **background flag, not the pipe** — a foreground `\| tail` is correct and constant, so a pipe-only rule would false-positive endlessly. `grep --line-buffered` is deliberately allowed: it flushes per line and is the documented way to stream a background feed. **This gate exists because prose failed:** `bash-command-style` documented the trap the same morning it was then broken 3×, since that skill's retrieval description is about *permission prompts* and nothing surfaces it when the task is "run a long job in the background". Same session, the four gated command rules blocked and were obeyed 5/5; the ungated prose rule held 0/3 — `CLAUDE.md`'s "mechanical triggers over self-recognition", measured. |
| `inplace-edit-gate.sh` | `Bash`/`PowerShell` | An in-place stream edit (`sed -i`, `sed --in-place`, `perl -i`, `-i.bak`) against a `~/.claude` path. Every file there is a SymbolicLink into this repo, and these tools RENAME a temp file over the target — which replaces the link with a standalone file, so the edit lands OUTSIDE the repo, `git status` reports clean, and the copies silently diverge. Confirmed live 2026-08-17 on `harness-gaps.md`: sed reported success, `LinkType` came back empty. Shell sibling of `symlink-write-gate.sh` and the worse half — Edit/Write at least refuse; `sed -i` succeeds. Narrow by design: needs an in-place FLAG plus a `.claude` path, so `sed -n`/`grep -i` on those paths pass. The flag must be a real TOKEN (whitespace, `-`, optional bundled letters, `i`) — matching a bare `-i` anywhere in the argument region was wrong BOTH ways: it denied `sed -n '1,25p' …/jira-edit-issue.sh` (the `-i` sits inside `edit-issue`) and it MISSED `perl -pi -e` / `perl -npi.bak -e`, the classic in-place perl idioms this gate exists to stop. Fixed 2026-08-18 against a 17-case fixture. |
| `publish-scrub-gate.sh` | `Bash`/`PowerShell` | A `git commit` in THIS repo whose staged content would abort `scripts/publish-public.sh` at its forbidden-token gate — the gate otherwise only runs post-commit inside `on-stop.sh`, so a bad token broke the public mirror silently (it did, for a full day). Calls `publish-public.sh --check-paths` on the staged paths (working-tree copies — the normal export is `git archive HEAD`, useless pre-commit). Fix by adding the literal to `scripts/public-scrub-map.txt`, not by rewording. ~2s. |
| `git-commit-ticket-gate.sh` | `Bash`/`PowerShell` | A `git commit` (any repo except `~/.claude`, which has its own separate gate) whose message doesn't start with `PROJ-XXXXX:` — see "Commit & ticket discipline" below. **The `~/.claude` exclusion is resolved by link, not by name**: `readlink -f` the command's target dir and compare against the harness root, so every directory linked in from this repo (`skills`, `hooks`, `memory`, `Chat files`, …) stays gated while `~/.claude` itself — which resolves to itself — stays excluded, and personal content (`settings.json`, `plans/`, session state) is excluded for free. The old literal list (`skills`, `hooks`, `claude.md`, `harness-config.json`) is kept as a fallback so a `readlink` failure can't lose protection, but it was incomplete: `git -C ~/.claude/memory commit …` was real harness code going through ungated, while the same commit against `~/Repos/AMA_APP/ama-claude-harness` was gated — two paths to one file disagreeing about why. Chosen over `git rev-parse --show-toplevel` (also verified to work) because this hook's own header optimises forks at ~60ms each. Only reads a message from `-m "..."` or the `-m "$(cat <<'EOF' ...)"` shape; **the heredoc must be attached to `-m`**, since matching a bare `<<MARKER` anywhere in the command made any write-a-file-then-commit call self-trip (a `cat > msg.txt <<'MSG'` + `commit -F msg.txt` read the message file's first line as the message; a `cat > script.sh <<'EOF'` + `bash script.sh` reported the message as `set -u` and matched a `git commit` that was only script *text*). **`-F` is read too**: a heredoc attached to the commit (`git commit -F - <<'EOF'` — a *different* parse from the `-m` form, marker trailing the args rather than glued to the flag) and a readable `-F <file>` both yield a message and get checked — including one written `-F "$HOME/…"`, whose literal prefix is expanded the same way `target_dir` already was, since the hook sees the command *un*expanded and that is how this repo's own commands write paths (without it, the more natural of the two file shapes fell straight back through to fail-open). A message piped in (`printf … | git commit -F -`) is the hook's **one deliberate non-fail-open branch** — DENIED with a reason naming the shape, since the text exists nowhere in the command, can't be checked now and can't be reconstructed later. That bypass was total and live: a ticket-less harness commit to `skills/` landed through it (the only such commit in this repo's history) while the very next commit, same kind but with `-m`, was correctly denied — enforcement can't depend on which flag the agent reaches for. Extraction is always tried before denial, because `--amend -F -` with an attached heredoc is the documented workaround for PowerShell here-strings mangling a subject (`bash-command-style`). Everything else — `--amend --no-edit`, `-c`/`--fixup`/`--squash`, an editor commit, an unlocatable `-F <file>`, a conflicted-merge conclusion — extracts no message and still fails open by design: each reuses an already-gated message or puts a human in the loop, and an unfindable file is ambiguity rather than concealment. **Heredoc bodies are stripped before the simple `-m` scan too** — a command that writes a script via heredoc and then runs it has `-m "..."` text inside that body, which was read as the real commit's message (three false denials on 2026-08-18 before both halves were fixed). `ticket-worked-while-open-gate.sh` covers the shapes this one can't parse, by reading the actual commit. |
| `master-push-direct-gate.sh` | `Bash`/`PowerShell` | A `git push` to `master` whose outgoing commits include non-merge commits reachable from no `hotfix/*`/`release/*` ref — out-of-cycle production changes ride a hotfix branch (`ama-hotfix`), master only receives `--no-ff` merges. `~/.claude`/`ama-claude-harness` excluded (they live on master). Also excludes `api-testing`/`ui-testing` by toplevel dirname — single-branch, no-PR, no-production-runtime test repos per `ama-api-tests/SKILL.md`, where a direct master push IS the only workflow, not an out-of-cycle production change (added 2026-08-25 after the gate blocked PROJ-15340's `api-testing` fix). See "Commit & ticket discipline" above. |
| `octopus-lambda-delete-gate.sh` | `Bash`/`PowerShell` | A `POST .../Spaces-N/deployments` with no `aws lambda delete-function` recorded this session — deploying over an existing Lambda can leave the OLD code running while Octopus reports Success and `LastModified` moves (cost ~40 min re-diagnosing an already-correct fix, 2026-08-17). Non-Lambda target → prefix `OCTOPUS_TARGET_NOT_LAMBDA=1`. Same file wired `PostToolUse --record` to remember the delete (2h window). See `ama-octopus-deploy`. |
| `skill-bloat-gate.sh` | `Edit`/`Write` | A `skills/*/SKILL.md` paragraph containing "confirmed real" that exceeds ~35 words — mechanical backstop for `write-a-skill`'s own anti-narrative rule. |
| `skill-model-tiering-gate.sh` | `Edit`/`Write` | A `skills/*/SKILL.md` with no `model:` frontmatter. Warn-only, never denies. Honors `SKILL_MODEL_TIERING=off`. |
| `standup-empty-section-gate.sh` | `Edit`/`Write` | Writing a `standup-notes-<date>.md` whose "Couldn't summarize", "Client mail", "Decisions", or "Action items" heading has no real bullet under it (`None`/`N/A`, or a bare heading) — an unearned empty section is a false all-clear; empty "Action items" reads as "no outstanding commitments" when the truth is the Zoom fetch or ledger read failed. `ama-standup-notes`'s own rule: omit the heading entirely. Each heading is checked **separately** — one pass would stop at the next heading, letting a populated section mask an empty one. Only reaches the unattended path because `standup-unattended-run.sh` grants `Write`; withhold it and the run writes by `Bash` redirect, firing no hook. Also denies a **bare movement bullet** (`- **PROJ-N** …` with no indented line beneath it before the next bullet/heading) — third bare-label defect in this skill in two days (2026-08-21); Step 4a's fallback is the ticket's Jira summary. |
| `running-script-edit-gate.sh` | `Edit`/`Write` (+ `Bash`/`PowerShell` `sed -i`/`perl -i`) | Editing a `.sh`/`.ps1`/`.pl`/`.py`/`.js` whose basename appears on a LIVE interpreter process's command line (`Get-CimInstance Win32_Process`, bash/sh/perl/python/node/pwsh only, so an editor holding the file open never trips it). Bash reads scripts lazily, so an edit mid-run corrupts that run (`command not found` / `syntax error near unexpected token` at a line that is fine on disk) — hit 4× in one week: `check-gates.sh` edited by a concurrent session mid-suite, `standup-unattended-run.sh` edited during its 15-min headless run. ~0.5s PowerShell spawn, paid only for script targets; fails open if the process list can't be read. `RUNNING_SCRIPT_CMDLINES` is the test seam. |
| `symlink-write-gate.sh` | `Edit`/`Write` | Writing to a `~/.claude` path that resolves elsewhere — these are symlinks/junctions into this repo and Edit/Write can't write through them. Fires BEFORE the tool's own generic refusal and hands back the resolved real path, so the retry lands first try. Shell counterpart: `inplace-edit-gate.sh` above. |
| `native-memory-gate.sh` | `Edit`/`Write` | Writing to Claude Code's native `~/.claude/projects/*/memory/` store — durable memory belongs in this repo's git-tracked `memory/` instead (that store is gitignored and scoped to one cwd hash). See the `harness-memory` skill. |
| `claude-dir-clutter-gate.sh` | `Edit`/`Write`, `Bash`/`PowerShell` | Creating a NEW entry directly at the ~/.claude TOP LEVEL (Edit/Write `file_path`, or a Bash/PowerShell redirect/`touch`/`mkdir`/`mv`/`cp`/`tee`) — a path already nested one or more levels down is always allowed, regardless of which subdirectory. PROJ-15342: `~/.claude` accumulated ~90 files that didn't belong there because no policy said where hook state or scratch notes should go, and it's a git repo pushed to a personal GitHub remote — other sessions had already staged >20 of them for commit before this gate existed. See "Where harness state lives" below. |
| `confluence-media-gate.sh` | `updateConfluencePage` | A `contentFormat="html"` body write to a page listed in `.atlassian.pagesWithNestedMedia` — the HTML→ADF converter silently drops a `<figure data-type="media-single">` nested inside a `<li>`, so such a page loses its image on EVERY html write: body written faithfully, version bumped, image gone, no error. Confirmed live 2026-08-17 on the AMA Backlog page (v88 destroyed it, v89 restored it via ADF). Write the body as `contentFormat="adf"` instead; recovery path in `ama-confluence-api`. Inert when the config list is empty. |
| `slack-brevity-gate.sh` | `slack_send_message`/`_draft`/`slack_schedule_message` | Two Slack message rules (the filename predates the second). **(a)** over 120 prose words — standing user instruction 2026-08-18, every Slack message uses as few words as possible; the DM that prompted it ran ~250 words of background the recipient already had, its accepted rewrite ~50. Fenced blocks and inline-code spans are excluded from the count. **Stand-up notes get a raised 250-word ceiling**, keyed off an `Updates from me:` line **within the first 3 lines** (a configurable per-audience greeting — `standup.notifyGreetings`, e.g. "<team>" — sits above it; 3 lines is exactly greeting + blank + header). Rule (a)'s premise is "drop background they have", which is false for the stand-up's audience (Reviewer One/Reviewer Two have no context on Your Name's work), and compressing to bare labels made a real note useless 2026-08-21. The discriminator is deliberately the note's own visible opening rather than a hidden flag — so yes, a long message could claim the ceiling by carrying that line; accepted knowingly, single-user harness, do NOT "tidy away" as a loophole. Must be a line of its own, so the phrase leading into prose keeps 120. Boundary pinned both sides in `check-gates.sh` (250 pass / 251 deny) with and without the greeting, plus buried-header and mid-sentence cases so the anchor can't loosen silently. **The greeting's own words count** — sizing a test at 253 would deny under both ceilings and prove nothing, so those fixtures are deliberately sized to 250. **(b)** 3+ addresses in a list not individually backticked — Slack renders each `` ` `` span as its own chip, so per-item backticks give an orderly row; bare text runs together and ONE span around the whole list becomes a single wide chip (both denied). Scoped to lists: one or two addresses in prose pass, a lone inline `sg-…` id passes, a fenced block passes. Rule and rationale in `memory/slack-messages-terse.md`; Jira comments and replies to the user are explicitly NOT in scope for either rule. **A THIRD raised ceiling (also 250) exists for the `<amaSupportChannelName>-notices` Phase 1 triage DM**, keyed off a `Support notification triage:` line on **line 1 only** (no greeting sits above this one). The two 250-word ceilings share a numeric value but are NOT interchangeable in the deny reasoning — a `limit_kind` variable (`standup`/`support`/`default`) picks the right explanation text, because comparing the numeric `$limit` alone can't tell the two apart (caught live 2026-08-21: the support-triage branch silently printed the stand-up's wording until `limit_kind` was added). |
| ~~`slack-signature-gate.sh`~~ | — | **RETIRED 2026-08-25.** Went through two premises, both wrong: (1) Slack never auto-signs any send — false, an interactive send got a duplicate footer live. (2) Slack auto-signs interactive only, never headless — also false, a controlled 3-send headless test duplicated 2/3 times under identical conditions. Real behavior: Slack/the connector auto-adds `Sent using <@U0ATAGGGBT2\|Claude>` in BOTH interactive and headless sends, unreliably (not tied to any signal this harness can read). Typing the line manually now mostly guarantees a visible duplicate instead of occasionally preventing a missing one — worse trade-off than doing nothing. Standing rule now: **never type the signature manually, anywhere** — accept the rare unsigned send as the lesser cost. Hook deleted, wiring removed from both settings files, `check-gates.sh` coverage removed. See `harness-gaps.md`'s closed entry on this for the evidence trail. |
| `audience-policy-gate.sh` | Gmail draft/send + Slack `slack_send_message`/`_draft`/`slack_schedule_message` | Nothing — it **injects** the resolved audience policy as `additionalContext` and emits no `permissionDecision` at all (an `allow` would risk overriding `clientcorp-cc-horia-gate.sh`'s ask on the same call). Depth per addressee is config data in `.audiences`; level = MIN across `to`, `avoid` = UNION, `cc`/`bcc` deliberately ignored. Prompt-time counterpart `audience-policy-check.sh` runs inside `on-prompt.sh` and is the half that can still shape a first draft. See `memory/audience-communication-levels.md`. |
| `hotfix-number-comms-gate.sh` | Gmail draft/send + Slack `slack_send_message`/`_draft`/`slack_schedule_message` | A message naming a hotfix NUMBER — standing user instruction 2026-08-21: say a fix went out as a hotfix, never which one. Trigger is a dotted version ADJACENT to `hotfix`/`hot-fix`/`HF` (optional `release`/`version`/`branch`/`build`/`v` between), across Slack `message` and Gmail `subject`/`body`/`htmlBody` — subject deliberately in scope. "A hotfix", "two hotfixes", and a version in a later sentence all pass; that last one is the accepted recall limit, since matching any bare `X.Y` would false-positive on dates and ticket numbers. Jira comments, Confluence, release notes, commit messages and branch names are NOT in scope and keep the version. Rule in `memory/hotfix-number-not-in-comms.md`. |
| `jira-ticket-fields-gate.sh` | `createJiraIssue` | Ticket creation where assignee doesn't match your own cached `jiraAccountId` — see "Commit & ticket discipline" below. |
| `harness-ticket-gate.sh` | `createJiraIssue` | Creating any new ticket whose Epic Link is <harnessEpicKey> — harness work never gets its own sub-ticket, see "Commit & ticket discipline" below. |
| `jira-fixversion-confirm-gate.sh` | `createJiraIssue`/`editJiraIssue` | Tagging a `release/*`/`hotfix/*` Fix Version before it's confirmed via `confirm-jira-version.sh` — see "Commit & ticket discipline" below. |
| `prod-api-test-window-gate.sh` | `Bash`/`PowerShell` | Triggering either PRODUCTION `<repository>-api-testing` pipeline (`"pattern":"production"`, which also prefix-matches `production_exports`) inside the blocked window: **Mon–Fri 9am–5pm ET**, the standing user instruction `ama-deploy-release` Step 5a carries. ET comes from python's `zoneinfo`, never `TZ=` — git-bash ignores `TZ` here, so Step 5a's old "trust the hour" advice was wrong by 4 hours and would have fired both production suites at 12:34 ET. **Alone among the externally-dependent gates it fails CLOSED**: an unresolvable clock, or an ET reading identical to UTC, denies — treating "couldn't read the time" as "go ahead" *is* the original defect. Escape hatch is `AMA_ALLOW_PROD_API_TESTS=1`, deliberately a var the user sets, never a side effect of following the skill (the deadlock lesson from `hotfix-version-claimed-gate.sh`). |
| `graylog-write-gate.sh` | `Bash`/`PowerShell` | Two denials. **(a)** a hand-rolled `curl -X PUT/POST/DELETE` against `/api/system/pipelines/...` — forces the write through `skills/ama-graylog-search/scripts/graylog-rule-write.sh`/`graylog-pipeline-attach-rule.sh`, which back up the current rule/pipeline and parse-validate the new source (`/rule/parse`, persists nothing) before writing; a raw curl skips both, and a typo'd title silently detaches a rule from its pipeline (stage refs are BY TITLE, see `PIPELINE-RULES.md`). The validate-only `.../rule/parse` endpoint is excluded — it never persists anything. **(b)** ANY Graylog pipeline write attempt from a headless `claude -p` run, sanctioned script or raw curl alike — no unattended monitor should mutate production alerting unsupervised. Detects headless via `session_is_headless` (`hooks/lib-session-kind.sh`, shared with `notify-sound.sh`'s headless-ding fix and the session-list suppression — never hand-roll the entrypoint read: a `head -c 4000` copy of it silently matched nothing for days); fails OPEN if the entrypoint can't be read, since rule (a) is the real backstop. Built alongside the harness's first Graylog write capability, <harnessEpicKey>. |
| `mongo-write-gate.sh` | `Bash`/`PowerShell` | Mongo WRITES — `ama-mongo-access` tunnels with the app's own read-write creds and no DB-level safety net (`docdb-query.sh`'s header says so), so until this gate read-only was convention, not enforcement. Write-shaped evals (`.updateMany(`, `.drop(`, aggregate `$out`/`$merge`, `mongoimport`/`mongorestore`, full list in the gate) against `docdb-query.sh production` → **deny**, hatch `AMA_ALLOW_PROD_MONGO_WRITE=1`; any other Mongo write (qa/staging, raw `mongosh`) → **deny**, hatch `AMA_ALLOW_MONGO_WRITE=1` (does NOT unlock production). Both hatches user-set, same lesson as `prod-api-test-window-gate.sh` — and deliberately deny-plus-hatch, NOT `ask`: the hatch re-run works identically in every permission mode and leaves the exact approved command in the transcript, which for a data mutation is the audit trail. Method match requires `(` right after the name (a collection *named* `updates` passes); reads never blocked; heredoc bodies exempt. |

Wired in `settings.template.json`'s `hooks.PreToolUse` (merged into your real
`settings.json` by `scripts/install.ps1`) — that file is the source of truth for the
exact matcher/command/timeout for each; this table is the map, not a duplicate of it.
**One group per event+matcher** — new hook on an existing matcher goes INTO that group.
install.ps1 merges by matcher into the first match, so a 2nd group re-duplicates live on
every re-install (hook fires twice). `scripts/check-settings-parity.sh` flags repeats.

## Comms & session hooks — detail (moved 2026-08-31 from AGENTS.md, where they sat misfiled under "AMA UI verify skill")

**`gmail-reply-thread-reminder.sh`** (`PostToolUse` on `mcp__.*__(create|update)_draft`):
tells you to confirm via `list_drafts` that a reply draft's `threadId` is the intended thread.
Two separate traps, both confirmed live:
- `create_draft` with `replyToMessageId` pointing at an **inbound** message put the draft on a
  brand-new thread, detached from the chain (2026-08-18; the response returns only `{id}`, so
  nothing surfaced it and the user caught it). Target the thread's LAST message — usually our
  own most recent sent one. Silent on new-thread drafts by design.
- `update_draft` **DETACHES** a correctly-threaded reply draft: changing only the body
  re-created it as its own thread, `threadId` == its own `messageId` (2026-08-19, and again
  2026-08-20 by a session that had the warning in `gmail-drafting` and still hit it — which is
  why it is now a hook and not just prose). There is no reply-target field on `update_draft`,
  so a reply draft can never be updated in place: get the wording right before creating, or
  recreate. Nudges unconditionally — the payload cannot reveal whether the target is a reply.

Either way the fix is recreate-and-discard-the-stray, never update. Same nudge-not-verify
limit as the push reminder — hooks have no Gmail access.

**`gmail-draft-sig-gate.sh`** (`PreToolUse` on
`mcp__.*__(create_draft|update_draft|reply|forward)` — widened to `reply`/`forward`
2026-08-26, both are direct-send with no compose-UI auto-sig same as `create_draft`;
confirmed live, a `reply` to ClientCorp shipped unsigned because the old matcher missed it): two
signature invariants on an outgoing draft/send. **Denies** a body or `htmlBody` spelling the
company `SturctureIt` — the stored Gmail sig is CORRECT (user-confirmed 2026-08-20), so
that spelling proves the sig was lifted from a STALE sent message and the rest of the block
is suspect too; re-source it rather than patching the string (checks `forwardText` instead
of `body` for `forward`, which has no `body` field). **Asks** when `create_draft`/`reply`
`htmlBody` carries no `class="gmail_signature"` (API sends get no auto-sig, so it would
arrive unsigned) — not `forward`, whose own added text is commentary on someone else's
message, not a new message owing a full sig; and not `update_draft`, which patches a
subject/recipient with no sig by design, and a gate firing on ordinary work trains itself
away.
- Anchor is `class="gmail_signature"`, never `data-smartmail` — that attribute is present on
  sent messages but Gmail strips it when saving a draft, so keying on it false-negatives
  every time.
- `PreToolUse` is the only workable placement: `htmlBody` is visible in `tool_input` before
  the draft exists. Unlike the threading reminder above this one CAN decide for itself — the
  spelling and the anchor are both in the payload, no Gmail access needed.
- **The payload is pre-quote, and that is what makes the deny safe.** On a reply the
  `tool_input` holds only our own text; Gmail appends the quoted chain server-side, and that
  chain legitimately contains `SturctureIt` from older sent mail. Run the same check against
  a STORED `htmlBody` and it false-fails every reply on an old thread — which is exactly the
  mistake that produced a wrong diagnosis twice on 2026-08-20. When verifying a stored draft,
  compare BYTE OFFSETS against the first `gmail_quote`: matches before it are ours, matches
  after it are archived history. `gmail-drafting` carries the snippet.
- **Verify a stored draft on a STYLE marker, not on the class.** Gmail strips BOTH
  `class="gmail_signature"` and `data-smartmail` when saving an API-created draft (measured
  2026-08-20: sent `<div dir="ltr" class="gmail_signature" data-smartmail="...">`, stored
  `<div dir="ltr">`), so the class can only ever match inside a quote. Check
  `font-family:Arial` / `#888888` / `rgb(17,85,204)` instead — those survive and are what
  the reader sees. The gate is unaffected: it reads the payload, which still has the class.
  Corollary: source a sig from a SENT message, never a stored draft.
- Gmail also rewrites the sig link on save (`https://www.<tenant domain>/` →
  `https://www.google.com/url?q=...&source=gmail&ust=...`) in both bodies. Cosmetic, anchor
  text unchanged — and NOT a symptom of a plain-text sig path, though it was misread as one.

**`audience-policy-gate.sh`** (`PreToolUse` on Gmail
`create_draft|update_draft|reply|forward|send_message` and Slack
`slack_send_message|_draft|slack_schedule_message`) plus **`audience-policy-check.sh`**
(sourced by `on-prompt.sh`, `UserPromptSubmit`): how much detail an outbound message carries
depends on who is being addressed. Standing user rule from 2026-08-20 — see
`memory/audience-communication-levels.md`. Both **only inject** `additionalContext`; neither
denies nor asks, because no hook can judge tone and a gate that cannot fail is worse than none.
- **The people/role mapping is config data, not code**: `harness-config.json` `.audiences`,
  one `people` entry per correspondent with `level` (`business`|`<level>`), `avoid`, `notes`.
  The user asked for it to be configurable because people swap roles. Empty `people` → both
  hooks inert. Shared resolver `lib-audience-policy.sh` + the two `.jq` programs beside it.
- **Level = MIN across addressees, `avoid` = UNION.** "A combination of all of the above →
  business level" is a consequence of the min, not a hand-written fourth case, which is what
  makes a role swap a one-line config edit.
- **Only `to` counts — never `cc`/`bcc`.** Explicit user decision. `clientcorp-cc-horia-gate.sh`
  cc's one person on every ClientCorp mail, so counting cc would make EVERY such mail a "mixed
  audience" and collapse it to business level, muting the per-person rule for its real
  addressee. Pinned both directions in `check-gates.sh`; do not "simplify" it into reading cc.
- **The prompt-time half is the load-bearing one.** By the time `create_draft` fires the body
  is already written, so the gate can only inform the revision. `audience-policy-check.sh`
  fires before anything is composed — but only when the prompt both concerns a message and
  names a configured person, so a mention of a colleague in unrelated work stays silent.
- **Slack resolves a person only from a DM `channel_id` or an `<@U…>` mention** —
  `slack_send_message` carries no recipient list. A plain channel post resolves to nobody and
  says nothing, falling through to `slack-brevity-gate.sh`. Do not document it as more.
- **Same shape on mail**: a `reply`/`forward` with `replyAll:true`/no explicit `to` carries
  NO recipients in the payload — Gmail resolves them server-side — so `keys` comes back
  empty and this hook stays silent, same as an unresolvable Slack post. Accepted: this hook
  is the backstop, not the enforcement (see below); `clientcorp-cc-horia-gate.sh`'s unresolvable-
  recipients branch is the one that actually blocks on this shape, since it guards a
  compliance rule rather than a tone suggestion.
- **No `permissionDecision`, not even `allow`**: an explicit allow could override
  `clientcorp-cc-horia-gate.sh`'s ask on the same call. Asserted in `check-gates.sh`.
- Two bugs worth remembering, both found only by executing it: the native `jq.exe` here emits
  **CRLF**, so a key list piped between two `jq` calls silently lost every name but the last
  (a two-person mail resolved to one person, no error anywhere); and it has **no
  `--slurpfile`** (1.5rc1), so the config is read on stdin. The jq programs live in `.jq`
  files rather than shell strings because every attempt to carry them inline mangled an
  escape.

**`clientcorp-cc-horia-gate.sh`** (`PreToolUse` on Gmail
`create_draft|update_draft|reply|forward|send_message`): every mail with an `@client.example.com`
recipient must copy `<emailRecipients>`. Standing user rule from 2026-08-20,
whole ClientCorp side, not one thread — see `memory/clientcorp-cc-horia.md`. **Asks** rather than denies
(user's choice) so a deliberate exception costs one approval instead of a hook edit; approve
only when the user has said THAT mail is the exception.
- **Exempts the user's own `<secondaryEmail>` when it is the ONLY clientcorp address** — it
  is a real <one entry per line; this element only declares the type> address, so a plain domain test would fire on every note-to-self. A
  real colleague on the mail still triggers it even alongside `your.windows.username2`. Both
  directions are pinned in `check-gates.sh`; do not "simplify" the carve-out away.
- Checks `to`/`cc`/`bcc` (a bcc'd colleague is still a recipient) and is case-insensitive
  throughout — addresses arrive mixed-case. <name> in any of the three satisfies it.
- **Unresolvable-recipients branch (added 2026-08-26, confirmed live)**: `reply`/`forward`
  only need `messageId` — a `replyAll:true` reply carries NO addresses in the payload at
  all, Gmail resolves them server-side. That broke both guards: the raw-payload prefilter
  finds no `<one entry per line; this element only declares the type>` literal to trigger on, and `to`/`cc`/`bcc` all come back empty even
  if it did. A real reply-all to ClientCorp passed silently, no <name> cc, before this fix. Now,
  for `reply`/`forward` specifically, an EMPTY `to`+`cc`+`bcc` asks unconditionally before
  the raw prefilter runs at all — can't tell ClientCorp from not-ClientCorp from the payload, so ask
  rather than silently pass. `create_draft`/`update_draft`/`send_message` always carry
  explicit recipients in the sanctioned flow, so this branch is defense-in-depth there,
  not the expected path.
- Set the cc in the SAME call: `update_draft` detaches a reply draft, so a forgotten cc on
  a reply costs a full recreate rather than a patch.
- Why a gate at all: after commit `ce367ef` fixed the sig to be sourced as real HTML, 3 of 3
  drafts still carried `SturctureIt`, one of them with otherwise-perfect markup — the pairing
  a human eyeballing a rendered draft is most likely to wave through.

**`self-checkable-ask-reminder.sh`** (`Stop`): flags a reply that handed the USER a question
this harness can answer itself, appending a `SELF-CHECKABLE ASK:` line to `harness-gaps.md`.
Fires only when one paragraph pairs an ask-the-user phrase (`worth checking`, `you'll need to
check`, `cannot be determined from`, `not readable from`, `please check`…) with a
readable-system keyword (`octopus`, `variable set`, `task definition`, `ecs`, `graylog`,
`redshift`, `postgres`, `jira`, `confluence`, `pipeline`…). The co-occurrence requirement is
load-bearing: "worth checking" alone is far too common, and a mostly-noise nudge gets ignored
when it's real. Incident: a reply said the Octopus `yourproduct-blog-domain` value "isn't readable
from the repos" — true, but three read-only API calls answered it and inverted the severity
finding in the same reply. Reuses `check_unticketed_flag`'s paragraph-scan shape, and lives in
its OWN file rather than extending `on-stop.sh`, which routinely carries another session's
staged changes. See [[self-check-before-asking]] for the readable-surface list.

**`subagent-model-tiering-gate.sh`** (`PreToolUse` on `Agent`, warn-only, never denies) --
TWO checks in one hook (it is the only `Agent` hook; a second would double the per-spawn
fork cost): `model` tiering, and an explicit output-word-cap in the prompt:
reminds to tier the `model` param per `resource-efficiency`'s easy→haiku/medium→sonnet/
hard→omit mapping when a spawn omits it. Honors `SUBAGENT_MODEL_TIERING=off`.

**`skill-model-tiering-gate.sh`** (`PreToolUse` on `Edit`/`Write`, warn-only, never denies):
sibling of the above for the OTHER tiering lever — `model:` in SKILL.md frontmatter. Fires on
a `skills/*/SKILL.md` write with no `model:`, restating `resource-efficiency`'s whole-turn
rule (an inline `model:` applies for the rest of the TURN, so it is unsafe on anything that
can fire mid-task or via a `hooks/*-check.sh` nudge). Never denies because **untagged is the
correct answer for most skills** — same reasoning as its sibling.

**`SKILL_MODEL_TIERING=off` silences the WARNING only.** Unlike `SUBAGENT_MODEL_TIERING`, it
cannot turn a tier off: `model:` in frontmatter is applied by the CLI, not chosen by Claude.
Turning a real tier off means editing the frontmatter.

**`statusline.sh` also renders/notices context-window usage now**, not just the 5h/weekly
rate-limit windows — a `ctx:NN%` segment in the bar, plus a per-session (not
account-wide) one-shot `/compact`-or-`/clear` recommendation at 60%/80%, relayed by
`on-prompt.sh` from `.ctx-notices-<session-id>`. See the `context-hygiene` skill for the
full mechanism and what to do when it fires. The rate-limit windows are bar-only as of
2026-09-08 — their in-chat crossing notice (and the `usage-monitor` skill documenting it)
was removed as a stale duplicate of a live indicator; `statusline.sh`'s header has why.

## check-gates.sh fixture traps (moved 2026-08-31 from AGENTS.md)

**Assert the READ, not just the write.** A write-only case (`assert_writes`) proves a hook
fills a bucket, never that anything drains it — two `on-prompt.sh` relays sat dark for weeks
at a green suite (2026-08-11 → 09-03). Use `op_relay` in the `on-prompt.sh` section: sandboxed
`CLAUDE_STATE_DIR`, asserts text reaches injected context AND the one-shot file ends empty.
Gotchas: the payload **must** carry `cwd` (else `on-prompt.sh` exits early, silently — looks
exactly like a broken relay); pre-create `notices/.nudge-checks-lastrun` so `_nudge_due=0`
skips the six sourced cadence checks (network, dozens of forks).

**A reusable trap hit writing that suite's own fixtures**: a test that must trigger
`publish-scrub-gate.sh`/`publish-public.sh`'s forbidden-token detection at RUNTIME
(writing a deliberately-offending string to a scratch file) cannot write that literal
directly into `check-gates.sh`'s own source — `check-gates.sh` is itself exported to the
public mirror (not in `publish-public.sh`'s `excluded_from_export`), so the literal
would abort a commit of the test file itself, at the source-text level, regardless of
what the runtime test does. Split the literal across a shell variable concatenation
instead (`_frag1="compute-1"; _frag2="amazonaws.com"; printf '...%s.%s...' "$_frag1"
"$_frag2"`) so the source never contains the contiguous forbidden substring while the
runtime-assembled string still does. **Do NOT "fix" this by adding the literal to
`public-scrub-map.txt`** — tried live 2026-08-21, and it silently broke the two tests
that rely on that exact string being detected (mapping it away scrubbed the runtime
fixture too, turning "must be flagged" into a false pass). Also confirmed live the same
day: `public-scrub-map.txt`'s existing `ec2-*.<region>.compute.amazonaws.com` "generic
placeholder" entry is dead code — `scrub.pl` quotemeta's the whole literal, so its `*`
matches only a literal asterisk, never a real hostname; a true wildcard would need real
support added to the scrub engine, not another map line.

**`check-gates.sh` must never read live, mutable state it does not own** (2026-08-28). Two cases
failed a real run — `extra map ENTRIES are not drift` and `identical live/example raise
nothing`, both `want=pass got=block` — and neither was a bug in the gate they named. The
config-parity block handed `config-key-parity-reminder.sh` the **live**
`$HOME/.claude/harness-config.json` while its `setup.md` shim was a snapshot taken once at
block start, so a concurrent session editing the live config mid-run made the two disagree
and `missing_setup` fired. Evidence: both cases pass in isolation against the same gate, and
the config's mtime (`10:33:36`) plus the gate's own (`10:36:36`) both land inside the run
window (`10:25:35`–`11:06:31`). Fixed by copying the live config to `$CBASE/live.json` once
and pointing every case at the copy. This is the same hazard `running-script-edit-gate.sh`
and the suite's private-copy-of-itself trick already cover, one level out: those protect the
script being *executed*, not the files it *reads*. Any new `check-gates.sh` case reading
`~/.claude` state should snapshot it into the case's own `mktemp -d` first — **keeping the
original basename**. Naming the snapshot `live.json` cost a red run: the gate's first
precondition is `case "$file_path" in */harness-config.json)`, so it exited on every case,
the two `want=block` cases failed and the two `want=pass` cases went green *for the wrong
reason* (silent because the gate never ran). A fixture rename can silently disarm a gate whose
trigger is its filename.

**`publish-scrub-gate.sh`'s deny case stages into a private index** (2026-08-28), via
`GIT_INDEX_FILE` seeded from `git read-tree HEAD` and exported around the `assert`. It used
to stage into the shared index and **skip whenever any session had files staged** — which
silently retired the only case in that block capable of failing, the exact "case cannot fail"
state the block's own comment warns about; it skipped on a real run. Seeding from HEAD
matters: an empty index reports every tracked file as deleted alongside the probe. Export it
explicitly rather than as a `VAR=x assert …` prefix — `assert` is a shell function, and an
env prefix there is not reliably visible to the grandchild process running the gate. No
`git reset` afterwards: the shared index is never written.

## Commit & ticket hooks — full detail (moved 2026-08-31 from AGENTS.md "Commit & ticket discipline")

AGENTS.md keeps the terse map; incident history and edge cases below and in each hook header.

- **Mechanically enforced, not just self-policed:** a `PreToolUse` hook blocks any `git commit` outright (any repo except `~/.claude`, which has its own gate below) if the message doesn't start with `PROJ-XXXXX:` — this isn't Claude choosing to follow the rule, the commit itself fails. Real gap this closed: a session once committed and pushed across 13 repos with zero ticket ref, the skill simply never got consulted.
- **Applies to `~/.claude` itself, too:** its auto-commit hook won't commit any change touching `hooks/` or `skills/` without a ticket resolved first (routine bookkeeping — chat logs, `sessions.txt` — stays frictionless). Resolve one, then run `set-session-ticket.sh` to unblock it. `hooks/`, `skills/`, `CLAUDE.md` actually live in this separate `ama-claude-harness` repo (junctioned back into `~/.claude`; `harness-config.json` sits there too but is untracked — it syncs via Octopus, not git) — `on-stop.sh`'s `auto_commit_push_harness` job auto-commits+pushes there too, same ticket gate, once `set-session-ticket.sh` has recorded <harnessEpicKey> for the session. **It stages only this session's own paths** (2026-08-28; was `git add -A` then unstage-the-rest, which twice swept a concurrent session's half-applied WIP onto master and nearly committed 19 chat-log symlinks): the path set is the session transcript's `Edit`/`Write` targets, `:(icase)` because they are lowercase-normalised, and the sha256 sidecar check (`harness-edit-hash.sh`) still runs after as the backstop.
- **`on-session-end.sh` prunes `.session-chatfiles/`** (2026-08-28): entries older than 30 days whose session has no transcript left are deleted at any clean exit — ~380 files had accumulated with nothing deleting them. Own session and suite-probe files are never touched.
- **New-ticket assignee mechanically gated** (`jira-ticket-fields-gate.sh`, `PreToolUse` on `createJiraIssue`): denies creation unless `assignee_account_id` matches your own cached `jiraAccountId` (not just non-empty — a wrong/stale/hallucinated GUID used to pass silently). Epic Link is no longer mandatory here — forcing one onto a plain bug with no natural epic just got worked around (fake epic, then stripped) instead of fixed.
- **New-ticket description mechanically gated** (`jira-ticket-description-gate.sh`, `PreToolUse` on `createJiraIssue`): denies creation unless the description has an "acceptance criteria", "how to test", and either "how to reproduce" (Bug) or "requirements" (everything else) section — checks presence only, any wording/heading style. Template + example: `commit-ticket/TICKET-TEMPLATE.md`. `jira-create-issue.sh` now posts `description` to `/rest/api/2/issue` (wiki markup, e.g. `h2.`/`*`/`#`) instead of v3 — confirmed live that this instance round-trips wiki markup as markup, not ADF; create through that script, not MCP `createJiraIssue`, or headings render as literal text.
- **Harness work never gets its own ticket** (this rule flip-flopped twice before settling here): every harness change commits directly against **<harnessEpicKey>**, no status transitions, no comments — `AGENTS.md` updates only (`README.md` too, but only when the change is human-visible — see below). `harness-ticket-gate.sh` (`PreToolUse` on `createJiraIssue`) mechanically denies creating any new ticket whose Epic Link is <harnessEpicKey>, so this can't silently drift back a third time. **The doc-currency half is now also mechanically enforced** — see `readme-currency-gate.sh` below.
- **Recent regressions route to one generic ticket** (`atlassian.regressionsTicketKey` in `harness-config.json`, currently **<regressionsTicketKey>**), instead of a fresh ticket per fix — a live search on "Regressions" previously turned up 40+ individually-filed one-off tickets nobody revisits. "Recent" = the regressed behavior belongs to a feature/change that shipped within roughly the last 3 releases (resolved live against Jira's version list, never hardcoded). If the specific causing ticket IS identifiable, the existing reopen-that-ticket rule still wins over this one. Genuinely unsure whether a fix qualifies → Claude asks, rather than guessing either way. Like <harnessEpicKey>, this ticket never transitions status, never gets a Fix Version, never gets a per-fix comment — but unlike the harness epic, it's a plain **Bug** parked at **Open** (not In Progress), so it stays out of the "what am I working on"/pickup queries permanently. See `commit-ticket/SKILL.md`.
- **`AGENTS.md` currency mechanically enforced** (`readme-currency-gate.sh`, `PostToolUse` on `Edit`/`Write`): the moment a harness `hooks/`/`skills/` file is edited, greps `AGENTS.md` for that file's name and blocks with the matching line numbers if found, so the description can be checked/updated on the spot instead of silently going stale. A new untracked hook/skill with no `AGENTS.md` mention blocks too, prompting a bullet to be added. Small edits (≤4 changed lines) are suppressed until they accumulate past 5, and at most one nudge per file per session — `on-prompt.sh` resurfaces any still-outstanding nudge on every later turn until `AGENTS.md` itself is touched, so it can't be silently dropped mid-task. If the check concludes no change is actually warranted, run `readme-nudge-ack.sh <key> <session-id>` to clear that nudge instead of forcing a hollow edit — the gate's block text and the `on-prompt.sh` relay both print that exact command (with key and session id filled in) since 2026-08-27, after a session verified AGENTS.md was current and then got nudged on every prompt for the rest of the day because nothing had told it the ack existed. **`README.md` (human-facing) is a separate file, deliberately outside this loop** — editing it never clears an `AGENTS.md` nudge, and a dedicated `human-readme-edit-gate.sh` (`PostToolUse` on `Edit`/`Write`) instead reminds that it updates only when human-visible behavior changed.
- **Adding a `harness-config.json` key means THREE files, mechanically enforced** (`config-key-parity-reminder.sh`, `PostToolUse` on `Edit`/`Write`): live config, `harness-config.example.json`, and `harness-setup/SKILL.md`'s enumerated keys. `releaseNotes.greetingNames` shipped live and was in neither, so an adopter would first meet it as an ask-the-user prompt mid-way through drafting a client-facing release email; the rule was written down and still missed, which is what makes it a hook. Checks **both directions** since 2026-08-28: live-only keys (adopter files blind) and example-only keys (the live config silently lacks something the schema has — it was one-way, and `aws.redshiftClusterId` sat missing live unflagged). Two deliberate narrowings, both found by running it: paths truncate at the first non-identifier segment, so entries of a data-keyed map (`greetingNames` is keyed by email) count as one key rather than reporting each person by name; and the `harness-setup` half checks TOP-LEVEL keys only, since the skill enumerates config in prose sections. Unnarrowed it produced 19 findings for 2 real gaps — a nudge that fires on everything gets trained away. It found `embs` on its first run: shipped in the example config, never asked for by `/harness-setup`. `CFGPARITY_LIVE`/`_EXAMPLE`/`_SETUP` override the three paths for tests only.
- **Column/status queries default to your own tickets** — "what's in review" (or similar) implicitly adds `assignee = currentUser()` rather than asking every time; only drops that filter if you explicitly ask for everyone's/the whole team's tickets.
- **Push-triggered status reminder** (`git-push-ticket-reminder.sh`, `PostToolUse` on `Bash`/`PowerShell`): nudges Claude to check/transition the session's ticket after a push to `master`/`develop`/`release/*`/`hotfix/*` — it prompts a check rather than verifying, and it can't de-dupe (it has no record of whether the transition already happened). Not because hooks can't read Jira — they can (`ATLASSIAN_API_TOKEN` + `harness-config.json`'s `.atlassian.cloudId`/`.user.email`; `ready-to-test-regression-reminder.sh`'s `ready_to_test()` is the working precedent) — but because this hook derives the target status from the pushed BRANCH, which needs no API call. Harness work is exempt twice over, because the session ticket alone isn't enough: a harness commit made *during* a product-ticket session leaves the session ticket at the product key, so the pushed commit's own `PROJ-` ref is checked against `atlassian.harnessEpicKey` as well (fired wrongly once — session on 15307, commit on 15106, nudge said move the mid-investigation 15307 to Test Complete). Since 2026-08-28 the nudge names the tickets **in the pushed commits** (`origin/<branch>@{1}..HEAD`, every `PROJ-` key, harness epic dropped; last-20-subjects fallback when the remote ref has no reflog yet; session ticket only if none found) — it used to interpolate the session ticket, so pushing 15330's commit said "move 15317". Several tickets → each named, with the caveat that only fully-delivered work moves. Hermetic suite case with a fixture repo. Since 2026-08-28 the session-ticket file (`.session-chatfiles/<sid>.ticket`) is a **fallback, not a precondition** — it used to open with `[ -f "$TF" ] || exit 0`, which silently switched the whole hook off whenever `set-session-ticket.sh` hadn't run yet, and it routinely hasn't: that script resolves the session by *chat filename*, Claude Code auto-renames the chat log mid-session, so the first call fails and the retry lands late. PROJ-15330 is the case that exposed it — `.ticket` written 14:23, all nine `develop`/`master` pushes 13:48–14:14, not one nudge, ticket sat In Progress for two days until the user asked why. The tickets it names come from the pushed commit subjects anyway, which are always present, so the file's absence was never a reason for silence. Harness-epic exemption now guards on a non-empty ticket, and a push naming no key at all exits quietly instead of nudging about an empty string; both have suite cases.
- **`set-session-ticket.sh` prints the chat filenames on record when it can't match** (2026-08-28). It resolves the session id by matching the chat filename it's given against `.session-chatfiles/` state, and exits 1 on no match — previously with nothing but the name that failed, so the only recovery was a guess, and in practice the call got deferred rather than retried (see the push-reminder entry above for what that cost). The error now lists the names it did find, making the retry one step. It does not attempt to auto-pick: several sessions can share a chat name, and silently tying a ticket to the wrong session is worse than a failed call.
- **Ready to Test: regression is Claude's check, the comment is for the tester; routing is blast radius not UI-testability** (user instruction 2026-08-21, refined 2026-08-26 after PROJ-15312 got an 1800-char regression essay nobody could test from the UI). A ticket whose change has anything downstream of it goes to **Ready to Test** even with no click path (its testing steps become a log/DB/API check); only a change nothing consumes goes straight to Test Complete. Then: judge regression risk from the diff. Low → nothing (no check, no comment). High → Claude EXERCISES the affected surfaces in session (`ama-ui-verify` on Staging, or Graylog/Postgres/Mongo for a non-UI surface); a SEPARATE regression comment only if the UI tester (`ama.uiTesterName` in `harness-config.json`) can run it from the UI — UI ticket or API ticket with a visible UI effect — and then brief: ≤5 one-line steps, no narrative. Not UI-testable → one "Regression: checked a, b; nothing found" line inside the testing-steps comment. Canonical mechanics: `ama-hotfix` Step 2a item 3; restated by `ama-cut-release-branch` Step 3a and `commit-ticket-jira`'s transition table; rule in `memory/ready-to-test-regression-comment.md`. Brevity mechanically enforced by **`regression-comment-brevity-gate.sh`** (`PreToolUse` on `addCommentToJiraIssue` + `Bash`/`PowerShell` invoking `jira-add-comment.sh`): a comment mentioning "regress" over 800 chars or 6 step lines → **ask**, never deny, since no hook can judge whether THIS ticket warrants the length; script-path text comes from the fixed payload file, which `Write` lands before the Bash call so PreToolUse can read it, and a missing file is silent. `jira-edit-comment.sh` (`ama-jira-api`) was added alongside to trim an existing comment in place (v2 PUT, plain text). Backstop: **`ready-to-test-regression-reminder.sh`** (`PostToolUse` on the Jira comment/transition MCP tools plus `Bash`/`PowerShell`) — fires on a testing-steps comment landing, and on a transition **after asking Jira what the status now is** — deliberately NOT by matching transition id `10171`, which is the id of the Ready to Test *status*: real transition ids on this board are 2-3 digits (`231` PR Review, `261` Done) and are per-ticket, so an id match would have looked right and never fired once (caught before shipping; positive path verified live 2026-08-21 on PROJ-15317). That read is a 3s read-only GET that fails open — no token, offline, or timeout means silent, with the comment trigger still covering. It is self-suppressing (text already mentioning "regress" stays quiet). Reminder only, never a `permissionDecision`: no hook can judge whether the investigation was thorough. Comment text for the script path comes from `~/.claude/harness-state/tickets/.jira-write-payload.json`, and an unreadable payload still nudges. The Bash branch matches an *invocation* of `jira-add-comment.sh` (script path followed by a ticket key), not the filename anywhere in the command — a `sed -n … jira-add-comment.sh` read fired it twice on 2026-08-26.
- **Cross-session shared-clone guards** — every session shares **one local clone per repo**, so `git checkout` is global state: whichever session switches last wins, silently, for everyone. Nothing knew another session existed until 2026-08-18 (52 repos, 5 parked off default; two sessions two minutes apart in the same clone root; 9 of 58 plan files recording another session's ownership as if durable — one of them about a hotfix that had already shipped). Three pieces, all **warn-only, never deny** — a stale claim must never wedge an urgent hotfix:
  - `hooks/lib-session-liveness.sh` — `session_is_live <sid> [max_age=600]`, from the session's own **transcript mtime** (`~/.claude/projects/**/<sid>.jsonl`). Extracted from `log-session-start.sh`, the only liveness test that existed. Chosen because Claude Code writes that file *without the session cooperating*: this harness has no reliable session end, so a heartbeat nobody updates or a lock nobody releases would strand repos forever. `CLAUDE_PROJECTS_DIR` overridable for tests.
  - `hooks/lib-repo-claims.sh` — `~/.claude/.repo-claims`, one TSV row per repo (`repo\tsid\tbranch\tepoch`): *who was last seen where*, **not a lock**. Deliberately **one self-pruning file**, because `.session-chatfiles/` already holds ~380 files nothing deletes and `on-prompt.sh:77-83` records that scanning it once blew the 30s hook budget. **No lock:** a lost update costs one missed warning; writes are atomic (temp + `mv`), the only corruption that would matter. Keys go through `claims_repo_root`, which resolves via `git rev-parse --show-toplevel` — hand-building a key from a `/c/...` path won't match, git normalises to `C:/...`.
  - `hooks/cross-session-repo-claim.sh` (`--record` PostToolUse + PreToolUse gate) — warns on a checkout/switch in a repo another **live** session holds on a different branch (one working tree, so the switch moves *theirs*); on HEAD no longer matching the branch this session last acted on (**committing onto another session's branch** is the worst outcome, and it's detectable locally with no network); and on both sessions holding `hotfix/*` in the **same repo**, which is exactly Octopus Hotfix-channel contention — contention is per Octopus *project*, so same-repo is the precise condition and **no API call is needed**; a cross-repo hotfix does not contend and must not warn.
  - `hooks/lib-file-claims.sh` + `hooks/file-claim-record.sh` (PreToolUse `Edit|Write`) — the same idea one level finer: `harness-state/sessions/.file-claims`, one TSV row per (path, sid), *which session last edited which FILE*, again **not a lock**. Read back by `cross-session-repo-claim.sh` as its **second check**, which warns **only at `git commit` / `git add -A`** — the raw collision rate is ~150 same-file/different-session pairs a week and almost all are harmless, so an edit-time warning would be ~150 interruptions for the two that actually cost work (both commits, 2026-09-01). Two departures from house style, both deliberate and both in the file headers: the ledger path is built **inline** rather than via `hstate` (`dirname` + the substitution around it are two forks on the Edit path — `CLAUDE_STATE_DIR` is still honoured, so the test seam works), and `fclaims_norm` **sets `FCLAIMS_KEY`** rather than printing, because `key="$(fclaims_norm ...)"` would fork a subshell per edit. Recorder measured at ~330ms against a 2.53s baseline for the nine gates already on `Edit|Write`; keep it there. Recorder is silent by contract — writes a row, prints nothing, never blocks; `FILE_CLAIMS=off` disables it, and unlike a frontmatter `model:` that toggle is real, since the ledger is only ever written in that one place.
  - `hooks/foreign-worktree-changes-gate.sh` — warns before `git add -A`/`add .`/`commit -a` when the repo has modified **tracked** files and another live session claims it. `git-commit-scope-gate.sh` refuses the add+commit *shape*, but its header is explicit it "never inspects the index, never looks at other sessions" and declined to build session state for the cross-call case; that state exists now. Verified live against a real concurrent edit.
  - `scripts/fleet-repo-state.sh` — read-only sweep (branch, dirty, worktrees, holder + `LIVE`/`stale`). **A recorded claim about another session is a snapshot, never a fact — re-verify with this before acting on one.**
  - **Worktrees are separate claims BY DESIGN, not an oversight.** `claims_repo_root` keys on `git rev-parse --show-toplevel`, which inside a linked worktree returns the *worktree* path, not the main clone. That is correct: separate working trees genuinely do not contend, and `commit-ticket`'s worktree section tells agents to *add* a worktree rather than switch someone else's branch — so warning between them would punish the recommended fix. `check-gates.sh` pins this behaviour with an explicit case so a refactor can't quietly invert it.
  - **`worktree-branch-conflict-gate.sh`** (`PreToolUse` on `Bash`/`PowerShell`) covers the *mechanical* git constraint instead: a branch checked out in one worktree cannot be checked out **or deleted** in another (`fatal: 'X' is already used by worktree at …`). Warns before `checkout`/`switch`/`branch -d|-D` of such a branch, naming the holding path. Not a cross-session guard — it applies to a single session working alone. Worth predicting because the failure lands *mid-sequence*: release cleanup deletes branches across a dozen repos in one pass, and a `fatal:` in the middle reads as "the cleanup broke". The release/129.0.0 plan had to carry this warning by hand for `search`. **Gotcha it was built on**: the create-flag exclusion must be anchored immediately after the subcommand — an unanchored `-C` test collides with git's own `git -C <path>`, which is the dominant shape here, and silently skipped every real case.
  - `scripts/fleet-repo-state.sh` lists each **linked** worktree under its repo with that tree's branch, dirty count and claim holder — without it a session working inside `C:/ep-worktrees/*` is invisible to the sweep, since it only walks the repos root.
  - Remaining blind spot: **`lib-harness-repos.sh path <repo>` always resolves the main clone**, so a harness script run for a session working in a worktree points at the wrong tree. Deliberately not changed — every script depends on that function and making its return value depend on ambient state would be a wide, subtle change for an incident nobody has hit.
- **Ticket worked while still Open** (`ticket-worked-while-open-gate.sh`, `PostToolUse` on `Bash`/`PowerShell`): after a `git commit`, reads the **real HEAD commit** (so it sees every commit shape — `-m`, `-F`, heredoc, `--amend`, unlike `git-commit-ticket-gate.sh` which can only parse some) and checks the ticket it names for two things. (1) **Status still `Open`/`To Do`** — commit-ticket-jira says a ticket moves to In Progress the moment ownership starts, and nothing enforced it: PROJ-15268 and -15269 were committed, released and deployed to **production while sitting at Open**, and were simultaneously listed on the AMA Backlog as unstarted work someone would have redone. Widening Step 7a's sweep treats the symptom — this is the cause, caught at the moment work first lands. (2) On a `release/*`/`hotfix/*` branch, **the ticket's Fix Version must include that branch**, or the release's ticket list won't describe what the release actually ships. **`atlassian.harnessEpicKey` and `atlassian.regressionsTicketKey` are exempt** — both are documented never-transition tickets, and the Regressions one is deliberately parked at Open, so without the exemption every regression fix would trip check (1) by design. Reminder, not a gate (the commit already exists), and fails open on no token/network.
- **Production infra mutation, no code artifact** (`prod-infra-change-ticket-reminder.sh`,
  `PostToolUse` on `Bash`/`PowerShell`): the infra-only twin of the hook above, for work
  that has no `git commit` for that hook to see. Fires on a MUTATING `aws` call
  (`authorize-/revoke-security-group-ingress|egress`, `modify-security-group-rules`,
  `apply-security-groups-to-load-balancer`, `set-security-groups`,
  `change-resource-record-sets`) against the SESSION's own resolved ticket
  (`.session-chatfiles/<sid>.ticket`) — `describe-*`/`get-*` never match. Two checks, both
  confirmed live 2026-08-26 as real gaps: status `Open`/`To Do` → move to In Progress now
  (PROJ-15314 reached a prod SG mutation at Open with nothing warning); status `In
  Progress` → the change IS the deploy, transition it (Done, or Ready to Test + ledger row
  — see the infra-only transition row above) — PROJ-15312's whitelisting sat at In
  Progress after going live on two prod LBs until the user caught it. Silent on any other
  status. Same harness-epic/Regressions exemptions and fail-open behavior as the commit
  hook above. Known gap, same class as the deploy-sweep hook: only catches the verb
  literally in the command text, not a wrapper script or SDK call.
- **Claimed hotfix versions blocked** (`hotfix-version-claimed-gate.sh`, `PreToolUse` on `Bash`/`PowerShell`): denies `git checkout -b hotfix/X.Y.Z` / `git switch -c` when that Jira version already has a description or any ticket tagged to it. `ama-hotfix` Step 1 already said to take max **+1**, but the version list reads like an invitation — confirmed live 2026-08-18, `hotfix/129.0.1` existed *and* was already in `~/.claude/harness-state/tickets/.confirmed-jira-versions`, which looks like a green light. It was reserved for PROJ-15311's selenium-crawler fix; an exporterplus branch was cut against it and pushed before the user caught it. **`harness-state/tickets/.confirmed-jira-versions` proves a version EXISTS (so `jira-fixversion-confirm-gate.sh` allows tagging it) — it says nothing about ownership**, and nothing was asking the second question. Gates branch *creation*, not the push (by then the name is already on a remote); a plain `git checkout` onto an existing hotfix branch still passes. Fails **open** on missing token, no network, or an unparseable response — a hotfix is urgent by definition and this must never be why one can't be cut. Own-version escape hatch: a version whose ONLY tagged ticket is this session's recorded ticket passes; the deny text carries the recovery for a stale session-ticket record (`set-session-ticket.sh` + retry) and says to CREATE the next version yourself via `jira-version.sh create` — never to ask the user (stale ask-the-user wording corrected 2026-08-19).
- **Hotfix stowaway commits blocked** (`hotfix-stowaway-gate.sh`, `PreToolUse` on `Bash`/`PowerShell`): denies `git commit` on a `hotfix/*` branch that has **no upstream** (never pushed) and already carries commits ahead of `origin/master` **older than 2 hours** — a parked local hotfix branch's cargo, which nothing else asks about. Confirmed live 2026-08-05→07: a session cut local `hotfix/128.0.1` in `reports`, cherry-picked two PROJ-15278 commits (user-approved route at the time), aborted mid-flow to fight QA 500s and left the repo ON the branch; two days later the PROJ-15286 session computed the same version, found the branch already there, committed on top and pushed/merged — shipping the stowaways to production inside a hotfix whose Jira version never mentioned them (the stash message naming the foreign HEAD scrolled by in test output). Fresh (<2h) own-session commits pass, an upstreamed branch passes (cargo already visible on the remote), fails **open** on no repo/no `origin/master`. Escape hatch after actually reviewing the listed commits: append `<repo-root>|<branch>|<HEAD-sha>` to `~/.claude/harness-state/tickets/.hotfix-stowaway-ack` — pinned to the exact HEAD, so new stowaways re-trip it. Companion prose rule in `ama-hotfix`: abandoning/parking a hotfix route = delete the local branches and check out develop, same turn.
- **Develop back-merge reminder** (`develop-backmerge-reminder.sh`, `PostToolUse` on `Bash`/`PowerShell`): fires after a push to `master` in a repo that also has `origin/develop`, when `git cherry origin/develop origin/master` reports any `+` line (a commit whose **patch** has no equivalent downstream) — the back-merge half of `ama-deploy-release` Step 1 / `ama-hotfix` Step 4. Both skills already said to merge to master **and** develop, but nothing checked the develop half and prose alone didn't hold: hotfixes 128.0.1–128.0.7 each skipped it, and the drift only surfaced weeks later at the release/129.0.0 wrap-up, when six repos had conflicting `.csproj` library versions and `reports` had a real semantic conflict (develop had dropped a line the hotfixes restored on master) that nobody could still explain from memory. The reason text carries the two resolution rules that have precedent — `.csproj` conflicts take the latest version of each package (confirmed against CodeArtifact **publish dates**, since the Bitbucket migration reset some build counters, so a higher version string isn't automatically newer), and a hotfix's own code beats develop, because that's what production is running. Deliberately a reminder, never a gate: the master push is already done and correct by the time it runs, and a production hotfix must never be blocked on a develop chore. Reads only local refs (no fetch), so a stale `origin/develop` can only produce a spurious reminder, never a missed one. **The predicate is the whole correctness of this hook, and two obvious-looking answers were both wrong.** (1) *Branch ancestry* — `ama-deploy-release` Step 1 deliberately sources both merges from the release branch rather than chaining develop through master, so after a normal release `origin/master` is never an ancestor of `origin/develop` even though every line already landed there; fires forever on healthy repos (7 of the 17 release/129.0.0 repos sat in exactly that state). (2) *Counting non-merge commits in `origin/develop..origin/master`* — a fix committed on a release branch and separately **cherry-picked** onto develop is two commits, different SHAs, identical content, so the master copy reads as missing. Confirmed live 2026-08-18: all 10 `exporterplus` commits flagged that way were already on develop with byte-identical patches (`git patch-id --stable` matched exactly), and the back-merges pushed for `export`/`feedback`/`querybuilder` produced empty file diffs for the same reason. `git cherry` compares patch IDs and is immune to both. Verified silent on all 9 live repos, and on a synthetic repo: silent when clean, **fires** on one genuinely unapplied commit, silent again once that same patch is cherry-picked onto develop under a different SHA. **Dead-develop skip** (2026-08-28): five fleet repos (`common-models`, `common-mongo`, `exportproducer-messages`, `fieldtablemapper-client`, `mappingtool-web`) have a `develop` untouched since 2020-21 that is a pure stale ancestor of master, so every master push there would nag forever. The hook stays silent only when BOTH hold — `git cherry origin/master origin/develop` shows zero develop-only patches AND develop's tip is older than `BACKMERGE_DEAD_DEVELOP_SECS` (default 1 year); either half alone still nudges (a healthy repo that is merely even after a release is young). Suite pins both halves. Whether to delete/fast-forward those five branches is a repo-housekeeping call for the user.
- **Cherry-picking a release fix onto develop instead of merging is the underlying process defect** the hook exists to catch. It leaves the branches with no shared ancestry for that work, so git sees two unrelated commits touching the same lines and **every later merge conflicts there** — the direct cause of release/129.0.0's `.csproj` conflicts across six repos and the `reports` `UpdateUserReportService.cs` semantic conflict. It also makes a genuinely missing commit indistinguishable from a duplicated one without a patch-id comparison. Fixes on a live `release/*`/`hotfix/*` branch must reach develop **through the merge**, never as a parallel cherry-pick.
- **Scoped-commit sweep prevented** (`git-commit-scope-gate.sh`, `PreToolUse` on `Bash`/`PowerShell`): denies `git add <specific files> && git commit` with no trailing pathspec and no `-a`/`--all` — `git commit` always commits the whole index, not just what was just added, so a concurrent session's already-staged files silently ride along under an unrelated message. Confirmed real, twice in one session against this repo. Fix: `git commit -m "..." -- <same paths>`. Doesn't flag a deliberate `git add -A`/`.` (the shape `on-stop.sh`'s own auto-commit uses), and only catches add+commit chained in the same command — a separate later `git commit` call isn't covered. **One edge in the recommended fix itself**: `git commit -- <paths>` has `--only` semantics — it commits those paths' WORKING-TREE content, silently overriding anything staged for them, including a `git rm --cached` deletion (bit a real untracking once: the "deleted" file re-committed with its edits). Committing a staged deletion of a file that stays on disk needs a plain index commit with nothing else staged.
- **Direct master pushes blocked** (`master-push-direct-gate.sh`, `PreToolUse` on `Bash`/`PowerShell`): denies `git push` to `master` on an AMA_APP repo when the outgoing commits include non-merge commits not reachable from any `hotfix/*`/`release/*` ref — master is production fleet-wide, and out-of-cycle changes must ride a hotfix branch per `ama-hotfix` (the solo-repo "no PRs" convention skips pull requests, not the hotfix flow; a cherry-pick straight onto master already happened once and needed a revert). The legitimate `--no-ff` hotfix/release merge shape passes; `~/.claude` and `ama-claude-harness` (which live on master by design) are excluded; reads only local refs (no network), fails open on unparseable shapes. A user-instructed direct push (e.g. history repair) needs the user to confirm that specific push.
- **Production-deploy-triggered Done sweep + version-Released nudge** (`octopus-prod-deploy-ticket-sweep-reminder.sh`, `PostToolUse` on `Bash`/`PowerShell`): fires on a `POST .../deployments` call whose `EnvironmentId` matches `octopus.environmentIds.production`, nudging two things once Claude's own ECS-image-tag verification confirms the deploy landed: (1) the mandatory Fix-Version ticket sweep to Done, same pass also closing any prior hotfix ticket still sitting at Done (`ama-deploy-release` Step 7a, reused as-is by `ama-hotfix` Step 4), and (2) marking that same release/hotfix Jira **version** Released (`jira-version.sh release`). (2) was added 2026-08-20 — previously self-recognition only (skill-text in `ama-hotfix`/`ama-release-notes`), and `hotfix/128.0.7`, `129.0.1`, `129.0.3`, `129.0.5` sat unreleased in Jira despite shipping to prod as a result. Reversed 2026-08-11 per explicit user instruction — this used to require asking the user first every time; that gate is gone, both steps are unconditional once verified. Same nudge-not-verify limitation as the push reminder above, plus a quote-blind gap: only catches an `EnvironmentId` literal actually visible in the command text, not one built via a shell variable or file payload. **Step 7a's query now spans `Open`/`To Do`/`In Progress` as well as `Done`/`Test Complete`** — a ticket worked straight from Open never enters the intermediate columns, so the old `status in (Done, "Test Complete")` query could not see it however plainly its code had shipped (PROJ-15268 and -15269 shipped in release/129.0.0, sat at Open, and were simultaneously listed on the AMA Backlog page as unstarted work). Those extra statuses are **reported, never auto-swept**: shipped-but-not-started is a contradiction where the right answer is sometimes to clear a wrong fixVersion rather than mark the ticket Done.
- **Staging cache-update nudge** (`octopus-staging-cache-update-reminder.sh`, `PostToolUse` on `Bash`/`PowerShell`): sibling of the prod hook above, same shape, for the Staging cache-update gate documented in `ama-hotfix` ("Cache update gate", own heading) and `ama-deploy-release` Step 0d instead of the ticket sweep. Confirmed live 2026-08-25: hotfix/129.0.9-.11 (touching report fields AND SqlTemplates) shipped through Staging with **zero** Staging cache-update executions run at all — the requirement was prose only, buried as Step 2's last paragraph, self-recognition missed it end to end. Two triggers, because Staging is reached two ways: (A) an explicit Octopus `POST .../deployments` matching `octopus.environmentIds.staging` (the release flow) — same EnvironmentId-match shape as the prod hook, stays a decision-nudge since there's no local diff to inspect from a bare curl call; (B) a `git push` on a `hotfix/*` branch — hotfixes auto-deploy to Staging via the Hotfix channel's lifecycle with no explicit deployments POST to catch, so trigger A alone would never fire for that path. Per explicit user instruction (2026-08-25), this must fire only for changes that actually touch report fields/SqlTemplates, not every push — trigger B can and does check this for real: the push already landed by `PostToolUse` time, so `git diff --name-only origin/<branch>@{1}..origin/<branch>` (same reflog idiom `ama-search-shared-version-sync` Step 0 uses) is grepped against a path pattern (`SqlTemplate`, `DataDictionary`, `Database/Migrations`, plus the two builder classes named in the 2026-08-25 incident) — no match, no nudge. Reflog unavailable (fresh clone, first push this session) falls back to a decision-nudge rather than staying silent. Same nudge-not-verify limitation as its sibling: can't act on the decision itself, and trigger A's quote-blind gap (`EnvironmentId` must appear as a literal in the command text) applies here too.
- **VPN DNS outages get logged to the standing IT ticket automatically** (`vpn-dns-outage-logger.sh`, `PostToolUse` on `Bash`/`PowerShell`): fires when a **network** command fails with a resolver error — BOTH wording families: Unix (`Could not resolve hostname`, `Non-existent domain`, `No address associated`, `Name or service not known`) AND Windows/.NET (`DNS name does not exist`, `No such host is known`); the Windows set was missing until 2026-09-01, and the hook sat silent through a confirmed live outage because of it (the failing command was `Resolve-DnsName`, whose wording matched nothing). The network-command side likewise recognizes PowerShell cmdlets (`Resolve-DnsName`, `Test-NetConnection`, `Invoke-WebRequest`, `Invoke-RestMethod`, `ping`) including inside `try {`/`if (` wrappers. Reminds Claude to append another dated `### Example` to `~/.claude/IT-Ticket-VPN-DNS/IT-TICKET-VPN-DNS-bitbucket.md` (moved into that subfolder 2026-08-28 per PROJ-15342; the old flat-path allowlist entry in `claude-dir-clutter-gate.sh` is removed — the flat name is ordinary clutter again). The hook scrapes tool output only — a resolver fault degrading Claude Code's own API calls with no failing tool command is covered by its companion, the proactive probe (PROJ-15367): `hooks/vpn-dns-probe.ps1`, run every 10 min by scheduled task `AMA-Harness-VPN-DNS-Probe` (PowerShell-native, zero cygwin forks, hidden via `run-hidden-generic.vbs`). Fault = `10.1.0.4` NXDOMAIN while the default resolver answers (both-failing = general connectivity, silent; GP disconnected = silent). On fault it appends to `hstate notices vpn-dns-probe.txt` (30-min dedupe) + chimes; on recovery it appends a duration line; `on-prompt.sh` surfaces the digest one-shot, un-throttled (the fault self-heals in minutes, so it must not ride the 30-min nudge marker). Per explicit user instruction 2026-08-20 — the draft ticket is only persuasive because it carries a *log* of occurrences with dates, durations, resolvers and **locations**, and self-recognition is worst exactly here: the session is mid-task, something just broke, and the reflex is to retry, not to document. Two-sided predicate (DNS wording **and** a network command) because merely `cat`-ing any log containing the error text would otherwise match; the ticket file, this hook and `harness-gaps` are excluded by name, or writing the entry would itself trigger a reminder to write the entry. Dedupe is **one entry per calendar day**, read straight off the ticket's own `### Example ... <today>` headings — no state file, so it keeps nudging until the obligation is met and goes quiet by itself once it is. Confirmed detection trap recorded in the reminder text: Windows `nslookup` **exits 0 on NXDOMAIN**, so an exit-code poll reports recovery while the resolver is still failing — probe with `git ls-remote`.
- **New tickets get added to the AMA Backlog Confluence page** (`atlassian.backlogPageId` in `harness-config.json`), kept priority-ordered — but only ones left **Open** (not worked this session; the backlog is future work, not a log of everything created). Nudged by `backlog-page-reminder.sh` (`PostToolUse` on `createJiraIssue`/`Bash`, same "nudge not verify" shape as the push reminder above, and mostly a no-op since request-time tickets usually go straight to In Progress). Section mapping + insertion mechanics: `commit-ticket-jira/BACKLOG-PAGE.md`. The same page is also the **pickup** source — "backlog"/"pick up tasks from the backlog" means its Open tickets, in the page's own document order, **plus** a second, lower-priority "AMA Backlog — Deferred" child page (older off-page tickets triaged 2026-08, read only after the main page is exhausted) — both pages' mechanics live in `memory/ama-backlog-page.md`.
- **Old/foreign tickets get a premise check before being worked** — a ticket created >2y ago or reported by someone other than you gets its condition verified first: a fix ticket is re-tested for whether it still reproduces, a requirement is re-confirmed with you as still wanted. Verified gone/not-wanted → cancelled automatically (commented, transitioned, removed from the backlog page); couldn't verify → ask, never cancel on that alone. Nudged by `ticket-in-progress-reminder.sh`'s existing reason text (no new hook). See `commit-ticket/SKILL.md`'s "Old/foreign ticket picked up" section.
- **Release/hotfix Fix Version tagging is gated** (`jira-fixversion-confirm-gate.sh`, `PreToolUse` on `createJiraIssue`/`editJiraIssue`): a `release/*`/`hotfix/*` Fix Version must be confirmed to exist before it can be tagged — **Claude creates it itself** (`skills/ama-jira-api/scripts/jira-version.sh create`), then runs `confirm-jira-version.sh <version>` to record it in `~/.claude/harness-state/tickets/.confirmed-jira-versions` before the gate allows tagging. The old rationale ("no MCP/REST tool does it") was half wrong and never tested: REST creation works. The gate still earns its place for a **different** reason than it was built for — the real hazard is taking the *wrong* number, which free creation makes easier, not harder. The script's output then nudges the next step: **set the version's description** (Claude CAN edit that — `PUT /rest/api/3/version/<id>`, recipe in `ama-jira-api`'s "Version descriptions" section), since Jira version descriptions surface as the Octopus Releases page's Description column. Applies whenever a hotfix/release version is confirmed created or found already existing with an empty description.
- **Release tagging (Step 3a) is a Jira query, not a code search:** assignee in (you, Reviewer One) + status in (QA/Ready to Test/Test Complete) → tag it, full stop. A code-search-based check used to wrongly call tickets "unmerged" when their code lived outside `~/Repos/AMA_APP` (an `AMA_ETL` repo, or the harness itself). Any *other* code sweep (grepping for a ticket ref across the fleet) must cover `AMA_APP` + `AMA_ETL` + `~/.claude` — and remember some tickets genuinely have no code at all.
- **Repo location and folder naming are no longer hardcoded** (PROJ-15143 wave 1): `hooks/lib-harness-repos.sh` resolves any repo by Bitbucket slug or local folder name via its own `git remote get-url origin` — local folder names aren't trustworthy (this machine alone strips 4 different prefixes). Roots + a discovered index live in `~/.claude/.harness-local.json` (gitignored, per-machine). The scripts/skills that hardcoded `~/Repos/AMA_APP` now call it. Wave 2 (remaining hardcoded identifiers — emails, project/epic keys, AWS/Octopus/Graylog literals) is audited and checklisted, not yet migrated. `hooks/lib-harness-repos.sh index` now emits the fleet as a 4th column (`slug/folder/path/fleet`) on both the real and test-override paths — `ama-pr-review` loops it directly instead of a docs-table list, so PR discovery covers app + ETL fleets in one pass.
- **Leaves context for future sessions**, per repo/topic — see the `ama-debugging-notes` skill below. Architecture facts get added liberally; a specific bug's root cause only for a genuinely reoccurring class, always confirmed with you first. Deliberately a skill, not a repo's own `CLAUDE.md` — the latter's cost is unconditional (every future session in that repo pays for the whole file from turn one), a skill only loads when actually relevant.

## Cross-session concurrency — measurements and file claims (moved 2026-09-15 from AGENTS.md)

Verbatim from AGENTS.md's "Commit & ticket discipline" section; AGENTS.md keeps a five-line pointer.

- **One session at a time doing hook/settings work in `ama-claude-harness`** (PROJ-15368,
  soft convention — other repos unrestricted). **The reason is COLLISIONS, not latency.** An
  earlier version of this entry said concurrency multiplied hook cost ~10x; measurement
  retired that, see below. What survives is the file-collision rate: 153 same-file
  different-session pairs inside 6h windows over 7 days, and exactly one of them outside this
  repo. Two of them cost real work on 2026-09-01.
  - **`on-prompt.sh`, measured 2026-09-02 (solo) and 2026-09-01 (4 sessions), each against a
    COPY of `harness-state`:** solo throttled **10.4 / 9.0 / 11.5s**, solo nudge-due **25.9s**;
    4-session throttled **6.5s**, nudge-due **6.4 / 8.3s**. Solo is not faster than contended,
    so **concurrency is not the driver** — the earlier "latency tracks concurrent shell count"
    claim was wrong and is withdrawn. Likely mechanism for the inversion: other sessions keep
    the harness files hot in page cache. n=3 for solo throttled; every other cell is n=1–2.
  - What DID change: solo throttled (9–11.5s) matches the original 2026-08-31 solo figure of
    11s, while the multi-session figure fell from 59–116s to 6.5–8.3s. **The contention
    amplification is gone** (30-min nudge throttle + `UserPromptSubmit` timeout 60→180s). The
    residual is a ~10s fixed hook cost that concurrency no longer multiplies, and a ~26s
    nudge-due path that is now the worst number in the set.
  - Why the 116s mattered at all: it blew the then-60s timeout, so the hook's whole injected
    context was **silently discarded**. That, not the wait, was the cost.
  - Timing method for anyone re-measuring: point `CLAUDE_STATE_DIR` at a **copy** of
    `harness-state`, never the live store — an empty store makes the notice checks cheaper than
    they really are and understated these numbers by ~2.5s on first measurement. `touch`
    `notices/.nudge-checks-lastrun` before timing the throttled path; a fresh dir has no
    marker, so run 1 takes the due branch and then creates it, and a median over a loop
    silently blends one due run with N-1 throttled ones. A synthetic payload with a fake sid
    always takes the `(_pn-1)%10==0` full-injection branch and skips the `sessions.txt` topic
    backfill, so it is not identical to a real prompt in either direction.
- **File-level claims — BUILT 2026-09-02** (`file-claim-record.sh` + `lib-file-claims.sh`, read
  by `cross-session-repo-claim.sh`). The user's standing "not justified yet" was **overturned by
  them** once the evidence was measured rather than anecdotal: 153 collisions/6h-window over 7
  days across 58 files (45 `AGENTS.md`, 21 `harness-gaps.md` — append-only BY DESIGN — 20 the
  Jira payload files), plus two same-day sweeps and one near-miss that came within an un-run
  `git reset` of shipping a staged deletion of already-committed content.
  - **Warns at COMMIT time, not edit time.** Recording is silent. Almost all 153 are harmless,
    so an edit-time warning would be ~150 interruptions a week for the two that hurt; both of
    those were commits. Measured price of the recorder: ~330ms on the Edit|Write path, against
    a 2.53s baseline for the nine gates that were already there (2026-09-01, solo).
  - Toggle `FILE_CLAIMS=off` genuinely disables it — the ledger is only ever written by that
    one hook, and the consumer stays silent on an absent file.
  - **Not yet observed firing on a real concurrent commit**, so PROJ-15368 stays In
    Progress. Daily 09:05 task `AMA-Harness-FileClaim-Reminder` nags until it does, and the
    guard itself clears the marker + reports the firing the first time it warns — an event
    closes the loop, not someone remembering. Details in `PORTABILITY.md`.

## sessions.md rendering rules (moved 2026-09-15 from AGENTS.md)

Verbatim; AGENTS.md keeps a pointer.

- **`sessions.md`** = same data rendered for viewing; never edit it, nothing parses it back.
  - Resume handle: latest `customTitle`, else latest `agentName`, resolved fresh from the
    transcript tail at render time (`resume_handle`, `session-ctx-sizes.pl`) — NOT the
    `.explicitname` snapshot, which goes stale after a `/rename` + quiet session
    (confirmed: a frozen snapshot printed a resume command `--resume` no longer recognized).
    `aiTitle` is not a confirmed `-r` match — those rows keep the raw sid.
  - **A name is only printed when exactly one session answers to it.** `claude -r <name>`
    with two matches drops the user into the resume *picker* instead of resuming — a
    printed command that silently doesn't do what it says (confirmed: two sessions titled
    "Update latest meeting notes"). The renderer counts every session's latest
    `customTitle`/`agentName`/**`aiTitle`** — all three, because Claude Code's own picker
    matched a session carrying only an `aiTitle`, a field the harness would never print
    but which still makes someone else's handle ambiguous — and falls back to the raw sid
    on a collision. The census is harvested from the tail buffer the context-size column
    already reads, so it costs no extra I/O.
  - Display name: `sessions.txt` field 1, **overridden by an explicit `/rename`** the row
    hasn't caught up with — i.e. a `customTitle` whose slug differs from field 1
    (confirmed: `0bb7c2c3`, renamed to `harness-findability-wave`, kept displaying
    `debug-chrome-process-killer` because only that session's own next turn updates field
    1, and it had gone quiet). Auto-titles deliberately do NOT override: `agentName` and
    `aiTitle` drift as a conversation moves, and following them rewrote ~67 rows away from
    the harness topic — which is also the chat file's name — for no user-visible reason.
    Render-only: `sessions.txt` and the chat file still catch up on that session's own
    next turn. **Exception:** when field 1 is the bare shortid there is no topic to
    protect, so any auto-title beats a hex string (confirmed: `7b9cae8f` displayed its
    shortid while its transcript had said `address-harness-gaps` 117 times).
  - Command ends `--chrome` (render-time only, skipped when `claudeInChromeDefaultEnabled:
    true`) — so a resume has Chrome control for repos with no headless path. The other two
    resume-command emitters stay as-is deliberately: `on-session-end.sh`'s chat-log line
    (its exact text is what `on-prompt.sh`'s strip regex matches) and `statusline.sh`'s
    rate-limit auto-resume (`--no-chrome` — unattended).
  - Short-id field between name and command (matches `.session-chatfiles/<sid>.*` etc.);
    trailing context-size field `— **<Nk>**` from the last NONZERO usage blob (an errored
    turn writes an all-zero blob; taking that would render a dead session as a fresh `0`).
    Not the max — `/compact` legitimately shrinks it. Colored green→red, absolute 0→600k
    (no window size in transcripts, so a % would fabricate a denominator); `<font color>`
    because VS Code's preview strips `<span style>`.
  - Rows hide for two reasons, each with its own footer count: **unresumable** (no
    transcript on this machine, or never a nonzero usage blob) and **under 90k context**
    **whose transcript is also under 1 MB** (`$MIN_CTX` + `$MIN_BYTES` — small sessions
    crowd out the ones worth returning to; still resumable via `grep <name> sessions.txt`,
    the txt keeps every line). Display-only, nothing is deleted. **Both clauses are
    required**: `/compact` resets the context window, so live context alone hid a
    13.9 MB / 1742-turn session at 79.6k — the exact kind of long-running session this list
    exists to surface.
  - Third hide, own footer count: **superseded** — rows sharing a display name (slugified)
    keep only the most recently modified transcript. Such pairs are context-continuations
    or forks, never sub-agents (no resumable sid of their own). Kept row still resumes by
    sid (name stays ambiguous to `claude -r`).

## VPN/DNS outage logger — detection, claims, PanGPS dumps (moved 2026-09-15 from AGENTS.md)

Verbatim; AGENTS.md keeps a pointer.

- `vpn-dns-outage-logger.sh` — a network command failing with a resolver error (and google.com
  NOT resolving via the default resolver; an nslookup/dig at an explicit server is a probe,
  never a trigger) → FIRST invoke `ama-vpn-dns-outage` (Slack-pings BARRY, deduped across sessions via
  `vpn-dns-ping-claim.sh` — reverted 2026-09-04 to pinging him directly again, on top of
  the ticket comment — + IT's live capture battery, time-critical; ticket IT-7829).
  `vpn-dns-ping-claim.sh` now takes a claim NAME, one per AUDIENCE — dedupe so each human
  hears about one outage once, however many sessions saw it. DM claims the default marker;
  Step 3's outward-facing writes (IT-7829 comment + the `Example` append) claim
  `.vpn-dns-reported`; Step 0's CLI mention to the USER claims `.vpn-dns-cli-surfaced`
  (2026-09-04 — lost the claim means say NOTHING about the outage, not "another session
  has it"; a direct user question is exempt). Capture and the GP-log look stay per-session
  and un-deduped deliberately. `vpn-dns-probe.ps1`'s recovery branch clears ALL THREE
  markers. Then append a
  dated `### Example` to
  `~/.claude/IT-Ticket-VPN-DNS/IT-TICKET-VPN-DNS-bitbucket.md` (one entry/day, read off
  the file's own headings). Detects BOTH wording families — Unix (curl/git/ssh) and
  Windows (`DNS name does not exist`, `No such host is known`) — and PowerShell cmdlets
  (`Resolve-DnsName` etc), incl. inside `try {`; it sat silent through a live outage
  (2026-09-01) when it knew only the Unix set. Scrapes tool output ONLY — the no-failing-
  command case (Claude Code's own API calls degrading) is covered by `vpn-dns-probe.ps1`
  + scheduled task `AMA-Harness-VPN-DNS-Probe` every 10 min (PROJ-15367, details in
  GATES-AND-HOOKS.md), surfaced un-throttled via on-prompt.sh. Windows `nslookup` exits 0
  on NXDOMAIN — probe with `git ls-remote`. That probe also runs a SECOND, independent
  check on the same tick: a PanGPS (GlobalProtect service) crash watcher — saves the event
  records and reports where the dump is. **`LocalDumps\PanGPS.exe` was armed elevated by the
  user 2026-09-01** (`C:\CrashDumps`, DumpType 2 full, DumpCount 5), which is the real fix —
  WER writes a second copy there that its ReportQueue purge does not touch, and the ACL
  (`BUILTIN\Users` ReadAndExecute) lets the RunLevel=Limited task read it. The watcher reads
  `DumpFolder` from that key and reports the dump's path + size; it deliberately does NOT
  copy it — a full dump of a VPN client is large and holds credentials/tunnel state, so it
  goes to Palo Alto via the IT-7829 attachment, never an external file-share. Archive and
  the arming recipe: `~/Documents/IT-7829-PanGPS-crash/`.
