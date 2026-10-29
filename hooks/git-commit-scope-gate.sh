#!/usr/bin/env bash
# PreToolUse hook (Bash/PowerShell). Mechanically blocks `git add <specific files> &&
# git commit` (no trailing pathspec, no -a/--all) -- `git commit` always commits the
# WHOLE INDEX, not just the paths just passed to `git add` in the same breath. Confirmed
# real, TWICE in one session against ama-claude-harness: a concurrent session's already-
# staged files got silently swept into the commit under an unrelated message, requiring
# `reset --soft HEAD~1` + `restore --staged .` + recommit to undo both times. The fix
# that actually worked is `git commit -m "..." -- <same paths>` -- a pathspec on the
# commit itself limits it regardless of anything else staged, at zero cost even when
# nothing else happens to be staged. Same class of fix as bare-cd-gate.sh /
# git-commit-ticket-gate.sh: a real hook gate, not just a skill-prose reminder, per
# CLAUDE.md's "Mechanical Triggers Over Self-Recognition" rule.
#
# Deliberately does NOT flag `git add -A`/`--all`/`.` chained into a bare commit -- that
# IS an explicit "stage everything" intent, not a false claim of scoping, and is exactly
# the shape on-stop.sh's own auto-commit uses (`git add -A -- .`). Confirmed no
# interference there either way: on-stop.sh's git calls are the hook script's own
# subprocess invocations, never routed through the model's Bash tool, so they never
# reach this gate regardless.
#
# Heuristic, not airtight, same tradeoff git-commit-ticket-gate.sh states for itself:
# only catches add+commit chained in the SAME command. `git add X` in one Bash call
# followed by a bare `git commit` in a later, separate call isn't detected -- no cheap,
# reliable cross-call signal exists for that without new session-state infrastructure,
# and every incident this session actually hit was the same-command form. Fails open on
# anything it can't confidently parse, rather than guessing and blocking wrongly.
#
# ONE EXCEPTION, added 2026-09-15 (user decision): inside the HARNESS REPO ITSELF, any
# pathspec-less `git commit` is denied -- bare, `-a` and `-am` alike. The cross-call case
# above is not hypothetical there: commit 8b5a84d swept another live session's in-flight
# settings.json edits into itself (harness-gaps.md, 2026-09-14). Every session edits that
# one shared file, so the "-a is a self-aware choice" reasoning below does not hold in
# this repo -- "commit every tracked change" here means "including changes that are not
# mine". Everywhere else the gate is unchanged. foreign-worktree-changes-gate.sh WARNS on
# the same shape in any repo when another live session claims it; this is the unconditional
# deny in the one clone where the contention is structural.
set -u

HERE="$(dirname "${BASH_SOURCE[0]}")"

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq/grep fork (precedent:
# aggregation-secret-gate.sh) -- detection below needs both literal substrings "add" and
# "commit", so a payload missing either can exit on zero forks.
# "add" is no longer required -- the harness-repo branch below fires on a commit with no
# `git add` anywhere in the command, which is the whole shape it exists to catch.
case "$payload" in *commit*) ;; *) exit 0 ;; esac
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
[ -n "$command" ] || exit 0

# Flatten newlines to `;` and STRIP CARRIAGE RETURNS before any matching -- two separate
# confirmed-live failures on this gate's first firing:
# 1. grep -P's `.*` cannot cross newlines, so a multi-line commit message between `commit`
#    and its trailing ` -- <paths>` made the pathspec check silently fail and deny a
#    correctly-scoped commit. Same flatten-first lesson bare-cd-gate.sh documents; `;` is
#    what a newline means as a statement separator.
# 2. This environment's jq -r emits CRLF, and this grep -P build treats a bare \r as a
#    line boundary too (PCRE newline=ANYCRLF) -- a leftover \r after the \n flatten still
#    broke `.*`, byte-verified with od. Strip \r entirely; it is never meaningful here.
command="$(printf '%s' "$command" | tr -d '\r' | tr '\n' ';')"

