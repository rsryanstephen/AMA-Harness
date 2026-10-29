#!/usr/bin/env bash
# PreToolUse hook (Edit|Write, and Bash/PowerShell in-place edits). Denies editing a script
# that a LIVE process is currently executing. Bash reads a script lazily, so an edit landing
# mid-run corrupts the interpreter's view of the rest of the file (`line 84: the: command not
# found`, `syntax error near unexpected token ')'`) -- hit 4x in one week (2026-08-21..25):
# check-gates.sh edited by a concurrent session mid-suite, standup-unattended-run.sh edited
# while its 15-min headless run was in flight. bash-command-correctness already said so in
# prose; per CLAUDE.md's "Mechanical Triggers Over Self-Recognition", prose was not enough.
#
# No bookkeeping: asks Windows which processes have the target's BASENAME on their command
# line, restricted to interpreters (bash/sh/perl/python/node/pwsh/powershell) so an editor
# holding the file open never false-denies. ~0.5s PowerShell spawn, paid only for .sh/.ps1/
# .pl/.py/.js targets. Fails OPEN if the process list can't be read.
set -u

IFS= read -r -d '' payload || true
# Cheap pre-filter: only script-shaped targets can be mid-execution.
case "$payload" in *.sh*|*.ps1*|*.pl*|*.py*|*.js*|*.bash*) : ;; *) exit 0 ;; esac

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
case "$tool" in
  Edit|Write|MultiEdit|NotebookEdit)
    target="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')" ;;
  Bash|PowerShell)
    cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
    # Only an in-place rewrite of a script; a plain read/run of it is fine.
    printf '%s' "$cmd" | grep -qP '(^|[;&|]\s*)(sed\s+(-[a-zA-Z]*i|--in-place)|perl\s+-[a-zA-Z]*i)\b' || exit 0
    # The target is the in-place clause's own file, not any script the command names: `sed -i
    # x.mjs && bash run-ui-verify.sh --script x.mjs` was denied as an edit of run-ui-verify.sh
    # (2026-10-21). Clause not found (odd quoting) -> whole command, as before.
    clause="$(printf '%s' "$cmd" | grep -oP '(?:^|[;&|]\s*)\K(?:sed\s+(?:-[a-zA-Z]*i|--in-place)|perl\s+-[a-zA-Z]*i)\b[^;&|]*')"
    if [ -n "$clause" ] && ! printf '%s' "$clause" | grep -qP '\.(sh|bash|ps1|pl|py|js)\b'; then
      exit 0   # in-place edit of a non-script file (.mjs, .txt ...); later script names are not its target
    fi
    target="$(printf '%s' "${clause:-$cmd}" | grep -oP '[^\s"\x27]+\.(sh|bash|ps1|pl|py|js)\b' | tail -1)" ;;
  *) exit 0 ;;
esac
[ -n "$target" ] || exit 0
base="$(basename "$target")"
case "$base" in *.sh|*.bash|*.ps1|*.pl|*.py|*.js) : ;; *) exit 0 ;; esac

# Test seam: RUNNING_SCRIPT_CMDLINES = newline-separated fake command lines (check-gates.sh).
if [ -n "${RUNNING_SCRIPT_CMDLINES:-}" ]; then
  lines="$RUNNING_SCRIPT_CMDLINES"
else
  lines="$(powershell.exe -NoProfile -NonInteractive -Command \
    "Get-CimInstance Win32_Process -Filter \"Name='bash.exe' OR Name='sh.exe' OR Name='perl.exe' OR Name='python.exe' OR Name='node.exe' OR Name='pwsh.exe' OR Name='powershell.exe'\" | Select-Object -ExpandProperty CommandLine" 2>/dev/null | tr -d '\r')"
fi
[ -n "$lines" ] || exit 0

# The hook's own process line names this hook, not the target; a hit must name the TARGET's
# basename and not be a hook invocation reading stdin. Basename must be a whole path token:
# a plain substring match denied a scratch `patch.sh` because the live dispatcher's
# `dispatch.sh` contains it (2026-09-22, session 0338a6ba).
cands="$(printf '%s\n' "$lines" | grep -P -- "(^|[\\s/\\\\\"'])\Q$base\E(?=[\\s\"']|$)" | grep -vF 'running-script-edit-gate.sh')"
[ -n "$cands" ] || exit 0
# Same basename is not the same file: a worktree copy of a script the live install is running
# (pr-merge-watch.sh watchers run for days) was denied forever (2026-10-28). When the process
# line names an ABSOLUTE path and both resolve, a mismatch is a different file. A bare or
# relative name cannot be resolved from here -> still a hit.
real_of() { readlink -f "$(cygpath -u "$1" 2>/dev/null || printf '%s' "$1")" 2>/dev/null; }
tgt_real="$(real_of "$target")"
hit=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  tok="$(printf '%s' "$line" | grep -oP -- "[^\\s\"']*\Q$base\E(?=[\\s\"']|$)" | head -1)"
  case "$tok" in /*|[A-Za-z]:[\\/]*)
    run_real="$(real_of "$tok")"
    [ -n "$tgt_real" ] && [ -n "$run_real" ] && [ "$tgt_real" != "$run_real" ] && continue ;;
  esac
  hit="$line"; break
done <<< "$cands"
[ -n "$hit" ] || exit 0

jq -cn --arg b "$base" --arg h "$hit" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("`" + $b + "` is being EXECUTED right now by a live process -- bash reads scripts lazily, so editing it mid-run corrupts that run (`command not found` / `syntax error near unexpected token` at a line that is fine on disk afterwards). Live command line: " + $h + ". Wait for it to finish (or stop it deliberately, if it is yours and disposable), then edit. If it is another session'"'"'s run, do not kill it -- edit later. See bash-command-correctness.")
  }
}'
