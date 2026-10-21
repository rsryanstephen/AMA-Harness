#!/usr/bin/env bash
# Hold a Claude-started dev server open for the USER's own local sign-off, so
# dev-server-teardown-reminder.sh's 20-minute idle kill skips it until the hold expires.
# Idle-kill only sees use by Claude calls or an open connection; a server handed to the user
# sits untouched until they get to it and was being killed first (2026-10-15).
# Usage: devserver-hold.sh <port> [hours, default 4]   |   devserver-hold.sh <port> --release
set -u
. "$HOME/.claude/hooks/lib-devserver-teardown.sh"
port="${1:?usage: devserver-hold.sh <port> [hours|--release]}"
case "$port" in *[!0-9]*) echo "port must be numeric" >&2; exit 2 ;; esac
f="$DEVSERVER_STATE/devserver-hold-$port"
if [ "${2:-}" = "--release" ]; then rm -f -- "$f"; echo "hold on $port released"; exit 0; fi
hours="${2:-4}"
case "$hours" in ''|*[!0-9]*) echo "hours must be a whole number" >&2; exit 2 ;; esac
mkdir -p "$DEVSERVER_STATE"
printf '%s\n' "$(( EPOCHSECONDS + hours * 3600 ))" > "$f"
echo "port $port held for the user's sign-off for ${hours}h (until $(date -d "@$(( EPOCHSECONDS + hours * 3600 ))" '+%H:%M'))"
