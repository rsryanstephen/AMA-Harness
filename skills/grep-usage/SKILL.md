---
name: grep-usage
description: How to search file content without risking a memory-blowup grep process -- use before running a raw bash grep/find, or whenever deciding how to scope a recursive text search across a repo or directory tree.
---

# Searching file content safely

Confirmed real: unscoped recursive `grep -r` over binary build output (bin/obj DLLs,
`.git` objects) drives `grep.exe` to 6GB+ RAM.

## Prefer the `Grep` tool over raw bash `grep`/`rg`

It's ripgrep-backed — skips binaries automatically, respects `.gitignore`,
`head_limit`/`glob`/`type` bound the result size. This is the default, not a fallback.

**`rg` is NOT installed on this machine** (confirmed) — don't suggest installing it or
assume it's available as a raw shell command; the `Grep` tool already gives ripgrep's
behavior without needing the CLI binary on PATH.

## If a raw `grep` in Bash is genuinely needed

(piping into other shell logic the `Grep` tool can't express)

1. **Always add `-I`** (skip binary files) on any recursive grep — this alone fixes
   the confirmed root cause (binary files buffered as giant single "lines").
2. **Scope to the specific repo/directory actually relevant** — never recurse the
   whole multi-repo `~/Repos/AMA_APP` (or any other) root unfiltered.
3. **Exclude build/dependency dirs** if scope can't be narrowed further:
   `--exclude-dir={node_modules,.git,dist,build,.next,out,coverage,bin,obj}`
4. Prefer `--include="*.ext"` over excluding when you know the target file type —
   narrower is safer than broader-with-exclusions.

A mechanical hook (`grep-memory-gate.sh`) denies a recursive grep missing `-I` — if
you hit that, add the flag rather than finding a way around the check.

## `~/.claude/skills` and `~/.claude/hooks` are junctions — walking `~/.claude` skips them

Scope a harness-wide sweep to `~/.claude/skills`, `~/.claude/hooks`, etc. directly, or
to the real repo path (`~/Repos/AMA_APP/ama-claude-harness`) — a walk rooted at
`~/.claude` silently returns 0 hits from either junction (missed refs, not an error).
