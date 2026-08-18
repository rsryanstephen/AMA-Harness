#!/usr/bin/env bash
# PreToolUse hook (Bash/PowerShell). Mechanically blocks a LEADING (the command's own
# first token), unparenthesized `cd <path>` -- whether it's the ENTIRE command, or
# followed by more work via &&/;/| -- because shell cwd persists across separate Bash
# tool calls in this harness, so either shape leaks cwd forward into every later call
# until on-prompt.sh's next-turn detection catches it. Only the LEADING position is in
# scope (a `cd` that isn't the command's first token, e.g. `echo hi; cd X`, is out of
# scope) -- deliberate, see the comment at the match site for why. Both shapes leaked
# for real despite the CLAUDE.md prose rule (`&&` doesn't start a subshell, so a
# compound cd still leaks into the next call) -- prose alone isn't enough, this is the
# mechanical version, same pattern as git-commit-ticket-gate.sh.
#
# Allows: `(cd X && cmd)` (a real subshell -- the parens mean the cd never escapes),
# passing the path as an argument instead of cd-ing into it at all (the prescribed
# default), and a bare `cd` back to the session's OWN home directory (a legitimate
# corrective return after an earlier leak).
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork (precedent:
# aggregation-secret-gate.sh) -- a command whose leading token is `cd` necessarily
# contains the substring "cd", so a payload without it can exit on zero forks. False
# positives fall through to the unchanged full logic; ~60ms/fork on this machine.
case "$payload" in *cd*) ;; *) exit 0 ;; esac
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"

[ -n "$command" ] || exit 0

# Flatten newlines to `;` (NOT a space) BEFORE matching -- a newline mid-script is
# itself a statement separator in bash, equivalent to `;`. This matters even though
# matching below only cares about position 0: a genuinely LEADING `cd` followed by a
# newline then more commands (`cd X\nls -la`) still needs its TARGET correctly
# terminated at the newline -- flattening to a space would let the target capture
# swallow the rest of the script as part of the path (confirmed real bug caught in
# testing: `cd C:/fake/home\nls -la` flattened to a space produced target
# "C:/fake/home ls -la", which then failed to match home and got wrongly denied).
# `;` is exactly what the target-extraction regex below already stops at.
# tr -d '\r' first: jq -r emits CRLF here and grep -P treats bare \r as a line
# boundary (PCRE ANYCRLF) -- see git-commit-scope-gate.sh, same fix.
flat="$(printf '%s' "$command" | tr -d '\r' | tr '\n' ';')"
trimmed="$(printf '%s' "$flat" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

# Match ONLY a `cd` at the very start (position 0) of the whole flattened command --
# NOT anywhere a `;`/`&`/`|` happens to appear. A mid-string operator-anchored version
# was tried and reverted: it's quote-blind, so a command that merely CONTAINS the text
# "; cd " inside a quoted argument (e.g. constructing a test payload, a grep pattern,
# documentation) gets denied even though no real cd ever runs there (confirmed real,
# caught testing this very hook). Position 0 doesn't have that problem -- for `cd` to
# be the literal first two characters of the trimmed string while ALSO being inside
# quotes, the string would have to start with a quote char, which fails `^cd` outright.
# This does mean a `cd` that isn't the command's own leading token (e.g. `echo hi; cd
# X`) is out of scope -- deliberate, matches "leading cd" in this hook's own name/intent,
# not a broader "cd anywhere" scan.
printf '%s' "$trimmed" | grep -qP '^cd\s+\S' || exit 0

