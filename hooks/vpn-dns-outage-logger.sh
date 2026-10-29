#!/usr/bin/env bash
# PostToolUse hook (Bash/PowerShell). Fires when a NETWORK command fails with a DNS
# resolution error, and reminds Claude to append another occurrence to the standing draft
# IT ticket at ~/.claude/IT-Ticket-VPN-DNS/IT-TICKET-VPN-DNS-bitbucket.md.
#
# Why this exists. The corporate VPN's resolver (10.1.0.4) intermittently returns NXDOMAIN
# for every external domain. The draft ticket is only persuasive because it carries a dated
# log of separate occurrences -- one report reads as a fluke, five with dates, durations,
# resolvers and locations reads as a pattern IT can act on. Per explicit user instruction
# 2026-08-20: every time this happens, log another example, automatically.
#
# Per CLAUDE.md's "Mechanical Triggers Over Self-Recognition" rule this is a hook, not a
# paragraph in a skill. Self-recognition is especially unreliable here: a DNS outage is
# maximally distracting -- the session is mid-task, something just broke, and the natural
# reaction is to retry or work around it, not to stop and write documentation.
#
# Deliberately a reminder (decision:block -> Claude sees it), never a gate: the failing
# command already failed, there is nothing left to prevent.
#
# Self-clearing, no state file: the only dedupe is "does the ticket already have an entry
# dated today". So it keeps reminding until the obligation is actually met, and it goes
# quiet by itself the moment it is -- nothing to reset, nothing that can get stuck.
#
# Fails open on anything it cannot resolve.
set -u

# Overridable so check-gates can exercise the dedupe without touching the real ticket --
# and it MUST be overridable: the live ticket already has an entry dated today the moment
# this works at all, which would silently make every suite case "pass".
# The ticket lives in a subfolder, NOT flat under ~/.claude (PROJ-15342 clutter rule
# moved it 2026-08-28; this default lagged behind pointing at the old flat path, which no
# longer exists -- so the dedupe below matched nothing and the append instruction named a
# file that would be created fresh, orphaned from the real evidence log).
TICKET="${VPN_DNS_TICKET_FILE:-$HOME/.claude/IT-Ticket-VPN-DNS/IT-TICKET-VPN-DNS-bitbucket.md}"

# Second ticket, added 2026-09-26. Since full tunnel closed IT-7829, the same symptom
# ("Could not resolve host") is usually a SLOW resolver rather than a broken one, and that is
# a separate fault with a separate draft ticket. The reason text below makes the caller
# classify before acting -- pinging <name> for the latency fault would be a false alarm on a
# ticket he has already asked us to keep quiet. Lives in the harness repo, reached through
# the ~/.claude/hooks junction's real parent, never a relative '..' through it.
LATENCY_TICKET="${VPN_DNS_LATENCY_TICKET_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/IT Tickets/IT-Ticket-VPN-DNS-resolver-latency.md}"

IFS= read -r -d '' payload || true

# Cheap raw-payload pre-filter before any jq fork (precedent: aggregation-secret-gate.sh).
# BOTH families of wording, deliberately: the Unix one git/ssh/curl emit, AND the Windows
# one. This hook is wired to `Bash|PowerShell`, so PowerShell wording is not optional --
# and it was missing, which is exactly how this hook stayed silent through a confirmed live
# outage (2026-09-01). `Resolve-DnsName` says "DNS name does not exist"; .NET, and so
# `dotnet` and most Windows-native tooling, says "No such host is known". Neither matched
# any of the five original Unix signatures, so the hook exited HERE and never reached the
# network-command test below. Adding a signature is safe because the predicate is two-sided
# -- see the network-command grep further down, which is what stops a `cat` of a file
# containing this text from firing.
case "$payload" in
  *"resolve host"*|*"Non-existent domain"*|*"name resolution"*|*"No address associated"*|*"Name or service not known"*) ;;
  *"DNS name does not exist"*|*"No such host is known"*) ;;
  *) exit 0 ;;
esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
[ -n "$command" ] || exit 0
# Wired under BOTH PostToolUse and PostToolUseFailure (2026-10-05). PostToolUse does not fire
# on a non-zero exit, so a FAILING curl/git -- the normal shape of a resolver outage -- was
# only ever seen when the exit was masked by a pipe. The failure event carries the text in
# `.error` (the raw-payload needle above covers both) but takes a different output shape.
event="$(printf '%s' "$payload" | jq -r '.hook_event_name // empty')"

# FALSE-POSITIVE GUARD, and the one that actually bites: merely READING or WRITING the
# ticket, this hook, or the gate-test suite puts every one of those signature strings into
# the payload. Without this, documenting the outage would itself trigger a reminder to
# document the outage. Checked before the network-command test because it is the cheaper
# and the more certain of the two.
# Both casings: the file is IT-TICKET-VPN-DNS-bitbucket.md but its parent directory is
# mixed-case IT-Ticket-VPN-DNS -- a command naming only the directory matches only the
# second pattern.
case "$command" in
  *IT-TICKET-VPN-DNS*|*IT-Ticket-VPN-DNS*|*vpn-dns-outage-logger*|*harness-gaps*) exit 0 ;;
esac

# Two-sided predicate: the DNS wording must come from a command that actually uses the
# network. Text alone is not enough -- `cat` of any log, transcript or chat file will
# contain it once an outage has been written up anywhere.
#
# PowerShell cmdlets are listed alongside the Unix binaries for the same reason the Windows
# wording is matched above (this hook's matcher is `Bash|PowerShell`). Resolve-DnsName and
# Test-NetConnection are not hypothetical: they are two of the commands ama-vpn-dns-outage's
# own capture battery runs, so an outage response would otherwise fail this test.
#
# The separator class carries `(){}` beyond the shell operators because a PowerShell command
# is routinely wrapped -- `try { Resolve-DnsName ... }` / `if (...) { ... }`. grep -E anchors
# `^` per line, so a cmdlet sharing its line with `try {` matches no other alternative here.
# That was the real command's shape during the 2026-09-01 miss. Inside a bracket expression
# these are literal; no escaping needed.
printf '%s' "$command" \
  | grep -qE '(^|[;&|(){}]|&&)[[:space:]]*(git|curl|wget|ssh|scp|aws|nslookup|dig|host|npm|npx|dotnet|docker|ping|gh|az|Resolve-DnsName|Test-NetConnection|Invoke-WebRequest|Invoke-RestMethod)\b' \
  || exit 0

# Dedupe: one entry per calendar day. An outage produces many failing commands; the ticket
# wants one dated occurrence, not twenty.
# Not the fault (2026-09-08, two false positives in one task): a lookup aimed at an EXPLICIT
# server (`nslookup name 1.1.1.1`, `dig @8.8.8.8`) is a deliberate probe, and if a control
# name still resolves through the default resolver the VPN resolver is not NXDOMAINing public
# names (under full tunnel it IS the default resolver, so the control covers both modes).
# VPN_DNS_CONTROL_RESOLVES=0|1 is the suite's seam; unset = ask nslookup, fail open on no tool.
printf '%s' "$command" | grep -qE 'nslookup[^;|&]*[[:space:]][0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|dig[^;|&]*[[:space:]]@[0-9a-zA-Z]' && exit 0
control_resolves() {
  case "${VPN_DNS_CONTROL_RESOLVES:-}" in 1) return 0 ;; 0) return 1 ;; esac
  command -v nslookup >/dev/null 2>&1 || return 1
  timeout 6 nslookup google.com 2>/dev/null | grep -q '^Name:'
}
control_resolves && exit 0

today="$(date '+%Y-%m-%d')"
if [ -f "$TICKET" ] && grep -q "^### Example .*${today}" "$TICKET" 2>/dev/null; then
  exit 0
fi

