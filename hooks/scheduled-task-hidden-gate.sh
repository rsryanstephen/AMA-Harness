#!/usr/bin/env bash
# PreToolUse hook (Bash/PowerShell). Denies registering a Windows Scheduled Task whose
# action doesn't route through the hidden-launch wrapper. <harnessEpicKey>.
#
# Why this exists as a mechanical gate, not just a documented rule: the two-layer
# hiding trick (CreateNoWindow + a non-console launcher) was already implemented once,
# for exactly one task (fleet-health-check), but was never documented outside that
# script's own header -- so the lesson never propagated, and three more scheduled
# tasks were registered calling bash.exe directly, each popping a visible,
# focus-stealing console. Per CLAUDE.md's "mechanical triggers over self-recognition"
# rule, prose alone already failed here once.
#
# The escape hatch this gate does NOT offer: `powershell.exe -WindowStyle Hidden`
# alone. Confirmed LIVE this session that it still flashes a console for one frame --
# powershell.exe is a console-subsystem executable, so Windows allocates its console at
# process creation, before the host can apply -WindowStyle to hide itself. The only
# mechanism that actually produces zero flash is scripts/run-hidden.vbs (wscript.exe is
# GUI-subsystem, never allocates a console at all). Don't reintroduce
# "-WindowStyle Hidden" as an allowed pattern here without re-confirming it live first.
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork (precedent: publish-scrub-gate.sh,
# bare-cd-gate.sh) -- neither substring present means this cannot be a task
# registration.
case "$payload" in
  *schtasks*|*ScheduledTask*) : ;;
  *) exit 0 ;;
esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
[ -n "$command" ] || exit 0
flat="$(printf '%s' "$command" | tr -d '\r')"

# FALSE-POSITIVE GUARD (added 2026-09-01). Writing ABOUT a task registration used to trip
# this gate exactly like performing one -- same class of bug vpn-dns-outage-logger.sh needed
# its own guard for. Both shapes were hit for real:
#   - `cat >> harness-gaps.md <<'EOF'` whose prose described this very bug, denied.
#   - a read-only `grep -n 'Register-ScheduledTask'` over the repo, denied.
# Neither can register anything; both merely contain the token.
#
# 1. Heredoc bodies are DATA, not command tokens. Precedent: the multi-line-string gate
#    already measures only the region before the first `<<`. Anything a heredoc feeds to a
#    shell would still have to name a registration command BEFORE the `<<` to run one.
. "$HOME/.claude/hooks/lib-command-text.sh" 2>/dev/null || command_scan_region() { printf '%s' "$1"; }
detect="$(command_scan_region "$flat")"

# 2. Read-only text tools: `grep -rn 'Register-ScheduledTask' hooks/`,
#    `Get-Content x.md | Select-String ...`, `echo '...Register-ScheduledTask...' >> notes`.
#    First word only -- a real registration does not start with grep.
#
#    NOTE a tempting third rule that is deliberately ABSENT: "require the command to also
#    invoke powershell/pwsh/schtasks, since the cmdlets can't run in bash anyway." It sounds
#    tighter and it is not -- check-gates.sh asserts a BARE `Register-ScheduledTask ...` under
#    a Bash payload must DENY, and that rule silently turned four established deny cases into
#    passes. The heredoc strip plus this guard already fix every observed false positive, so
#    the extra rule bought nothing and cost the gate's teeth.
first="$(printf '%s' "$detect" | sed -E 's/^[[:space:]]*//' | sed -E 's/[[:space:]].*$//')"
case "$first" in
  grep|egrep|fgrep|rg|cat|head|tail|less|echo|printf|sed|awk|jq|wc|diff|sort|uniq|Select-String|Get-Content|Write-Output|Write-Host)
    # A chained command could still register something, so "contains a pipe" is NOT enough
    # to deny on -- `Get-Content x.md | Select-String Register-ScheduledTask` is entirely
    # read-only and was still being denied. Test each chained SEGMENT instead: only a
    # segment that actually STARTS with something able to register counts.
    _reg=0
    while IFS= read -r _seg; do
      _seg="${_seg#"${_seg%%[![:space:]]*}"}"
      case "$_seg" in
        powershell*|pwsh*|schtasks*|Register-ScheduledTask*|New-ScheduledTaskAction*|'$'*) _reg=1 ;;
      esac
    done <<EOF
$(printf '%s' "$detect" | tr ';&|' '\n')
EOF
    [ "$_reg" -eq 1 ] || exit 0
    ;;
esac

# Only care about a CREATE. schtasks.exe /query, /delete, /change, /run don't register
# a new action, so they can't be the source of a new flash. Register-ScheduledTask and
# New-ScheduledTaskAction are inherently creation-shaped, no flag to check.
is_create=0
printf '%s' "$detect" | grep -qiE '\bRegister-ScheduledTask\b|\bNew-ScheduledTaskAction\b' && is_create=1
printf '%s' "$detect" | grep -qiE '\bschtasks(\.exe)?\b' \
  && printf '%s' "$detect" | grep -qiE '/create\b' && is_create=1
[ "$is_create" -eq 1 ] || exit 0

# Allow if the same command already routes through a known-safe wrapper: the bash-
# specific run-hidden.vbs, its full-command-line sibling run-hidden-generic.vbs (for a
# payload that isn't a bare bash command, e.g. an outer powershell.exe launch), or the
# pre-existing run-fleet-health-hidden.ps1 (now only reached FROM inside
# run-hidden-generic.vbs, never launched directly by Task Scheduler as of <harnessEpicKey>).
# $detect, not $flat: a heredoc BODY that happens to mention run-hidden.vbs must not
# whitelist a registration built in the command region before the `<<`.
if printf '%s' "$detect" | grep -qiE 'run-hidden(-generic)?\.vbs|run-fleet-health-hidden'; then
  exit 0
fi
# `schtasks /create /xml <file>`: the action lives in the FILE, not the command text (false-
# denied a correct /xml registration 2026-08-24). Read that file's <Command>/<Arguments> and
# apply the same check; unreadable file -> fall through to deny.
xml="$(printf '%s' "$detect" | grep -oiP '/xml\s+"?\K[^"[:space:]]+' | head -1)"
if [ -n "$xml" ]; then
  xml="${xml/#\~/$HOME}"; xml="${xml/#\$HOME/$HOME}"
  [[ "$xml" =~ ^([A-Za-z]):(/.*)$ ]] && xml="/$(printf '%s' "${BASH_REMATCH[1]}" | tr 'A-Z' 'a-z')${BASH_REMATCH[2]}"
  [ -f "$xml" ] && grep -iE '<(Command|Arguments)>' "$xml" 2>/dev/null \
    | grep -qiE 'run-hidden(-generic)?\.vbs|run-fleet-health-hidden' && exit 0
fi

jq -cn '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "This registers/updates a Scheduled Task action that does not route through scripts/run-hidden.vbs. Launching bash.exe/powershell.exe directly via Task Scheduler pops a visible console that steals foreground focus -- confirmed live, reproduced, and the whole reason this gate exists (<harnessEpicKey>, AGENTS.md). `-WindowStyle Hidden` on powershell.exe is NOT sufficient -- also confirmed live to still flash one frame; only wscript.exe (GUI-subsystem, no console at all) actually avoids it. Build the action as: Execute=wscript.exe, Argument=\"<repo>\\scripts\\run-hidden.vbs\" \"<bash command>\" -- or, for a dynamic one-shot task from bash, call scripts/register-hidden-task.ps1 instead of building the action by hand. See AGENTS.md'\''s scheduled-task section."
  }
}'
