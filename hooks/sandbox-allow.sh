#!/usr/bin/env bash
# PreToolUse hook for all tools (Bash, PowerShell, Read, Write, Edit, MCP, etc).
# When cwd is inside ~/.claude/, a Claude Code scratchpad temp dir, or one of THIS
# adopter's own configured trusted roots, returns "allow" so the call bypasses
# user-level deny rules and prompts and runs without prompting. Otherwise stays silent
# and lets the static permission rules decide.
#
# Configure trusted roots in ~/.claude/.harness-local.json's `sandboxTrustedRoots`
# array (see .harness-local.json.example in this repo for the schema, or run
# /harness-setup) -- ~/.claude and the scratchpad are always trusted (portable,
# derived from $HOME, safe for any adopter); everything else is opt-in per machine.
# Was hardcoded to Your Name's own `~/Repos/` convention until PROJ-15143 wave 2 made
# it configurable -- a new adopter's repos won't necessarily live there.
#
# NOTE: this does NOT and CANNOT suppress Claude Code's own hardcoded
# suspiciousPathGuard (fires on 8.3 short-form path segments like "RYAN~1.STE" nested in
# a longer path) -- that check runs after and independent of any PreToolUse hook
# decision, confirmed non-overridable (github.com/anthropics/claude-code/issues/54927).
# Root fix for that is the TEMP/TMP env var, not this hook -- recipe in the
# bash-command-style skill ("8.3 short paths"), applied on this machine 2026-08-17. A
# PreToolUse DENY does fire before that guard though (proven live), so short-path-gate.sh
# turns the prompt into an agent self-correction for anything still carrying a short path.

set -u

logfile="$HOME/.claude/hooks/sandbox-allow.log"
# Debug logging (INPUT/CWD/normalized/match-result lines) is OFF by default -- it was
# unconditional, forking `date` per line plus an append, on every single tool call, and
# had grown sandbox-allow.log to 33MB/99k lines of verbatim tool payloads (a secret-at-
# rest concern on top of the perf cost). Set SANDBOX_ALLOW_DEBUG=1 to re-enable for
# troubleshooting -- the lines themselves are kept, not deleted, per <harnessEpicKey>.
debug=0; [ -n "${SANDBOX_ALLOW_DEBUG:-}" ] && debug=1

input=$(cat)
[ "$debug" = 1 ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] INPUT: $input" >> "$logfile" 2>&1

# Single jq call for both fields instead of two -- same `// ""` defaulting, order fixed
# (cwd then file_path) so the two `read`s line up positionally.
cwd=""; file_path=""
{ IFS= read -r cwd; IFS= read -r file_path; } < <(printf '%s' "$input" | jq -r '.cwd // "", (.tool_input.file_path // "")' 2>/dev/null)
# jq.exe emits CRLF; $(...) command substitution silently drops the trailing \r along
# with \n (confirmed via isolated test -- an MSYS pipe-interop quirk), but `read` from
# a process substitution does not, so a stray \r otherwise survives into $cwd and
# breaks every path comparison below. Strip it explicitly to match old behavior.
cwd="${cwd%$'\r'}"; file_path="${file_path%$'\r'}"
[ "$debug" = 1 ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] CWD extracted: '$cwd', file_path: '$file_path'" >> "$logfile" 2>&1

# sed 's|\\|/|g' | tr upper->lower, as pure bash: single-backslash-to-slash (confirmed
# via isolated test this is a SINGLE-backslash pattern, unlike line 74's r_norm below
# which uses a DOUBLE-backslash pattern -- different semantics, left untouched).
norm_cwd="${cwd//\\//}"; norm_cwd="${norm_cwd,,}"
norm_fp="${file_path//\\//}"; norm_fp="${norm_fp,,}"
[ "$debug" = 1 ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] Normalized cwd: '$norm_cwd', file_path: '$norm_fp'" >> "$logfile" 2>&1

