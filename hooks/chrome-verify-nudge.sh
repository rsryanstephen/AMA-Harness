#!/usr/bin/env bash
# Two wirings, one file:
#   PreToolUse (Skill)            -- a UI-driving skill was invoked
#   PreToolUse (Bash|PowerShell)  -- Playwright is being driven by hand, skill or not
#
# Reminds to use Claude-in-Chrome rather than defaulting to headless Playwright, which has
# real confirmed friction with MatDialog/CDK overlay interactions (PROJ-15260: Customize
# dialog never opened under synthetic clicks; 2026-08-17: the Save Report dialog never opened
# either, blocking a fresh-save regression test) -- and which some repos (reports, manage,
# search) have no headless path for at all.
#
# The branch that matters. This hook used to say "check whether the chrome tools are already
# in your list; if not, tell the user to relaunch with --chrome". That delegated the decision
# to the model and offered the relaunch branch unconditionally -- and an agent that skipped
# the check landed straight on the wrong branch. Confirmed live 2026-08-17: chrome-by-default
# was ON, the mcp__claude-in-chrome__* tools were in the session's deferred-tool list the whole
# time, and the agent still told the user to exit and relaunch. A bash hook genuinely cannot
# see the model's tool list -- but it CAN read the flag that decides it, so it does that here
# instead of asking.
set -u

payload="$(cat)"

skill="$(printf '%s' "$payload" | jq -r '.tool_input.skill // empty')"
if [ -n "$skill" ]; then
  case "$skill" in
    ama-ui-verify|ama-report-debug|verify|run) ;;
    *) exit 0 ;;
  esac
else
  # Hand-rolled Playwright: the Skill matcher never fires once the agent leaves the skill and
  # drives a scratchpad .mjs directly, which is exactly how the 2026-08-17 case played out.
  command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
  [ -n "$command" ] || exit 0
  case "$command" in
    *playwright*|*verify-ui.mjs*|*chromium.launch*) ;;
    *) exit 0 ;;
  esac
fi

SELECT='ToolSearch(select:mcp__claude-in-chrome__tabs_context_mcp,mcp__claude-in-chrome__navigate,mcp__claude-in-chrome__computer,mcp__claude-in-chrome__read_page,mcp__claude-in-chrome__get_page_text,mcp__claude-in-chrome__tabs_create_mcp,mcp__claude-in-chrome__tabs_close_mcp)'

# ~/.claude.json is Claude Code's own config; the /chrome "Enabled by default" opt-in writes
# this top-level flag. Missing file / unparseable / absent key all read as "not enabled".
# Fed on STDIN, not as a path argument: jq here is the native Windows exe and cannot resolve
# an MSYS /c/... path, so `jq ... "$HOME/.claude.json"` fails "No such file or directory" and
# would silently take the wrong branch (caught while testing this hook).
chrome_default="$(jq -r 'if .claudeInChromeDefaultEnabled == true then "true" else "false" end' \
  < "$HOME/.claude.json" 2>/dev/null || echo false)"
[ -n "$chrome_default" ] || chrome_default=false

if [ "$chrome_default" = "true" ]; then
  reason="Chrome-by-default is ON for this machine (claudeInChromeDefaultEnabled: true in ~/.claude.json), so the mcp__claude-in-chrome__* tools ARE available to this session -- they sit in your deferred-tool list until loaded. Load them and drive Chrome: ${SELECT}. Every tool on that server is allowlisted, so driving runs unattended -- no per-click prompt, no need for the user to be present. Do NOT tell the user to exit or relaunch with --chrome; it is already enabled, and saying otherwise wastes a restart (confirmed live 2026-08-17). Do NOT re-litigate prerequisites (extension installed, plan type, /login auth, extension version) -- they were settled at install time; treat Chrome as available and just try. THE ONE THING TO ASK FOR: if a call reports no connected browser / extension not connected, Chrome simply is not running -- ask the user to open Chrome, then retry the same call. Do not silently fall back to headless Playwright instead of asking. Headless Playwright stays correct only for genuinely unattended runs where no browser can be opened at all."
else
  reason="Before defaulting to headless Playwright: check whether claude-in-chrome browser tools are already in this session's tool list (try ${SELECT}). If they are not, and the task allows it, tell the user they can relaunch with \`claude --continue --chrome\` (or \`--resume <id> --chrome\`) to reattach with attended Chrome control -- avoids the headless MatDialog/CDK-overlay dead ends confirmed in PROJ-15260 and the Save Report dialog case. Both self-verify methods stay valid; this is a reminder to consider --chrome first, not a mandate."
fi

jq -cn --arg reason "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    permissionDecisionReason: $reason
  }
}'
