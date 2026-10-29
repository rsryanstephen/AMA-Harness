---
model: sonnet
name: harness-setup
description: Personalization of ~/.claude/harness-config.json for a new adopter of this harness (/harness-setup), or just the named blocks that install.ps1 added since setup (/harness-setup <block...>). User-invoked only — a setup action, not something to trigger mid-task.
disable-model-invocation: true
---

# Harness setup

Fills in `~/.claude/harness-config.json` for a new user/org. Full run = once per machine.

**Block mode — `/harness-setup <block> [<block>...]`:** safe on a personalized machine. `install.ps1` (Job 3) merges any block/key the example has and the live config lacks, as placeholders, then prints `/harness-setup <blocks>`. Block mode skips steps 1-2 and 5+, touches ONLY the named blocks: walk each one's step-3 entry, write answers, leave every other value alone. Unknown name → list the example's top-level keys. Placeholders left = that feature stays off/inert. Any later edit to org-shared values → step 2a push note applies; personal-only values never need pushing.

## Steps

1. Real config missing → copy `~/.claude/harness-config.example.json` to `~/.claude/harness-config.json` as the starting point (`install.ps1` normally seeds this already).
1a. **A seeded config carries schema placeholders inside arrays** — every array in the example holds one `"<one entry per line; this element only declares the type>"` element, because an empty array declares no element type and the example is the Octopus sync's schema (step 2b). **Empty those arrays in the LIVE config** as you fill each group: an unreplaced entry is a bogus recipient / sender / page title, not an inert empty list. Never "tidy" them out of the EXAMPLE — that breaks `push` (loudly: it names the array path, so the failure is self-correcting).
2. Real config already exists with non-placeholder values → stop, ask user before overwriting anything. Might already be personalized.
2a. **Octopus-first path.** Org keeps its harness config in a "Claude Harness" Octopus library variable set → skip the org questions entirely: needs `OCTOPUS_API_KEY` + VPN, run `bash scripts/octopus-config-sync.sh fetch --server <url> --space <Spaces-N>` (flags only needed while config is still placeholder). Fetch preserves the local `user` block — only step 3's `user` group remains to ask. No such variable set / no Octopus → manual Q&A below. After ANY later local config edit: `bash scripts/octopus-config-sync.sh push` so other machines pick it up, then `verify` (fetches to a temp file, diffs against local, changes nothing). Variables must stay non-Sensitive-typed — Sensitive is write-only via API, fetch would get a mask.
2b. **The set holds one variable per value** (`HarnessConfig:<colon-separated path>`, e.g. `HarnessConfig:atlassian:cloudId`), not one JSON blob. `harness-config.example.json` is the SCHEMA — it supplies every leaf's type, so **a `push` REFUSES a live key the example lacks** (a value under an unknown key could never be placed by a fetch; it would vanish silently on the next machine). Adding a config key = add it to the example too, with a placeholder. **An array in the example must carry one element even when empty in practice**, or its element type is unknowable; placeholder elements never reach a rebuilt config. Anything in the set not prefixed `HarnessConfig:` is left untouched (`AmaUiTestUserPassword` lives there). Logic: `scripts/harness-config-vars.py`, tested by `scripts/harness-config-vars-selftest.sh`.
3. Walk user through each group, one at a time, skip groups that don't apply (say which skills go unused as a result):
   - `user` — email, display name, Windows username, Jira accountId (opaque GUID, not the email — resolve once via `lookupJiraAccountId`, write the result into config; never re-looked-up after that), `secondaryEmail` (a second address the user also sends from, e.g. a client-tenant account — [[ama-standup-notes]] sweeps mail sent from it that cc's the primary; leave empty if there isn't one), `slackUserId` (their own `U…` id, used to find their sent Slack messages)
   - `atlassian` — Jira cloud id, project key, board id, Confluence space id/key/parent page id, harness epic key, security epic key (`securityEpicKey` -- every security finding's ticket is Epic-Linked to it, gate-enforced by `harness-ticket-gate.sh`), regressions ticket key, harness TEST FIXTURE ticket key (`harnessTestTicketKey` -- a parked Task used as the reusable Jira write target for harness smoke tests; create one and leave it Open), Epic Link custom field id (`epicLinkFieldId` — find via a ticket's `editmeta`/`createmeta` API response, varies per Jira instance), team-meeting-notes title-match words (`teamMeetingNotes.titleWords`, only if that skill applies)
   - `aws` — account number, region, CodeArtifact domain/repository (`codeArtifact.{domain,repository}`, only if using [[ama-cut-release-branch]]'s library-drift check)
   - `octopus` — server URL, space id, automation service-account email, project-name naming patterns (`projectNamePatterns`), environment ids per env (`environmentIds.{development,qa,staging,production}`)
   - `graylog` — host URL, support-alert stream id (`alertStreamId`, only if that alert exists in this org's Graylog)
   - `mongo` — SSH bastion user (`bastionUser`), per-env bastion host (`bastionHosts.{qa,staging,production}`), local tunnel port (`localPort`) — only if using [[ama-mongo-access]]. A stopped/restarted bastion EC2 instance gets a new public DNS name unless it's an Elastic IP, so re-confirm live rather than assuming it's stable across sessions
   - `bitbucket` — org, repo-slug prefix (`repoSlugPrefix`), default PR reviewers (`defaultPrReviewers`), ETL-fix reviewers (`etlFixReviewers`) — **currently silently skipped even though both already exist in the schema**, ask explicitly
   - `fleetOwners` — per fleet (`app`/`etl`, the `.harness-local.json` reposRoots `fleet` tags): owner `name` + `bitbucketUuid`. Non-self owner → their PR approval required (`fleet-owner-push-gate.sh`, `pr-merge-watch.sh`); user = `bitbucket.selfUuid`. Ask who owns each fleet
   - `backlogQaSweep` — QA person (`reporterName`/`reporterAccountId`) whose new Open tickets the biweekly `AMA-Harness-Backlog-QA-Sweep` adds to the backlog; `reportTarget` Slack id, `slackEveryRunUntil` date (DM every run until then, failures only after) — [[commit-ticket-jira]] `backlog-qa-sweep.sh`
   - `ama` — ETL assignee account id/name (`etlAssigneeAccountId`/`etlAssigneeName`) — **currently silently skipped**, ask explicitly; only applies if this org also has an AMA ETL fleet. Also `uiTesterName` — the person who tests Ready-to-Test tickets from the UI; decides whether a regression comment is posted at all ([[ama-hotfix]] Step 2a)
   - `slack` — support channel id/name (`amaSupportChannelId`/`amaSupportChannelName`), action-items canvas id (`actionItemsCanvasId`, blank = canvas mirror off) — **currently silently skipped**, ask explicitly
   - `standup` — which Slack conversation the unattended weekday standup-notes draft targets (`notifyMode`, one of the keys in `notifyTargets`/`notifyTargetNames`: a group DM, `#<amaSupportChannelName>`, or the user's own self-DM), plus `notifyGreetings` — the greeting line per target, since it names the actual people ("<team>"); empty string for a self-DM, where greeting yourself reads oddly. Plus `actionItems` — `sourceChannel` (Slack channel where the Zoom stand-up/team-meeting summary links get posted; Step 3b discovers doc ids there, never hardcodes one) and `ownerAliases` (names the user answers to in a summary's Action Items list, e.g. `["Your Name"]` — matches `Your Name` and `Your Name + Reviewer One`, skips other people's items). Only if using [[ama-standup-notes]]'s unattended companion
   - `releaseNotes` — recipient list, sign-off name, PDF-approver Slack user ids (`approverSlackUserIds`), PDF footer text (`pdfFooter`), and **`greetingNames`** (email → the name that person actually goes by). Ask for the greeting names explicitly: the release email opens with them, and a name inferred from an address gets it wrong — `<emailRecipients>` goes by **Seb**, and the 129.0.0 draft addressed him by his legal name because nothing had asked.
   - `audiences` — per-person communication depth: `defaultLevel`, then one `people` entry per regular correspondent (`name`, `emails`, `slackUserIds`, `level` = `business`|`<level>`, `avoid` = subject matter they can't use even at their level, `notes` in the user's own words). **Ask explicitly, person by person** — a level inferred from a job title is wrong the same way a greeting name inferred from an address was. `emails`/`slackUserIds` must be real addresses and real `U…` ids: the hooks match on those, so an entry keyed only on a first name matches nothing that arrives from Gmail or Slack. Empty `people` = both hooks inert. Drives [[audience-communication-levels]].
   - `packages` — internal NuGet library prefix (`libraryPrefix`, e.g. `YourCompany.Product.`) — only if this org publishes internal libraries checked by [[ama-cut-release-branch]]
   - `app` — per-environment domains (`domains.{prod,qa,staging,adminQa,dev}`) — only if using [[ama-ui-verify]]
   - `embs` — vendor publishing-calendar URL (`calendarUrl`), reminder calendar (`googleCalendarId`, `primary` unless a dedicated one), notice sender addresses (`noticeSenders`) + subject prefix (`noticeSubjectPrefix`) + any Gmail labels a filter files notices under (`noticeLabels`, display names, one search each), and the notice sweep windows (`noticeCheckDays`, `noticeLookbackDays`, `noticeOverlapDays`, `noticeSlackMinTier`, `noticeReportTarget`) — only if using [[ama-embs-reminders]]/[[ama-embs-notices]]. Shipped in the example config but **never asked for** until now, so an adopter got the placeholders and no prompt.
   - `feedbackNotices` — the client-feedback form's sender address(es) (`senders`) and subject prefix (`subjectPrefix`, the text before ` Ref:NNN`), the Jira epic every feedback ticket is linked to (`epicKey`), the Slack delivery target for the "ticket created" DM (`reportTarget`; a `U…` id DMs, a `C…` id posts to a channel, empty = tickets only) and the Gmail search window (`lookbackDays`, default 7 — the seen ledger, not the window, prevents duplicates) — only if using [[ama-feedback-notices]].
   - `awsNotices` — Slack delivery target for the AWS notice sweep (`reportTarget`; a `U…` id DMs, a `C…` id posts to a channel), the sweep windows (`checkDays`, `lookbackDays`, `overlapDays`, `slackMinTier`, `watchLeadDays`), the deadline-reminder horizon (`deadlineHorizonDays`, default 90 — a dated finding nudges weekly once its deadline is inside this many days, and stays silent before that), the new-usage-type cost floor (`newKeyFloorUsd`, USD — below it a brand-new billing line is traffic noise, not a finding), any addresses that forward AWS notices into this mailbox (`noticeForwarders`), and any Gmail labels a filter files AWS notices under (`noticeLabels`, display names — the mail leg searches each one) — only if using [[ama-aws-notices]]. Needs no AWS credentials of its own; it reuses the `aws` group's default-profile assumption.
   - `fleetHealth` — Slack delivery target for the nightly fleet-health sweep
     (`reportTarget`; a `U…` id DMs, a `C…` id posts to a channel) — only if using the
     fleet-health check registered by [[ama-library-version-sync]]. Empty = off switch,
     same convention as `embs.noticeReportTarget`.
   - `clientMail` — external domains treated as client mail for [[ama-standup-notes]]'s
     Step 3a and [[ama-team-meeting-notes]]'s equivalent (`domains`, e.g. `["<one entry per line; this element only declares the type>"]`)
     — mail to/from any address on these domains gets its own "Client mail" block. Empty
     array = that block never appears.
   - `supportNotices` — app-support mailbox monitor (`senders`, e.g. the app's own automated-failure address), the phase switch (`mode`: `construction` routes every outbound Slack — ack and ETL-owner ping alike — to `targets.construction`, `live` splits them to `targets.live`'s `ack`/`etlOwner`), the phase dials (`createTickets`/`autoFix`/`autoHotfix`, all bool, all `false` under construction), cadence (`timezone`, `dailyCheckHour`, `weekendMorningCheckHour`, `postProcessingDays`, `postProcessingEveryHours`, `lookbackHours`) — only if using [[<amaSupportChannelName>-notices]]. Day classification reads `.embs-reminders-synced`, so this needs [[ama-embs-reminders]] already running.
4. Write answers into `harness-config.json`, same schema as the example file. Leave any skipped group as placeholder.
5. **Repo locations (PROJ-15143) — separate file, not `harness-config.json`.**
   `harness-config.json` is org-shared (via the Octopus variable set, step 2a — untracked
   in git), but where repos are cloned is per-machine and belongs in neither store. Ask where AMA repos are cloned locally (one tree, or several —
   e.g. app repos and ETL repos split); write each as `{"path": "...", "fleet":
   "..."}` into `~/.claude/.harness-local.json`'s `reposRoots` array (`fleet` only
   needed if the user actually splits trees; omit/null otherwise — see
   `.harness-local.json.example` in this repo, or the live `.harness-local.json`, for
   the exact format). Gitignored, never committed. If skipped, `hr_roots` falls back
   to deriving a root from the harness's own clone location — works if repos are
   cloned alongside it, nothing else needed.
5a. **Sandbox trusted roots — same file, separate array, ask right after step 5.**
   `sandbox-allow.sh` auto-approves tool calls (no manual permission prompt) for
   anything under a trusted root. `~/.claude` and Claude Code's own scratchpad temp
   dir are always trusted, but nothing else is until this is set — write the SAME
   paths just given for `reposRoots` into `~/.claude/.harness-local.json`'s
   `sandboxTrustedRoots` array (plain path strings, `~` OK) as the default, then ask
   if the user wants to trust anything else (a separate scratch directory, etc.) or
   scope it narrower than the repo-discovery roots. This is genuinely separate from
   `reposRoots` — that one's about where the fleet's repos are found for skills like
   `ama-pr-review`; this one's about which directories bypass permission prompts.
   Skipped entirely → every tool call outside `~/.claude`/scratchpad prompts normally
   until this is configured (safe default, not broken — just not yet convenient).
5b. **Chrome-by-default opt-in — per-machine `~/.claude.json`, ask right after 5a.**
   Ask whether to opt in. Why: it's the only UI-verification path outside `admin`/
   `exporterplus` (`ama-ui-verify`'s Playwright script is those two repos only, and
   PROJ-15260 confirmed a headless MatDialog dead end even there). State
   prerequisites first — two fail silently, so lead with them:
   - **Direct Anthropic plan** (Pro/Max/Team/Enterprise) — not available via Bedrock,
     Vertex, or Microsoft Foundry at all.
   - **`/login` auth.** An API key or `claude setup-token` keeps Chrome off **even
     with `--chrome` passed** (2.1.216+; earlier versions 403 on every connect
     instead) — looks like the flag worked, doesn't.
   - Claude in Chrome extension v1.0.36+ (Chrome Web Store), Chrome or Edge (Brave/
     Arc/Vivaldi/Opera also detected), not supported in WSL.
   - Claude Code 2.1.211+ so startup doesn't hang with Chrome closed.
   - Cost: browser tools load every session, raising context even with no UI work.

   User opts in → they run `/chrome` → "Enabled by default" themselves (interactive,
   client-side, same as `/rename` — no tool/hook here can do it). Writes
   `claudeInChromeDefaultEnabled: true` at the top level of `~/.claude.json`.
   First-ever enable installs a native-messaging-host config that Chrome only reads
   at browser startup — extension "not detected" on the very first try → restart
   Chrome, then `/chrome` → "Reconnect extension". Not a failed install.
   Skipped → safe default, not broken: Playwright still covers `admin`/`exporterplus`,
   and per-session `claude --chrome` still works.
5c. **`ama-ui-verify` shared password — one-time env var, ask right after 5b, only if the `app` group applies.** Source of truth is a non-sensitive Octopus library variable (`Claude Harness` set, `AmaUiTestUserPassword` variable — this adopter's id: `LibraryVariableSets-261`; a different org creates its own). Fetch once, export forever, so Claude never re-fetches it mid-session:
   ```bash
   PW="$(curl -sS -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" \
         "https://yourorg.octopus.app/api/Spaces-1/variables/variableset-LibraryVariableSets-261" \
         | jq -r '.Variables[] | select(.Name=="AmaUiTestUserPassword") | .Value')"
   case "$PW" in ''|null) echo "fetch failed -- check OCTOPUS_API_KEY, variable name" >&2;; *)
     sed -i '/^export claude_ama_pw=/d' ~/.secrets 2>/dev/null
     printf 'export claude_ama_pw=%q\n' "$PW" >> ~/.secrets && source ~/.secrets ;;
   esac; unset PW
   ```
   See [[ama-ui-verify]]'s "Dedicated test users" section for why the variable stays
   non-sensitive (Octopus won't return a value for a sensitive one) and why
   `~/.claude/.ama-ui-credentials.json` never holds the password itself.
6. **Physical layout — handled already, run BEFORE this skill:** `scripts/install.ps1` (see README) links `skills/`/`hooks/`/`CLAUDE.md`/`harness-config.json` into `~/.claude` and merges `settings.template.json` into the adopter's real `settings.json`. This skill only fills in `harness-config.json`'s values — if links aren't set up yet, point the user at the README's install section first.
7. Tell user: AMA_APP-specific skills assume a fleet shaped like this org's (ECS-deployed .NET services, Octopus, Bitbucket, Jira/Confluence via direct REST with `ATLASSIAN_API_TOKEN` — no Atlassian MCP, retired 2026-08-31) — different shape, skip that content. Only the general-purpose skills apply regardless of org: `commit-ticket` (+ `commit-ticket-jira`), `resource-efficiency`, `chat-log-reads`, `caveman`, `karpathy-guidelines`, `rename-topic`, `relocate-session`, `process-prompt-queue`, `write-a-skill`.

## Verifying it took

Scripts/hooks read config with a graceful fallback (`jq -r '.path // "<default>"'`) — a missing or malformed field silently falls back to the original hardcoded default, no error. Spot-check with:

```bash
jq '.' "$HOME/.claude/harness-config.json"
jq '.reposRoots, .sandboxTrustedRoots' "$HOME/.claude/.harness-local.json"
jq '.claudeInChromeDefaultEnabled, .cachedChromeExtensionInstalled, .hasCompletedClaudeInChromeOnboarding' "$HOME/.claude.json"
```

Confirm no `example.com` / `yourorg` / `000000000000` placeholders remain in groups the user said apply to them, and that `sandboxTrustedRoots` isn't empty/missing if the user wants routine work in their own repos to skip permission prompts. For step 5b: `claudeInChromeDefaultEnabled` is the opt-in itself; the other two keys are only **cached** history (extension seen once, ever) — not proof it's installed and connected right now. The real check is `/chrome`'s own status panel showing "Status: Enabled" and "Extension: Installed".
