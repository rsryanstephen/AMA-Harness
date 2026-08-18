#!/usr/bin/env bash
# Thin wrapper. All the actual rendering logic (bold-field cascade, context-size
# column, hide filter, etc -- see session-ctx-sizes.pl's own header) lives in
# session-ctx-sizes.pl now, as a single perl process. Used to be a bash loop here that
# forked ~8-10 subprocesses PER ROW -- measured 43s over a real 65-row sessions.txt,
# which blew past every automatic caller's hook timeout (on-stop.sh's Stop: 10s,
# on-session-end.sh's SessionEnd: 5s) and left sessions.md stuck stale, sometimes for
# tens of seconds, sometimes indefinitely. One perl process doing the same work: ~1s.
#
# perl absence -> no render attempt at all, sessions.md just stays at its last good
# state -- same as any other silent-exit path in the .pl. No bash fallback: perl is
# already a hard dependency of this path (it always computed the context-size column).
#
# Kept as the stable entry point so none of this script's 5 callers (on-prompt.sh,
# on-stop.sh, on-session-end.sh, rename-topic.sh, relocate-session.sh) need to change.
command -v perl >/dev/null 2>&1 || exit 0
exec perl "$(dirname "${BASH_SOURCE[0]}")/session-ctx-sizes.pl"
