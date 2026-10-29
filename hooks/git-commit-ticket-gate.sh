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
# out of -- simple -m "..."/'...' form, the heredoc `-m "$(cat <<'EOF' ...)"` form this
# project's own conventions use, a heredoc attached to `-F -`, or a readable `-F <file>`.
# Anything else (bare `git commit --amend --no-edit`, `-c`/`--fixup`/`--squash`, an
# editor-opening commit, an unlocatable message file) is let through unchecked rather than
# blocked on a guess -- fails open on ambiguity, fails closed when a message was actually
# found and it's missing the ticket ref.
#
# ONE deliberate exception to fail-open, added after a confirmed live bypass: a commit whose
# message comes from STDIN (`printf ... | git commit -F -`) is DENIED even though no message
# was extracted. That shape isn't ambiguous, it's concealed -- the text exists nowhere in the
# command, so it can't be checked now and can't be reconstructed later. See the -F block
# below for the incident. Extraction is always tried first: `--amend -F -` with the heredoc
# attached to the same command is a documented workaround (bash-command-correctness) for PowerShell
# here-strings mangling a commit subject, and it still passes.
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

. "$HOME/.claude/hooks/lib-git-target.sh" 2>/dev/null || exit 0
target_dir="$(git_target_dir "$command" "$cwd")"

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

  # That literal list was incomplete, and the two paths to the same file disagreed about why
  # they were gated (flagged by session 431272bb). `memory`, `Chat files`, `sessions.md`,
  # `AGENTS.md`, `README.md`, `harness-gaps.md` and the two example configs are ALL links into
  # the harness too; of those the DIRECTORY links are what a `git -C` can target, so
  # `git -C ~/.claude/memory commit ...` was real harness code going through ungated while the
  # same commit issued against ~/Repos/.../ama-claude-harness was gated.
  #
  # Resolve the link instead of enumerating names: every directory linked in from the harness
  # resolves under the harness root, while ~/.claude itself resolves to ~/.claude -- so personal
  # content (settings.json, plans/, session state) stays excluded for free and both notations
  # land on the same branch. `readlink -f` returns POSIX form when it actually followed a link
  # and echoes the input form when it didn't, so normalise both sides and derive the root's two
  # notations the same way as ~/.claude above. Two forks, only for a commit already under
  # ~/.claude -- cheaper than the `git rev-parse --show-toplevel` alternative (also verified to
  # work) in a hook whose header optimises forks at ~60ms each.
  resolved="$(readlink -f "$target_dir" 2>/dev/null | tr '\134' '/' | tr '[:upper:]' '[:lower:]')"
  hroot="$(readlink -f "$HOME/.claude/skills" 2>/dev/null | tr '\134' '/' | tr '[:upper:]' '[:lower:]')"
  hroot="${hroot%/skills}"
  if [ -n "$resolved" ] && [ -n "$hroot" ]; then
    hroot_win=""
    if [[ "$hroot" =~ ^/([a-z])/(.*)$ ]]; then
      hroot_win="${BASH_REMATCH[1]}:/${BASH_REMATCH[2]}"
    fi
    if [ "$resolved" = "$hroot" ] || [ "${resolved#"$hroot"/}" != "$resolved" ]; then
      is_harness_subtree=true
    elif [ -n "$hroot_win" ] && { [ "$resolved" = "$hroot_win" ] || [ "${resolved#"$hroot_win"/}" != "$resolved" ]; }; then
      is_harness_subtree=true
    fi
  fi

  # Fallback to the original literal list, kept so a readlink failure (or a harness installed by
  # copy rather than by link) cannot LOSE protection the list already gave. Strictly additive.
  if [ "$is_harness_subtree" != true ]; then
    for base in "$posix_claude_dir" "$win_claude_dir"; do
      [ -n "$base" ] || continue
      for sub in "/skills" "/hooks" "/claude.md" "/harness-config.json"; do
        full="${base}${sub}"
        case "$norm" in "$full"|"$full"/*) is_harness_subtree=true ;; esac
      done
    done
  fi
  [ "$is_harness_subtree" = true ] || exit 0
fi

# Must anchor to an actual command position (start of string, or right after ;/&/|) --
# NOT just "the words git and commit appear somewhere in this string". Confirmed real
# false-positive: an unanchored check fired on a Bash call that was actually testing THIS
# hook, because the test script's fixture data merely contained the text "git commit"
# inside a quoted argument, nowhere near being an actual command being run.
# `-C <path>` (with its value) can sit between "git" and "commit"; handle that one real
# shape explicitly rather than trying to parse every possible git flag.
#
# Anchor against the HEREDOC-STRIPPED text, not the raw command. A command that writes a script
# whose own text contains `git commit ...` is not a command that commits, and the anchor alone
# can't tell the difference -- that was survivable while only `-m` was parsed (the stripping
# below neutralised it downstream), but the `-F` handling added later reaches a DENY, so a
# `cat > t.sh <<'SH' ... git commit -F - <<'EOF' ... SH` call was denied outright with no commit
# in it. Stripping first fixes the whole class at the anchor instead of per-extractor. Costs one
# awk fork on any payload containing "commit"; extraction still reads the RAW command, because
# a heredoc body is exactly where an attached message lives.
stripped="$(printf '%s\n' "$command" | awk '
  inhd { if ($0 ~ ("^[[:space:]]*" d "[[:space:]]*$")) { inhd=0 } ; next }
  {
    print
    if (match($0, /<<-?[[:space:]]*[^[:space:]|;&>()]*/)) {
      tok = substr($0, RSTART, RLENGTH)
      sub(/^<<-?[[:space:]]*/, "", tok)
      gsub(/[^A-Za-z0-9_]/, "", tok)
      if (tok != "") { d = tok; inhd = 1 }
    }
  }
