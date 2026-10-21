#!/usr/bin/env bash
# PreToolUse hook (Bash/PowerShell). Denies giving THIS repo (ama-claude-harness) a
# github.com remote, or pushing it to a github.com URL directly. The public mirror is a
# sanitized single-commit snapshot published ONLY via scripts/publish-public.sh (AGENTS.md
# "Public GitHub mirror") -- raw history reaching GitHub is unrecoverable there (GitHub
# keeps force-pushed-away commits fetchable by SHA; delete-and-recreate is the only
# cleanup). Rule was prose-only until PROJ-15361's hookability audit.
#
# Scope: only commands whose target repo resolves to the harness repo root. ~/.claude
# itself (Claude-Config) legitimately pushes to its own private GitHub remote -- a
# DIFFERENT repo root, never matched. publish-public.sh's internal push never appears in
# a PreToolUse command (it runs inside the script), so no exemption is needed.
set -u

IFS= read -r -d '' payload || true
# Cheap raw needle before any fork (precedent: bare-cd-gate.sh).
case "$payload" in *github*) ;; *) exit 0 ;; esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' | tr -d '\r')"
[ -n "$command" ] || exit 0
flat="$(printf '%s' "$command" | tr '\n' ';')"

# Verb must directly follow `git` (allowing only a -C <path> between) -- an anywhere-match
# was rejected as quote-blind (a commit message DESCRIBING the rule would deny itself,
# bare-cd-gate.sh hit exactly that class).
printf '%s' "$flat" | grep -qiE '\bgit\s+(-C[= ]+"?[^ ";|&]+"?\s+)?(remote\s+(add|set-url)|push)\b[^;|&]*github\.com' || exit 0

# Which repo does the command act on? -C <path> wins, else the call's cwd.
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' | tr -d '\r')"
cdir="$(printf '%s' "$flat" | grep -oP '(?<!\S)-C[= ]+"?\K[^ ";|&]+' | head -1)"
dir="${cdir:-$cwd}"
[ -n "$dir" ] || exit 0
dir="${dir/#\$HOME/$HOME}"
dir="${dir/#\~/$HOME}"

harness="$(git -C "$HOME/.claude/hooks" rev-parse --show-toplevel 2>/dev/null)"
target="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$harness" ] && [ -n "$target" ] || exit 0

# Same normalization as readme-currency-gate.sh / bare-cd-gate.sh (POSIX drive form fold).
norm() { printf '%s' "$1" | tr '\134' '/' | tr '[:upper:]' '[:lower:]' | sed -e 's:/*$::' -e 's|^/\([a-z]\)/|\1:/|'; }
[ "$(norm "$target")" = "$(norm "$harness")" ] || exit 0

jq -cn '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "This is the ama-claude-harness repo -- it must NEVER get a github.com remote or a direct push to a github.com URL (AGENTS.md \"Public GitHub mirror\": raw history on GitHub is unrecoverable -- force-pushed-away commits stay fetchable by SHA). The public mirror is published only as a sanitized snapshot via `bash scripts/publish-public.sh` (auto-fires from on-stop.sh after a harness commit lands). If you meant the ~/.claude config repo (Claude-Config), run the command with THAT repo as the cwd/-C target instead."
  }
}'
