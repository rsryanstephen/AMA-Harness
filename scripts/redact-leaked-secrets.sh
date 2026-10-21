#!/usr/bin/env bash
# Scrub leaked credentials out of Claude transcripts, chat logs and scratch files.
#
# Run this the moment a credential lands in tool output -- do NOT ask the user first, and do
# NOT recommend rotating on account of the transcript alone: ~/.claude/projects is gitignored
# (.gitignore:5) and the chat-log directories are not git repos, so nothing reaches a remote.
# Rotation is only warranted if the value leaked somewhere that IS published.
#
# usage: redact-leaked-secrets.sh [extra paths...]   (defaults cover the usual three)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULTS=(
    "$HOME/.claude/projects"
    "$HOME/.claude/scratch"
)
# Chat-log dirs vary per adopter; include whichever exist.
for d in "$HOME/Repos/AMA_APP/Local Chat Files" \
         "$HOME/Repos/AMA_APP/ama-claude-harness-local-chat-files" \
         "$HOME/Repos/AMA_APP/ama-claude-harness/Local Chat Files"; do
    [ -d "$d" ] && DEFAULTS+=("$d")
done

python "$HERE/redact-leaked-secrets.py" "${DEFAULTS[@]}" "$@"