')"
printf '%s' "$stripped" | grep -qP '(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?commit\b' || exit 0

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
#
# Heredoc BODIES are stripped first. Restricting the block above to -m-attached heredocs
# fixed half the false-positive class; this is the other half. A command that writes a
# script or message file via heredoc and then commits has `-m "..."` text sitting INSIDE
# that body -- e.g. `cat > t.sh <<'SH' ... git commit -m "$K: ..." ... SH` -- and the
# unstripped scan read that as this commit's message, denying a commit whose real message
# was fine. Hit three times on 2026-08-18 before being fixed properly.
if [ -z "$msg" ]; then
  # $stripped is computed once, above the anchor check.
  msg="$(printf '%s' "$stripped" | grep -oP -- "-m\s+\"\K[^\"]*" | head -1)"
  [ -z "$msg" ] && msg="$(printf '%s' "$stripped" | grep -oP -- "-m\s+'\K[^']*" | head -1)"
fi

# -F / --file forms. `git commit -F -` reads the message from STDIN, which never appears in the
# command text at all: both extractors above find nothing, execution reaches the fail-open exit
# below, and the gate is bypassed completely. Confirmed live 2026-08-18 -- a harness commit to
# skills/ landed with NO ticket ref (the only such commit in this repo's history) while the very
# next commit, identical in kind but written with -m, was correctly denied. Enforcement can't
# depend on which flag the agent happens to reach for, and -F is the MORE natural shape for a
# multi-paragraph message.
#
# Order matters: extract first, deny only as a last resort. `--amend -F -` with a heredoc is the
# shape bash-command-correctness documents as the fix for PowerShell here-strings mangling a commit
# subject, so it has to keep working.
if [ -z "$msg" ]; then
  # \042 \047 = " and ' -- octal rather than nested shell quoting, which is how this line first
  # shipped a syntax error that made the WHOLE hook exit 2 and therefore fail open silently.
  # Read the flag off $stripped, so a `-F` sitting in a script body being written doesn't count.
  # All four spellings git accepts: `-F x`, `-Fx` (short options glue), `--file=x`, `--file x`.
  # Matching only `-F\s+` and `--file=` left `git commit -F-` as the same total bypass by a
  # different spelling.
  ffile="$(printf '%s' "$stripped" | grep -oP -- '(-F\s*|--file[=\s]\s*)\K\S+' | head -1 | tr -d '\042\047')"
  if [ "$ffile" = "-" ]; then
    # Heredoc trailing the commit's own args: `git commit -F - <<'EOF'`. A DIFFERENT parse from
    # the -m form above, where the marker is glued to the flag -- here the redirect follows the
    # arguments. Deliberately requires the marker on the SAME line as the commit: an unrelated
    # heredoc elsewhere in the command (a script or message file being written) is not this
    # commit's message, which is exactly the false-positive class the -m extractor above had to
    # be narrowed for.
    #
    # Known residual: this greps the RAW command (it must -- the message lives in a heredoc body),
    # while `ffile` above comes from the stripped text. A command whose heredoc body contains a
    # FAKE `git commit -F - <<'EOF'` line AND which also really commits with -F - would take its
    # message from the script text. Contrived enough to document rather than build machinery for;
    # the realistic shapes (a body containing a commit and nothing real, two heredocs where the
    # commit owns the second) are both covered by cases.
    hline="$(printf '%s\n' "$command" | grep -nP '(^|[;&|])\s*git\s+(-C\s+\S+\s+)?commit\b.*(-F\s*-|--file[=\s]\s*-).*<<' | head -1)"
    if [ -n "$hline" ]; then
      delim2="$(printf '%s' "$hline" | grep -oP '<<-?\s*.?\K[A-Za-z_][A-Za-z0-9_]*' | head -1)"
      lno="${hline%%:*}"
      [ -n "$delim2" ] && msg="$(printf '%s\n' "$command" | sed -n "$((lno + 1))p")"
    fi
    if [ -z "$msg" ]; then
      # Genuinely invisible -- piped in (`printf ... | git commit -F -`, and the pipe is itself
      # one of the command anchors above, so it reaches here) or otherwise sourced off-command.
      # The ONE place this hook does not fail open: the message is hidden by the shape chosen,
      # not merely ambiguous, so there is nothing to guess at and no way to check it later.
      jq -cn --arg proj "$jira_project" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: ("This commit reads its message from stdin (-F -), so the hook cannot see it and cannot confirm the " + $proj + "-XXXXX: ticket ref the commit-ticket skill requires. Use a shape whose message is visible: attach the heredoc to this same command (git commit -F - <<MSG on one line, message, then MSG), pass a real file (-F msg.txt), or use -m for a single-line message.")
        }
      }'
      exit 0
    fi
  elif [ -n "$ffile" ]; then
    # A real message file: read it the way git will. Try the path as given, then relative to the
    # command's target dir, then the session cwd.
    # Expand a literal "$HOME"/"${HOME}" prefix, exactly as target_dir does above and for the
    # same reason: this codebase's own commands write "$HOME/..." into the command string, which
    # the hook sees UNexpanded. Without this, `git commit -F "$HOME/scratch/msg.txt"` -- the more
    # natural of the two -F <file> shapes in this repo -- failed all three [ -f ] probes and fell
    # straight back through to fail-open, i.e. the bypass this block exists to close.
    ffile="${ffile/#\$\{HOME\}/$HOME}"
    ffile="${ffile/#\$HOME/$HOME}"
    fpath=""
    [ -f "$ffile" ] && fpath="$ffile"
    [ -z "$fpath" ] && [ -f "$target_dir/$ffile" ] && fpath="$target_dir/$ffile"
    [ -z "$fpath" ] && [ -f "$cwd/$ffile" ] && fpath="$cwd/$ffile"
    # Can't locate it -- stay fail-open. A file the hook merely cannot find is ambiguity, not
    # concealment, and blocking would be blocking on a guess.
    [ -n "$fpath" ] && msg="$(head -1 "$fpath" 2>/dev/null | tr -d '\r')"
  fi
fi

# Couldn't confidently extract a message -- fail open, don't block on a guess. Still the rule for
# `--amend --no-edit`, `-c`/`--reuse-message`, `--fixup`/`--squash` and editor-opening commits:
# each either reuses a message that was already gated when first written, or puts a human in the
# loop. Only the stdin case above is treated as concealment rather than ambiguity.
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