out="$(jq -cn --arg t "$TICKET" --arg d "$today" --arg lt "$LATENCY_TICKET" '{
  decision: "block",
  reason: ("A network command just failed with a DNS resolution error. There are now TWO different faults behind that symptom, and they go to DIFFERENT tickets. CLASSIFY FIRST -- one command:\n\n  nslookup <the host that failed> 10.1.0.4\n\n  - It RESOLVES (the failure does not reproduce) -> the resolver is SLOW, not broken. This is the post-full-tunnel latency fault, not IT-7829. Do NOT ping <name> and do NOT run the capture battery. Append an occurrence to:\n  " + $lt + "\n    following the shape of the entries already there (the harness probe writes the same shape automatically). That ticket is a DRAFT being held until there are several occurrences -- never send it. Then carry on, per the backoff note below. Background: the resolver answers correctly at ~350-400ms with occasional multi-second retries, and a client with a shorter timeout reports exactly this error.\n  - It does NOT resolve, or returns NXDOMAIN while google.com resolves elsewhere -> that IS IT-7829, and everything below applies.\n\nIT-7829 has not recurred since the full-tunnel switch on 2026-09-04, so the first branch is the likelier one -- but check, do not assume either way.\n\nFOR IT-7829 ONLY: invoke Skill(ama-vpn-dns-outage) and follow it NOW -- it Slack-pings BARRY immediately, deduped across concurrent sessions via vpn-dns-ping-claim.sh (user standing instruction 2026-09-04, reverts the 2026-09-01 ping-the-user version), then runs the fixed capture battery. Capture is now-or-never, but do NOT assume it self-heals: episodes have run minutes to ~25h, and the 2026-09-03/04 one was ended by <name> switching this host to FULL TUNNEL, not by healing (full tunnel is live as of 2026-09-04 10:44).\n\nTHEN, per explicit user instruction (2026-08-20), every occurrence also gets logged, automatically, without being asked: append a new \"### Example N\" section to:\n  " + $t + "\n\nMatch the existing entries'"'"' shape and record, at minimum:\n  - Date " + $d + " and the time the failure started (SAST).\n  - WHERE the user physically was -- office vs home vs elsewhere. Ask the user if you do not already know. This matters more than it looks: without it the obvious first theory is \"only happens off the corporate network\", and the 2026-08-20 entry is the one that rules that out, because it happened in the YourCompany JHB office.\n  - The resolver address, from `nslookup <host>` output (has been 10.1.0.4; Example 2 recovered onto a different resolver, so it is not a constant).\n  - SCOPE: test a non-vendor domain too (`nslookup google.com`). Bitbucket-only vs everything-fails distinguishes a forwarding gap from a total connectivity loss, and that distinction is the ticket'"'"'s main diagnostic content.\n  - What it blocked, and the duration once known. Do not wait for resolution before writing the entry -- log the start now and update it later (Example 3 set that precedent).\n\nTHEN CARRY ON. Poll with backoff (10s -> 30s -> 1m -> 5m -> 15m) and keep doing whatever work is not blocked; do not hand the session back to the user over a DNS blip -- see commit-ticket'"'"'s bitbucket-remote section.\n\nTwo traps already confirmed the hard way:\n  - Windows `nslookup` exits 0 even on NXDOMAIN, so `if nslookup host >/dev/null` reports success while the resolver is still failing. Probe with `git ls-remote` instead, or grep the output for a real answer line.\n  - `cmd | sed` takes sed'"'"'s exit status, not the command'"'"'s. A push that Bitbucket rejected will look like it succeeded. Capture status before piping.\n\nThis reminder fires once per day and stops as soon as the ticket has an entry dated " + $d + ".")
}')"
if [ "$event" = "PostToolUseFailure" ]; then
  # Same text, the failure event's shape (docker-wedge-reminder.sh precedent): `decision:block`
  # is not read on this event.
  printf '%s' "$out" | jq -c '{hookSpecificOutput: {hookEventName: "PostToolUseFailure", additionalContext: .reason}}'
else
  printf '%s\n' "$out"
fi
