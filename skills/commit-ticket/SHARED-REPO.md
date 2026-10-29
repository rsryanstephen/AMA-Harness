# Another session in the same clone; worktrees, pathspecs, synthetic blobs

Reference for [[commit-ticket]] -- loaded on demand, not at task start.

## A plan's stated constraint is a snapshot — re-verify it before obeying it

Same failure mode as the section above, one level up: an approved plan (or an earlier
message in this session, or a subagent's report) records what was true when it was
*written*. Long tasks outlive that. **Before letting a recorded constraint change what you
do, re-check it live** — and say so when it has gone stale, rather than quietly acting on
old information.

Confirmed live 2026-08-18: a plan said "`exporterplus`'s Staging slot is held by another
session's `hotfix/129.0.2`, don't touch that repo". True when written; by execution time
that hotfix had merged (`master` tip read `Merge remote-tracking branch
'origin/hotfix/129.0.2'`) and the tree was back on `master`. The constraint was carried
forward as fact and shaped a real scope decision it should no longer have shaped.

**Before assuming another session occupies a repo, check — it's three cheap commands:**
```bash
git -C <repo> worktree list          # other checkouts of the same repo, and their branches
git -C <repo> branch --show-current  # what the main tree is actually on now
git -C <repo> status --porcelain      # someone else's uncommitted work in flight
```
`git worktree list` is the one that gets forgotten: a repo can have several working trees,
so "the repo is busy" and "this checkout is busy" are different claims.

**Another LIVE session in the clone -> own worktree BEFORE first edit** (not after a collision).
Never switch their branch. One root only, `~/Repos/AMA_APP/.worktrees/<repo>-<slug>`:
```bash
bash ~/.claude/scripts/worktree-add.sh <repo> <slug> <new-branch> [base]   # prints the path; base default = origin default branch
```
`file-claim-record.sh` nudges once/session/repo when it sees another session's fresh edit in your tree.
Done -> `git worktree remove <path>` same turn; stragglers: `scripts/worktree-prune.sh --apply` -- run it yourself, no ask (standing rule, user 2026-10-22: clean + pushed + no live session + idle >=3d + no outside link = removable; plain `-d`, never force). Report removed/kept.
Native `claude -w` / `EnterWorktree` / Agent `isolation:"worktree"` -> `<repo>/.claude/worktrees/<name>` (docs; no path setting). Fine for throwaway subagent edits; a `WorktreeCreate` hook to redirect was rejected (replaces git's creation for every subagent, and subagent trees never reach `WorktreeRemove` -> leak). `worktree-prune.sh` sees them like any other tree.

**Harness repo (`ama-claude-harness`) = worktree by default** (user 2026-10-22). `~/.claude/{hooks,skills,scripts}` symlink
into the main clone = LIVE install, so a half-edited hook hits every running session. Multi-file or any `hooks/` work:
`worktree-add.sh ama-claude-harness <slug> <branch>`, run `check-gates.sh` (filtered) THERE -- it loads the tree's own hooks --
commit, then `git -C <main> merge --ff-only <branch>`, remove tree + branch same turn. Live in-session check only after merge.
Small single-file edit (one skill line, one doc line, one memory file) -> direct in main as before. ff refused because main
has dirty overlap from another session -> rebase branch onto master, retry, else hand the user the branch; never stash/discard theirs.
Shared file (`AGENTS.md`, `check-gates.sh`) dirty in main -> edit it in main (additive hunk), not in the branch, so ff stays possible.
**Never junction (`mklink /J`) `node_modules` into a worktree.** `git worktree remove --force`
follows a junction and empties the MAIN clone's `node_modules` (exporterplus, 2026-10-21;
recovery `npm ci` there; again same day). `npm ci` in the worktree, or `rmdir` the junction before removing it.
Gate-enforced: `worktree-junction-remove-gate.sh` denies the remove while a link is inside.
Never `git stash` or check out over another session's uncommitted changes to make room.
And when committing in a shared repo, scope the commit to your own paths
(`git commit -F msg -- <paths>`) so a concurrent session's staged files can't be swept in.
**But a pathspec commits the WORKING TREE, not the index** — it keeps other files out, and
pulls in any concurrent edit to the files you named, bypassing whatever you staged. Sharing a
file with another session → stage your side (`git add -p`, or a synthetic blob via
`git hash-object -w` + `git update-index --cacheinfo`) and commit with **no pathspec at all**,
then `git show HEAD -- <file>` to confirm. Confirmed 2026-08-28: a synthetic-blob exclusion was
silently undone by the `-- <paths>` in this very rule, committing another session's broken hunk
under a message that said it had been excluded.
**A pathspec only matches TRACKED files** — a new file errors with `did not match any file(s)
known to git` and the whole commit aborts, so `git add -- <new paths>` first, then commit with
the full pathspec. Also pass the message via `-F <file>`, not `-F -`: the ticket gate can't read
stdin and refuses a message it can't see. A gate-denied `git add && git commit` chain retried
as commit-only ships whatever subset was already staged (2026-08-21, rename-only commit reached
Staging) — after any denial, re-run the adds and `git show --stat HEAD` before pushing.
**A shared FILE can't be scoped away.** When another session's in-flight work is interleaved in
a file you must commit (`AGENTS.md`, `on-prompt.sh`, `check-gates.sh`), check whether its lines
depend on files it hasn't committed — committing your half alone can ship a tree that breaks on
every prompt. Carry theirs, say so in the message, and log it.
**Their stuff already STAGED → neither shape works.** Pathspec commits the working tree (their
hunks in your file); no-pathspec commits the index (their 7 other files). Build the commit in a
private index instead — `GIT_INDEX_FILE=<tmp> git read-tree HEAD`, `git apply --cached <your
patch>`, `write-tree`, `commit-tree -p HEAD -F msg`, `update-ref HEAD <new> <old>`. Shared index
and working tree untouched. **Footgun: that leaves the shared index holding a staged DELETION of
what you just committed** (its base is the old HEAD) — always follow with
`git reset HEAD -- <paths>`, or the next session to commit ships the deletion. Hit twice,
2026-09-01 (PROJ-15368).
- Verified absent, or user confirms not wanted → **cancel automatically** (user
  instruction): comment the evidence, transition to Cancelled/Won't Do (resolve via
  `jira-get-transitions.sh`, may take hops; none offered → ask user, don't force a
  status), remove from AMA Backlog page (`../commit-ticket-jira/BACKLOG-PAGE.md`), tell user it was
  cancelled.
- Couldn't verify (no env/access) ≠ absent — say which, then ask user. Never cancel on
  "couldn't verify."

