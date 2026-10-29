---
name: ama-vpn-dns-outage
model: sonnet
description: Live-capture runbook for the recurring VPN DNS failure (resolver 10.1.0.4 NXDOMAINs public names, IT ticket IT-7829) -- Slack-ping BARRY FIRST (deduped across sessions), then run the fixed capture battery, then comment on the ticket. Use the moment a DNS resolution failure hits (hooks/vpn-dns-outage-logger.sh's nudge fires, "Could not resolve hostname", NXDOMAIN, or the user says the VPN DNS thing is happening again). Time-critical -- capture first; episodes have run minutes to ~25h, so never assume it self-heals. Full tunnel is live on this host since 2026-09-04.
---

# VPN DNS outage -- live capture runbook

## Step -1 -- TWO faults now. Classify before doing ANY of this.

`nslookup <the host that failed> 10.1.0.4`

- **Resolves** -> resolver SLOW, not broken. NOT IT-7829. **Stop here**: no <name> ping, no
  capture battery, no claims. Append an occurrence to
  `IT Tickets/IT-Ticket-VPN-DNS-resolver-latency.md` (DRAFT -- never send), then carry on.
  `vpn-dns-probe.ps1` writes the same shape automatically; match it.
- **Fails / NXDOMAIN while a public resolver answers** -> IT-7829. Rest of this file applies.

Why: full tunnel (2026-09-04) fixed IT-7829 -- zero probe faults in the 22 days after. What
remains is ~350-400ms to 10.1.0.4, sole resolver on the PANGP adapter, occasional multi-second
retry -> client timeout -> same "Could not resolve host" text, different cause. Pinging <name>
for that is a false alarm on a ticket he asked us to keep quiet.

Standing IT ticket: **IT-7829** (filed 2026-08-28). Full history:
`~/.claude/IT-Ticket-VPN-DNS/IT-TICKET-VPN-DNS-bitbucket.md`.

Still capture FIRST -- but "self-heals in minutes" is NOT reliable. Measured window
2026-09-03 10:00 -> 2026-09-04 10:50 = **~24h50m**, and it did not self-heal: <name> ended
it by switching this host split-tunnel -> full-tunnel. Episodes have run minutes to ~25h.
Treat capture as now-or-never anyway (it CAN clear in minutes), never assume a long one
will clear on its own, and never tell <name> it self-heals.

**FULL TUNNEL IS LIVE on this host** (<name>, 2026-09-04 10:44) -- his split-tunnel/Windows
-update theory, `AFRICA-VPN`, test config for this user only. Consequences that change what
you measure: `10.1.0.4` is now the DEFAULT resolver (PANGP ifMetric 1 vs Wi-Fi 35), and
**the LAN is unreachable while the VPN is up** -- so a `192.168.50.x` timeout is expected,
not a finding. Full tunnel may be reverted; re-check which mode is live before diagnosing.

## Step 0 -- telling the USER about it in the CLI is ALSO deduped

Every live session gets the same probe nudge. Without a claim each one narrates the same
outage into its own reply, so the user hears about one fault N times. User instruction
2026-09-04: no session talks to the user about a VPN outage another session is handling.

```bash
bash "$HOME/.claude/hooks/vpn-dns-ping-claim.sh" .vpn-dns-cli-surfaced
```
Exit 0 -- you own the CLI mention. Surface it once, one line.
Exit 1 -- another session already told the user. **Say NOTHING about the outage** -- no
"the VPN thing is happening again", no aside, no closing note. Do Steps 1-4 per their own
claims and stay silent about it in the reply.

Applies to the DM/ticket steps too: a skipped claim means skipped SILENTLY. Never
substitute "another session already pinged <name>" as CLI chatter -- that is the same
duplicate noise wearing a different hat.

Exception: the user ASKS about the VPN/DNS. Answer them -- a direct question is not
unsolicited narration, no claim needed.

## Step 1 -- ping BARRY immediately, deduped across sessions

User standing instruction 2026-09-04 (reverts the 2026-09-01 "ping the user" version,
which itself replaced the 2026-08-31 "ping <name>" one): first alert on fresh outage goes
to **<name>**, `<slackUserIds>`. Not the user. Send, don't draft, don't ask.

Multiple sessions can hit this fault at the same moment (the background probe ticks
every 10 min, any live session's own tool calls can also trip it) -- without a claim,
every one of them would DM <name> separately for the one outage. Gate on the claim
helper FIRST:

```bash
bash "$HOME/.claude/hooks/vpn-dns-ping-claim.sh"
```
Exit 0 -- you won the claim, send the DM now:
> VPN DNS outage live now (IT-7829)
(<name> = `<slackUserIds>`, `harness-config.json` `.audiences`. Terse per
[[slack-messages-terse]]; he complained about verbosity on IT-7829.)
Exit 1 -- another session already pinged for this outage. Skip the DM, continue
straight to Step 2. Step 2's capture and Step 4's GP-log look are per-session and NOT
deduped on purpose -- read-only, local, more data points help. Step 3's two WRITES take
their own claim; see there.

## Step 2 -- capture battery (one PowerShell call, while it is still failing)

Fixed sequence (user instruction 2026-09-01). Run together, keep raw output:

```powershell
ping -n 3 10.1.0.4
nslookup google.com 10.1.0.4
nslookup google.com 8.8.8.8
nslookup altssh.bitbucket.org 10.1.0.4
Test-NetConnection bitbucket.org -Port 22
Get-Process PanGPA,PanGPS -ErrorAction SilentlyContinue | Select Name,Id,StartTime
Get-NetAdapter | Where-Object InterfaceDescription -match 'PANGP' | Select Name,Status,InterfaceDescription
Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object ServerAddresses
Get-DnsClientNrptPolicy -Effective | Select Namespace,NameServers
```

Ping comes first deliberately -- prove network connectivity BEFORE testing DNS. The two
`nslookup` calls are side by side on purpose: `10.1.0.4` vs `8.8.8.8` for the same name
is the comparison that shows a VPN-resolver-only failure. Trap (confirmed): Windows
`nslookup` exits 0 on NXDOMAIN -- judge by output text, never exit code.

NRPT line added 2026-09-01 (user instruction). It is the discriminator for the held-back
hypothesis below. <name>'s account = GP forwards only two internal zones to `10.1.0.4`; done
the Windows way that IS an NRPT table. Measured DISCONNECTED, NRPT is EMPTY (`-Effective`
and `Get-DnsClientNrptRule` both) -- inconclusive, tunnel was down. Read it LIVE:
- NRPT has rules, public names NOT in them, yet `10.1.0.4` answered anyway -> the GP client
  intercepted off-policy and synthesized the NXDOMAIN. Client is the fault.
- NRPT still empty and `10.1.0.4` is just the adapter's DNS server at a lower metric (35
  Wi-Fi vs the PANGP adapter's) -> Windows asked it correctly, server answered NXDOMAIN.
  Server/config is the fault.
Facts only on the ticket -- the inference stays out of <name>'s comment (see Step 3).

## Step 3 -- record + report

All correspondence with <name> -- ticket comments, mail -- brief and to the point,
minimum verbiage (he complained about verbosity on this ticket; he also has an
`.audiences` entry in `harness-config.json`). <name> also gets Step 1's ping, so the
comment is the DETAIL, not the alert -- don't restate the ping.

Both writes below go OUTWARD (a ticket <name> reads, a file another session may be
appending to at the same moment), so claim them first -- same helper, second claim name:

```bash
bash "$HOME/.claude/hooks/vpn-dns-ping-claim.sh" .vpn-dns-reported
```
Exit 1 -- another session already reported this outage. **Skip both writes**, say so in
the reply, and go to Step 4. Do not post "an extra data point" comment; <name> complained
about verbosity on this ticket and duplicate comments are exactly that. Exit 0 -- you own
the reporting for this outage, do both:

- Append the occurrence to `~/.claude/IT-Ticket-VPN-DNS/IT-TICKET-VPN-DNS-bitbucket.md` (the
  vpn-dns-outage-logger.sh nudge describes the entry shape; that obligation stands).
- Post the capture output as a public comment on IT-7829 -- authorized, standing
  instruction. Facts and raw output only, no theorizing (see above). JSM customer API, Basic auth `you@example.com:$ATLASSIAN_API_TOKEN`:
  `POST https://yourorg.atlassian.net/rest/servicedeskapi/request/IT-7829/comment`
  body `{"body": "<text>", "public": true}` (write body via a payload file, same rule as
  [[ama-jira-api]]). Read replies: GET same URL.

## Step 4 -- GP-log look; the full-tunnel switch is ALREADY DONE

Full tunnel was the prepared escalation and <name> applied it 2026-09-04 10:44. Do NOT
prepare or propose it again. If a fault recurs **on full tunnel**, that is new information
and the single most useful thing to tell him -- it kills the split-tunnel theory.
- GP client logs for the live look: `%LOCALAPPDATA%\Palo Alto Networks\GlobalProtect\PanGPA.log`
  (user agent) and `C:\Program Files\Palo Alto Networks\GlobalProtect\PanGPS.log`
  (service, may need elevation). Tail both around the failure window NOW, while the
  window is still fresh, and keep the excerpt ready to hand over -- don't wait to be asked.

## Context that frames what the capture means

- Split-DNS is BY DESIGN (<name>, IT-7829): the GP client intercepts DNS on the laptop,
  forwards only the two internal zones to 10.1.0.4, rest to Google/Cloudflare. So an
  authoritative NXDOMAIN "from 10.1.0.4" is plausibly synthesized by the GP client
  interceptor -- the client, not the server, is the live suspect (PanGPS crashed
  unexpectedly 2026-08-28 00:07, System event 7031). This hypothesis is NOT shared with
  <name> -- and Step 1 pings him again since 2026-09-04, so keep it out of that DM too
  (one line, no theory) -- user held the hypothesis back
  2026-08-31 (info overload; unsent write-up:
  `~/.claude/IT-TICKET-VPN-DNS-bitbucket/reply-draft-IT-7829.md`). It steers YOUR
  diagnosis (check GP client processes/logs first) -- never volunteer it on the ticket.
- Outbound port 22 is NOT blocked (<name>) -- the altssh.bitbucket.org workaround's
  premise was wrong; the Test-NetConnection in Step 2 is the standing recheck.
- Meanwhile keep working per the logger nudge: poll with backoff, don't hand the
  session back over a DNS blip.