# Derive trusted roots from this process's own real $HOME, not a hardcoded username --
# portable across whoever's account this hook actually runs under. $HOME is POSIX-form
# in git-bash ("/c/Users/...") but the payload's cwd/file_path can arrive in either POSIX
# or Windows drive-letter form -- compute both so either notation matches.
posix_home="${HOME//\\//}"; posix_home="${posix_home,,}"
win_home=""
if [[ "$posix_home" =~ ^/([a-z])/(.*)$ ]]; then
  win_home="${BASH_REMATCH[1]}:/${BASH_REMATCH[2]}"
fi

# PROJ-15143 wave 2: adopter's trusted root(s) come entirely from config now --
# no hardcoded path convention. One small jq read, no scan/git/resolver call in this
# hot path (runs on every tool call).
extra_roots=""
local_file="$HOME/.claude/.harness-local.json"
if [ -f "$local_file" ]; then
  extra_roots="$(jq -r '.sandboxTrustedRoots // [] | .[] | if type=="string" then . else .path end' "$local_file" 2>/dev/null)"
fi

matches() {
  local p="$1"
  for home in "$posix_home" "$win_home"; do
    [ -z "$home" ] && continue
    case "$p" in
      "$home/.claude"|"$home/.claude"/*) return 0 ;;
    esac
  done
  case "$p" in
    # Claude Code's own per-session scratchpad root, any Windows user path form (long
    # username or its short 8.3 alias) -- always trusted, it's Claude Code's own managed
    # temp area, not user/repo content.
    */appdata/local/temp/claude|*/appdata/local/temp/claude/*) return 0 ;;
  esac
  if [ -n "$extra_roots" ]; then
    local r r_expanded r_norm r_win
    while IFS= read -r r; do
      r="${r%$'\r'}"
      [ -n "$r" ] || continue
      r_expanded="${r/#\~/$HOME}"
      # sed 's|\\\\|/|g' | tr, as pure bash: this one is the DOUBLE-backslash pattern
      # (collapses a \\ pair to /, leaves single \ alone -- confirmed via isolated
      # test), hence the doubled escape in the pattern half, unlike norm_cwd above.
      r_norm="${r_expanded//\\\\//}"; r_norm="${r_norm,,}"
      case "$p" in
        "$r_norm"|"$r_norm"/*) return 0 ;;
      esac
      # Same POSIX<->Windows-drive-form duality as posix_home/win_home above --
      # ~-expansion yields POSIX form but the payload can arrive in either.
      r_win=""
      if [[ "$r_norm" =~ ^/([a-z])/(.*)$ ]]; then
        r_win="${BASH_REMATCH[1]}:/${BASH_REMATCH[2]}"
        case "$p" in
          "$r_win"|"$r_win"/*) return 0 ;;
        esac
      fi
    done <<< "$extra_roots"
  fi
  return 1
}

if matches "$norm_cwd" || { [ -n "$norm_fp" ] && matches "$norm_fp"; }; then
  [ "$debug" = 1 ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] MATCH! Returning allow" >> "$logfile" 2>&1
  if [ "$debug" = 1 ]; then
    jq -nc '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        permissionDecisionReason: "Sandbox auto-approve: cwd or target path is under a trusted root (~/.claude/, the Claude scratchpad temp dir, or a root configured in ~/.claude/.harness-local.json'\''s sandboxTrustedRoots)"
      }
    }' | tee -a "$logfile"
  else
    jq -nc '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        permissionDecisionReason: "Sandbox auto-approve: cwd or target path is under a trusted root (~/.claude/, the Claude scratchpad temp dir, or a root configured in ~/.claude/.harness-local.json'\''s sandboxTrustedRoots)"
      }
    }'
  fi
else
  [ "$debug" = 1 ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] No match for cwd='$norm_cwd' file_path='$norm_fp'" >> "$logfile" 2>&1
fi

exit 0