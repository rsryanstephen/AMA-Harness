# git push/fetch/clone failing on bitbucket.org

Reference for [[commit-ticket]] -- loaded on demand, not at task start.

## `git push`/fetch/clone failing on a bitbucket.org remote — check these first

- `ssh: connect to host bitbucket.org port 22: Network is unreachable` (hangs, not an
  error) → this network blocks outbound port 22. Already fixed in `~/.ssh/config`
  (routes over `altssh.bitbucket.org:443`) — if it recurs (new machine, config reset),
  reapply the same fix, don't re-diagnose as auth.
- DNS resolution failing (any host, not just bitbucket.org) → transient VPN-DNS blip:
  keep polling until it clears, backing off the interval as it drags on (10s → 30s →
  1m → 5m → 15m). Don't stop and hand back to the user. If it drags on badly, append
  the evidence (timestamps, resolver, hostnames) to the not-yet-sent draft IT ticket at
  `~/.claude/IT-Ticket-VPN-DNS/IT-TICKET-VPN-DNS-bitbucket.md`.
  **Every occurrence gets logged there, always** — new dated `### Example`, incl.
  where user physically was. Not only when it drags on. `vpn-dns-outage-logger.sh`
  fires the reminder; one entry per day, self-clearing.
- `! [remote rejected] <branch> (pre-receive hook declined)` = Bitbucket's SERVER refused the
  push -- it arrived, so this is never your network. NO `remote:` reason lines -> transient
  server-side: retry once (idempotent). WITH `remote:` lines (branch permission, file size,
  ticket check) -> real refusal, read them, don't retry blind. The PostToolUse push nudges fire
  on a rejected push too: trust the `old..new` ref line, not the nudge.
- Push landed but Bitbucket never started its pipeline (also server-side): `pipeline-status.sh
  <repo> <branch> --sha <sha>` -> `NO PIPELINE` with the API answering = event lost ->
  [[ama-bitbucket-api]]'s `trigger-branch-pipeline.sh <repo> <branch>`. Check this after any
  push made while Bitbucket was misbehaving.
- `api.bitbucket.org` timing out (curl `000` after 20s) or slow 503s while `nslookup` resolves
  it and `bitbucket.status.atlassian.com` says operational -> the NETWORK path, on this host the
  full-tunnel VPN (2026-10-15: GlobalProtect Connected throughout; cleared on disconnect, and
  a disconnect+reconnect fixed it with full tunnel still on). Ask the user to disconnect and
  reconnect GlobalProtect, re-check, don't loop. Evidence goes to
  draft `IT Tickets/IT-Ticket-VPN-full-tunnel-bitbucket.md`.
- This is git-over-SSH transport only — a different layer from Bitbucket's REST API
  (Pipelines status, triggering a run), see [[ama-bitbucket-api]] for that.

