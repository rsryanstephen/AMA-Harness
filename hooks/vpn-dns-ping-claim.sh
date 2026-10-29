#!/usr/bin/env bash
# Atomic cross-session claim: "am I the session that pings the user for THIS outage?"
# Multiple concurrent sessions can hit the VPN DNS fault at the same moment (each running
# its own PostToolUse hook or probe tick) -- without this, every one of them would DM the
# user separately for the same outage. User instruction 2026-09-01.
#
# Exit 0 = claimed, this session acts. Exit 1 = already claimed, skip that action.
#
# Takes an optional claim name (default `.vpn-dns-user-pinged`, the Step 1 <name> DM). The
# skill also claims `.vpn-dns-reported` around Step 3's OUTWARD-FACING WRITES -- the IT-7829
# public comment and the IT-TICKET-VPN-DNS-bitbucket.md append -- so concurrent sessions
# don't double-post to a ticket whose owner complained about verbosity, or race each other
# appending to the same file. `.vpn-dns-cli-surfaced` (Step 0) covers the third audience,
# the USER: every live session gets the same nudge, so without it each narrates one outage
# into its own reply. The LOCAL, READ-ONLY parts (Step 2 capture, Step 4 GP-log look) stay
# un-deduped on purpose: every session's own capture is extra evidence.
#
# Rule of thumb for any future claim: dedupe by AUDIENCE, not by step. One human (<name>,
# the ticket, the user) should hear about one outage once, however many sessions saw it.
#
# Mechanism: bash noclobber (`set -C`) makes `>` fail if the target already exists --
# atomic at the OS level, no separate lock file needed, no TOCTOU window between a `[ -f ]`
# check and a later write (same class of bug a lock would exist to prevent).
#
# Same-outage boundary: a marker older than 6h is treated as a DIFFERENT outage (this
# fault's own history shows episodes of minutes to ~6.5h -- Example 2 -- so 6h separates
# "still the same outage" from "it's back again, tell the user again" without needing the
# probe to be running to know the difference). vpn-dns-probe.ps1's recovery branch also
# deletes this marker directly when it sees the resolver heal -- that is the precise
# signal an outage ended, so a fault after a real recovery re-pings regardless of age.
set -u
. "${BASH_SOURCE[0]%/*}/lib-claude-paths.sh"
MARKER="$(hstate notices "${1:-.vpn-dns-user-pinged}")"

if [ -f "$MARKER" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$MARKER" 2>/dev/null || echo 0) ))
  if [ "$age" -lt 21600 ]; then
    exit 1
  fi
  rm -f "$MARKER"
fi

sid="${CLAUDE_SESSION_ID:-unknown}"
if ( set -C; printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${sid%%-*}" > "$MARKER" ) 2>/dev/null; then
  exit 0
fi
# Lost the race to another concurrent session between the stale check and the write.
exit 1
