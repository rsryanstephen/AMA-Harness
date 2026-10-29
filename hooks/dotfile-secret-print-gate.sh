#!/usr/bin/env bash
# PreToolUse (Read|Grep, and Bash|PowerShell via dispatch). Denies PRINTING a credential file:
# ~/.secrets (where the harness's API keys live, sourced by ~/.bashrc) -- or ~/.bashrc,
# ~/.bash_profile, ~/.profile while one of them still holds a credential-named export.
# A print puts every key into the tool result and the transcript.
#
# Hit live 2026-10-28, twice in one session: a Read of ~/.bashrc lines 60-72 leaked 6 keys, then
# `tail -n 3 ~/.bashrc` (checking HIST settings) printed a freshly appended DTrack key. Keys
# moved to ~/.secrets the same day so .bashrc is safe to view again.
#
# Allowed on a protected file: source/`.`, test/[ -f ], ls, stat, wc, chmod, touch, opening it
# in an editor (code/notepad), sed -i, a redirect TARGET (> / >>), and grep -c/-q/-l/-L, or
# grep -o with a pattern that stops at `=` (names only: grep -n -o '^export [A-Za-z_]*=' f).
# Everything else naming it (cat, head, tail, sed -n, Get-Content, awk, plain grep) is denied.
# No hatch: the user can open the file themselves. Scripts run via `bash file` are not
# inspected (only the command line) -- a script that reads a key into a variable is fine.
set -u
payload="$(cat)"
case "$payload" in *.secrets*|*.bashrc*|*.bash_profile*|*.profile*) ;; *) exit 0 ;; esac

CRED='^[[:space:]]*export[[:space:]]+[A-Za-z0-9_]*([Kk][Ee][Yy]|TOKEN|_PAT|PAT=|PASS|SECRET|_[Pp][Ww])[A-Za-z0-9_]*='
FILES='\.(secrets|bashrc|bash_profile|profile)'
# Is ~/.<name> protected right now?
protected() {
  case "$1" in
    secrets) return 0 ;;
    *) grep -qE "$CRED" "$HOME/.$1" 2>/dev/null ;;
  esac
}
deny() {
  jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}
MSG="holds the harness's API keys -- printing it puts every key into the transcript (leaked twice 2026-10-28). Check names only: grep -n -o '^export [A-Za-z_]*=' <file>; test a key's shape or auth inside a script file that never echoes it; or ask the user to look."

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' | tr -d '\r')"
case "$tool" in
  Read|Grep)
    p="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.path // empty' | tr -d '\r')"
    p="${p//\\//}"
    [[ "$p" =~ (^|/)${FILES}$ ]] || exit 0
    name="${BASH_REMATCH[2]}"
    if [ "$tool" = Grep ]; then
      mode="$(printf '%s' "$payload" | jq -r '.tool_input.output_mode // "files_with_matches"' | tr -d '\r')"
      [ "$mode" = content ] || exit 0
    fi
    protected "$name" && deny "$p $MSG"
    exit 0 ;;
  Bash|PowerShell) ;;
  *) exit 0 ;;
esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' | tr -d '\r')"
[ -n "$command" ] || exit 0
. "$HOME/.claude/hooks/lib-command-text.sh" 2>/dev/null && command="$(printf '%s' "$command" | command_without_heredoc_bodies)"

# One segment per simple command. Regexes live in variables: unquoted =~ escaping is fragile.
RE_PATH="(^|[/\\\\~[:space:]\"'])${FILES}([[:space:]\"']|\$)"
RE_SEDI='[[:space:]]-[a-zA-Z]*i'
RE_SEDN='[[:space:]]-n'
RE_GCNT='[[:space:]]-[a-zA-Z]*[cqlL]'
RE_GO='[[:space:]]-[a-zA-Z]*o'
RE_EQ_END="=[\"']?([[:space:]]|\$)"
RE_EQ_MORE="=[^\"'[:space:]]"
segs="$(printf '%s\n' "$command" | sed -E 's/(\|\||&&|[;|&])/\n/g')"
while IFS= read -r seg; do
  [[ "$seg" =~ $RE_PATH ]] || continue
  name="${BASH_REMATCH[2]}"
  protected "$name" || continue
  # Path only as a redirect target (echo ... >> ~/.secrets): nothing is read.
  rest="$(printf '%s' "$seg" | sed -E "s#[0-9]?>>?[[:space:]]*[^[:space:]]*${FILES}[\"']?##g")"
  [[ "$rest" =~ $FILES ]] || continue
  w="$(printf '%s' "$seg" | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//' | awk '{print $1}')"
  w="${w##*/}"; w="${w%.exe}"
  case "$w" in
    .|source|test|'['|'[['|ls|stat|wc|chmod|touch|code|notepad|Test-Path) continue ;;
    sed) [[ "$seg" =~ $RE_SEDI ]] && ! [[ "$seg" =~ $RE_SEDN ]] && continue ;;
    grep|egrep|rg)
      [[ "$seg" =~ $RE_GCNT ]] && continue
      [[ "$seg" =~ $RE_GO ]] && [[ "$seg" =~ $RE_EQ_END ]] && ! [[ "$seg" =~ $RE_EQ_MORE ]] && continue ;;
  esac
  deny "Command reads ~/.$name, which $MSG"
done <<< "$segs"
exit 0
