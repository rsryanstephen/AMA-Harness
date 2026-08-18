#!/usr/bin/env bash
# PreToolUse hook (Bash/PowerShell), PROJ-15114-class fix: mechanically block a
# `git commit` under ~/Repos/ whose message doesn't start with a PROJ ticket ref --
# the commit-ticket skill's own hard-stop is advisory (only applies if the model actually
# follows it). Confirmed real incident: a whole 13-repo cascade session committed and
# pushed with zero ticket ref anywhere, skill never consulted. This is the same class of
# fix already applied to ~/.claude's own auto-commit (see on-stop.sh) -- a real hook gate,
# not just a skill reminder.
#
# Applies everywhere EXCEPT ~/.claude -- that repo has its own separate ticket-gate
# mechanism (on-stop.sh's auto_commit_push + set-session-ticket.sh), not this one.
# Confirmed real bug in an earlier version of this hook: it allowlisted ~/Repos/ using
# only the payload's own `cwd` field, but `cwd` is the SESSION's cwd, not the git
# command's actual target -- a `git -C <path> commit ...` (or `cd X && git commit`) run
# from a ~/.claude session against a totally different repo was silently let through
# because the session cwd itself was ~/.claude. Fixed by resolving the command's real
# target directory (from -C/cd if present, session cwd otherwise) and denylisting only
# ~/.claude, instead of allowlisting ~/Repos specifically.
#
# Heuristic, not airtight: only checks commands it can confidently parse a commit message
# out of (simple -m "..."/'...' form, or the heredoc `-m "$(cat <<'EOF' ...)"` form this
# project's own conventions use). Anything else (bare `git commit --amend --no-edit`, an
# editor-opening commit, etc) is let through unchecked rather than blocked on a guess --
# fails open on ambiguity, fails closed only when a message was actually found and it's
# missing the ticket ref.
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq/config fork (precedent:
# aggregation-secret-gate.sh) -- the commit-matching regex below requires the literal
# substring "commit", so a payload without it can exit on zero forks. False positives
# fall through to the unchanged full logic; ~60ms/fork on this machine.
case "$payload" in *commit*) ;; *) exit 0 ;; esac

CONFIG="$HOME/.claude/harness-config.json"
jira_project="PROJ"
[ -f "$CONFIG" ] && jira_project="$(jq -r '.atlassian.jiraProjectKey // "PROJ"' "$CONFIG" 2>/dev/null)"

cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"
# tr -d '\r': this environment's jq -r emits CRLF and grep -P treats a bare \r as a
# line boundary (PCRE ANYCRLF) -- see git-commit-scope-gate.sh, same fix. Matters here
# for the multi-line heredoc path below (grep -qP over $command, awk line scan).
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' | tr -d '\r')"

[ -n "$cwd" ] || exit 0
[ -n "$command" ] || exit 0