# --- Harness repo: any pathspec-less commit, regardless of what was staged and how ------
# Matched against the text with heredoc bodies and single-quoted spans removed, so a fixture
# string holding `git commit` is not read as one (lib-command-text.sh; the class this gate's
# own add-args capture already anchors against). Existing matches below stay on $command.
if . "$HERE/lib-command-text.sh" 2>/dev/null; then
  . "$HERE/lib-repo-claims.sh" 2>/dev/null || true
  scan="$(printf '%s\n' "$command" | command_text_stripped)"
  if printf '%s' "$scan" | grep -qP '(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?commit\b' \
     && ! printf '%s' "$scan" | grep -qP '\scommit\b.*(--\s+\S|--pathspec-from-file[=\s]\S)'; then
    # --pathspec-from-file IS a pathspec (2026-10-20: denied as pathspec-less, though it is
    # the one form that keeps name-keyed gates off a long path list).
    # Target repo: -C <path> if given, else the cd target, else the session's cwd. Same
    # three-step resolution foreign-worktree-changes-gate.sh uses -- and the same reason
    # git-push-ticket-reminder.sh (299367c) had to grow it: a `-C "$W"` left the literal
    # `$W`, the repo resolved empty and the hook went silent on a real push.
    . "$HOME/.claude/hooks/lib-git-target.sh" 2>/dev/null || true
    gcs_dir=""
    if command -v git_target_dir >/dev/null 2>&1; then
      gcs_dir="$(git_target_dir "$command" "$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)")"
    fi
    if [ -n "$gcs_dir" ] && command -v claims_repo_root >/dev/null 2>&1; then
      # The harness clone identifies ITSELF -- ~/.claude/hooks is a junction into it, so this
      # resolves to the right root whatever the clone is named or wherever it lives.
      gcs_root="$(claims_repo_root "$gcs_dir")"
      gcs_harness="$(claims_repo_root "$HOME/.claude/hooks")"
      if [ -n "$gcs_root" ] && [ "$gcs_root" = "$gcs_harness" ]; then
        jq -cn '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
          permissionDecisionReason:"Pathspec-less `git commit` in the harness repo. Every live session edits this clone (settings.json above all), so a commit with no pathspec -- bare, -a or -am -- takes whatever else is staged or modified and ships it under your message. That is not hypothetical: it happened on 2026-09-14, sweeping another session in-flight settings.json edits into an unrelated commit. Name your own paths: `git commit -m \"...\" -- <your paths>`. Check who else holds the repo first: bash ~/.claude/scripts/fleet-repo-state.sh ama-claude-harness"}}'
        exit 0
      fi
    fi
  fi
fi

# Capture the git-add clause's own argument text, up to the next unquoted &&/;/| --
# same "capture up to the next operator" technique bare-cd-gate.sh uses for its `cd`
# target. Anchored to an actual command position (start, or right after ;/&/|), not
# just "the words git and add appear somewhere" -- same false-positive class
# git-commit-ticket-gate.sh's own header already documents (a quoted test fixture
# merely containing the text, nowhere near a real invocation).
add_args="$(printf '%s' "$command" | grep -oP '(?:^|[;&|]|&&)\s*git\s+(?:-C\s+\S+\s+)?add\s+\K[^&;|]+' | head -1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
[ -n "$add_args" ] || exit 0

# Deliberate broad add ("-A", "--all", or exactly ".") -- explicit "stage everything",
# not a false claim of scoping. Let it through.
printf '%s' "$add_args" | grep -qP '^(-A\b|--all\b)' && exit 0
printf '%s' "$add_args" | grep -qP '^\.\s*$|^--\s+\.\s*$' && exit 0

# Must find an actual `git commit` invocation later in the same command -- same
# anchored pattern git-commit-ticket-gate.sh already uses.
printf '%s' "$command" | grep -qP '(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?commit\b' || exit 0

# Already scoped (a pathspec after `--`) or an explicit -a/-am/--all flag (a different,
# self-aware choice -- "commit every tracked change", not "commit just what I added").
# Checked against the WHOLE command, not just text after "commit", to fail open rather
# than mis-parse a complex quoting shape -- same tradeoff as the add-args capture above.
printf '%s' "$command" | grep -qP '\scommit\b.*(--\s+\S|--pathspec-from-file[=\s]\S)' && exit 0
printf '%s' "$command" | grep -qP '\scommit\b.*(^|\s)-a(m)?\b|\scommit\b.*--all\b' && exit 0

jq -cn --arg add "$add_args" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("`git add " + $add + "` followed by a bare `git commit` -- `git commit` with no pathspec commits the WHOLE INDEX, not just what this call just added. If another session already has unrelated files staged (confirmed to happen twice in one session already), they get silently swept into this commit under this message. Add the SAME paths after `--` on the commit itself: `git commit -m \"...\" -- " + $add + "` -- this scopes the commit to exactly those paths regardless of anything else staged, and costs nothing even when nothing else happens to be staged. If the intent really is to commit everything currently staged, use `git add -A` explicitly instead of naming files, so that intent is unambiguous rather than accidental.")
  }
}'