# Target = everything after `cd ` up to the first unquoted &&/;/| or end of string --
# stop the capture at the first operator so a compound form's trailing command never
# gets swallowed into "target".
target="$(printf '%s' "$trimmed" | grep -oP '^cd\s+"?\K[^"&;|]+' | head -1 | sed -e 's/[[:space:]]*$//')"
[ -n "$target" ] || exit 0
target="${target/#\$HOME/$HOME}"
target="${target/#\~/$HOME}"

# Resolve this session's home directory the same way on-prompt.sh tracks it -- the
# directory of its recorded chat log file. Fail open if unavailable, don't block on
# incomplete info.
home=""
if [ -n "$sid" ] && [ -f "$HOME/.claude/.session-chatfiles/$sid" ]; then
  home="$(dirname "$(cat "$HOME/.claude/.session-chatfiles/$sid")")"
fi
[ -n "$home" ] || home="$cwd"
[ -n "$home" ] || exit 0

# Also folds POSIX drive form (/c/...) to Windows form (c:/...) -- $HOME expands to
# the former in this git-bash environment, the hook's own cwd/target fields use the
# latter, so the home-dir allow-path silently never matched without this.
norm() { printf '%s' "$1" | tr '\134' '/' | tr '[:upper:]' '[:lower:]' | sed -e 's:/*$::' -e 's|^/\([a-z]\)/|\1:/|'; }
# Home-dir exemption covers the BARE form only. `cd <home>` alone is the corrective
# return this exemption exists for; the COMPOUND form (`cd <home>; cmd`/`&& cmd`/
# `| cmd`) is separately harmful: on git-bash Claude Code can't statically determine a
# cd-compound's final cwd, so relative write targets can't be checked and the call is
# refused delegation to the auto-approval classifier -- manual permission prompt every
# time (confirmed 2026-08-17). Denying it pushes the prescribed no-`cd` form
# (`bash "$HOME/x.sh" ...`), which classifies clean. Bare = nothing but optional quote
# and whitespace after the target; the target capture already stops at `"&;|`, so any
# operator following it fails the `$` anchor.
athome=0
if [ "$(norm "$target")" = "$(norm "$home")" ]; then
  printf '%s' "$trimmed" | grep -qP '^cd\s+"?[^"&;|]+"?\s*$' && exit 0
  athome=1
fi

# Two reasons, because the two cases fail for DIFFERENT reasons and one message can't
# honestly cover both: a foreign target leaks cwd forward, while a compound to the
# session's OWN home leaks nothing (target already IS cwd) -- it's denied because Claude
# Code can't statically resolve a cd-compound's final cwd on git-bash and so refuses to
# delegate the call to the auto-approval classifier at all. Saying "leaks cwd forward"
# there is simply false, and the old single-branch message also closed with "a bare cd
# back TO that directory is fine and was allowed" while denying.
jq -cn --arg t "$target" --arg h "$home" --arg athome "$athome" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: (if $athome == "1" then ("Leading `cd " + $t + "` is this session'"'"'s own home directory, so a BARE `cd " + $t + "` would be allowed -- but this one is a compound (`; <command>`/`&& <command>`/`| <command>`), and that shape is refused for a different reason: on git-bash Claude Code cannot statically determine a cd-compound'"'"'s final working directory, so relative write targets cannot be checked and the whole call is refused delegation to the auto-approval classifier -- a manual permission prompt every time. Drop the `cd` entirely and use absolute paths: `bash \"$HOME/x.sh\" ...`, `git -C " + $t + " ...`, `ls -la " + $t + "/`. Need cwd genuinely set? `(cd " + $t + " && <command>)` -- real subshell parens.") else ("Leading, unparenthesized `cd " + $t + "` -- this session'"'"'s shell cwd persists across separate Bash/PowerShell calls, so this leaks cwd forward into every later call, whether bare (`cd " + $t + "` alone) or compound (`cd " + $t + " && <command>`/`; <command>`/`| <command>` -- the && form is NOT safe, only real subshell parens scope a cd). Prefer passing the path as an argument instead -- `git -C " + $t + " ...`, `ls -la " + $t + "/`, `jq ... " + $t + "/file` -- or wrap it as a genuine subshell: `(cd " + $t + " && <command>)`. This session'"'"'s home directory is " + $h + " -- a bare cd back TO that directory is fine and was allowed.") end)
  }
}'