target_dir="$(printf '%s' "$command" | grep -oP -- '-C\s+"?\K[^"[:space:]]+' | head -1)"
[ -z "$target_dir" ] && target_dir="$(printf '%s' "$command" | grep -oP '^\s*cd\s+"?\K[^"[:space:];&]+' | head -1)"
[ -z "$target_dir" ] && target_dir="$cwd"
# Paths this codebase's own commands write are frequently "$HOME/..." literally (not yet
# shell-expanded, since the hook only sees the command string, not its execution) --
# expand that prefix ourselves using this process's own real $HOME before comparing.
target_dir="${target_dir/#\$HOME/$HOME}"

# Compute the ~/.claude exclusion from this process's own real $HOME, not a hardcoded
# username -- portable across whoever's account this hook actually runs under. $HOME is
# POSIX-form in git-bash ("/c/Users/...") but the payload's cwd/target path can arrive in
# either POSIX or Windows drive-letter form -- derive both so either notation matches.
posix_claude_dir="$(printf '%s' "$HOME/.claude" | tr '\134' '/' | tr '[:upper:]' '[:lower:]')"
win_claude_dir=""
if [[ "$posix_claude_dir" =~ ^/([a-z])/(.*)$ ]]; then
  win_claude_dir="${BASH_REMATCH[1]}:/${BASH_REMATCH[2]}"
fi
norm="$(printf '%s' "$target_dir" | tr '\134' '/' | tr '[:upper:]' '[:lower:]')"
under_claude=false
case "$norm" in
  "$posix_claude_dir"|"$posix_claude_dir"/*) under_claude=true ;;
  "$win_claude_dir"|"$win_claude_dir"/*) [ -n "$win_claude_dir" ] && under_claude=true ;;
esac

if [ "$under_claude" = true ]; then
  # PROJ-15200: skills/, hooks/, CLAUDE.md, harness-config.json moved to their own
  # repo (ama-claude-harness), linked back into ~/.claude via junctions/symlinks. A
  # commit issued through the junction/symlink path (e.g. `git -C ~/.claude/skills
  # commit ...`) is really harness code and must stay gated -- carve those specific
  # subtrees back OUT of the blanket ~/.claude exclusion above. Deterministic string
  # check on the logical path; doesn't depend on git resolving the junction/symlink.
  is_harness_subtree=false
  for base in "$posix_claude_dir" "$win_claude_dir"; do
    [ -n "$base" ] || continue
    for sub in "/skills" "/hooks" "/claude.md" "/harness-config.json"; do
      full="${base}${sub}"
      case "$norm" in "$full"|"$full"/*) is_harness_subtree=true ;; esac
    done
  done
  [ "$is_harness_subtree" = true ] || exit 0
fi

# Must anchor to an actual command position (start of string, or right after ;/&/|) --
# NOT just "the words git and commit appear somewhere in this string". Confirmed real
# false-positive: an unanchored check fired on a Bash call that was actually testing THIS
# hook, because the test script's fixture data merely contained the text "git commit"
# inside a quoted argument, nowhere near being an actual command being run.
# `-C <path>` (with its value) can sit between "git" and "commit"; handle that one real
# shape explicitly rather than trying to parse every possible git flag.
printf '%s' "$command" | grep -qP '(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?commit\b' || exit 0

msg=""

# Heredoc form: -m "$(cat <<'EOF' ... EOF)" -- first line after the opening marker is
# the message's first line.
#
# The heredoc must be ATTACHED TO -m. Matching a bare `<<MARKER` anywhere in the command
# was a confirmed false-positive generator: a call that WRITES a file via heredoc and then
# commits (`cat > msg.txt <<'MSG' ... MSG` + `git commit -F msg.txt`) had the message
# file's first line read as the commit message; so did `cat > script.sh <<'EOF' ... EOF`
# + `bash script.sh`, where the "message" came out as `set -u` and the `git commit` being
# matched was a line of script text, not a command being run. Both hit live 2026-08-18
# while landing six merge commits, and neither was a real violation.
#
# Restricting to the -m-attached shape is faithful to this block's stated scope (see the
# header comment: "the heredoc `-m "$(cat <<'EOF' ...)"` form this project's own
# conventions use"), not a weakening. Any other shape simply extracts no message and hits
# the fail-open path below, which is this hook's documented behavior for ambiguity.
if printf '%s' "$command" | grep -qP -- '-m\s+"?\$\(\s*cat\s+<<-?\s*.?[A-Za-z_]+'; then
  delim="$(printf '%s' "$command" | grep -oP -- '-m\s+"?\$\(\s*cat\s+<<-?\s*.?\K[A-Za-z_]+' | head -1)"
  if [ -n "$delim" ]; then
    msg="$(printf '%s\n' "$command" | awk -v d="$delim" '
      found_start && !found_msg { print; found_msg=1 }
      $0 ~ ("<<-?[[:space:]]*.?" d ".?[[:space:]]*$") { found_start=1 }
    ')"
  fi
fi

# Simple form: -m "message" or -m 'message'.
if [ -z "$msg" ]; then
  msg="$(printf '%s' "$command" | grep -oP -- "-m\s+\"\K[^\"]*" | head -1)"
  [ -z "$msg" ] && msg="$(printf '%s' "$command" | grep -oP -- "-m\s+'\K[^']*" | head -1)"
fi

# Couldn't confidently extract a message -- fail open, don't block on a guess.
[ -n "$msg" ] || exit 0

if printf '%s' "$msg" | grep -qP "^${jira_project}-[0-9]+:"; then
  exit 0
fi

jq -cn --arg msg "$msg" --arg proj "$jira_project" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Commit message doesn'"'"'t start with a " + $proj + "-XXXXX: ticket ref (per the commit-ticket skill). Message seen: \"" + $msg + "\". Resolve a ticket with the user first, then retry the commit with the ticket ref leading the message.")
  }
}'
