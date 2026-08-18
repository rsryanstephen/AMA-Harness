---
name: harness-setup
description: One-time personalization of ~/.claude/harness-config.json for a new adopter of this harness. User-invoked only (/harness-setup) — a one-shot setup action, not something to trigger mid-task.
disable-model-invocation: true
---

# Harness setup

One-time. Fills in `~/.claude/harness-config.json` for a new user/org. Not for repeat runs on an already-personalized machine.

## Steps

1. Real config missing → copy `~/.claude/harness-config.example.json` to `~/.claude/harness-config.json` as the starting point (`install.ps1` normally seeds this already).
2. Real config already exists with non-placeholder values → stop, ask user before overwriting anything. Might already be personalized.
2a. **Octopus-first path.** Org keeps its harness config in a "Claude Harness" Octopus library variable set → skip the org questions entirely: needs `OCTOPUS_API_KEY` + VPN, run `bash scripts/octopus-config-sync.sh fetch --server <url> --space <Spaces-N>` (flags only needed while config is still placeholder). Fetch preserves the local `user` block — only step 3's `user` group remains to ask. No such variable set / no Octopus → manual Q&A below. After ANY later local config edit: `bash scripts/octopus-config-sync.sh push` so other machines pick it up (variable must stay non-Sensitive-typed — Sensitive is write-only via API, fetch would get a mask).
3. Walk user through each group, one at a time, skip groups that don't apply (say which skills go unused as a result):
   - `user` — email, display name, Windows username, Jira accountId (opaque GUID, not the email — resolve once via `lookupJiraAccountId`, write the result into config; never re-looked-up after that)
   - `atlassian` — Jira cloud id, project key, board id, Confluence space id/key/parent page id, harness epic key, Epic Link custom field id (`epicLinkFieldId` — find via a ticket's `editmeta`/`createmeta` API response, varies per Jira instance), team-meeting-notes title-match words (`teamMeetingNotes.titleWords`, only if that skill applies)
   - `aws` — account number, region, CodeArtifact domain/repository (`codeArtifact.{domain,repository}`, only if using [[ama-cut-release-branch]]'s library-drift check)
   - `octopus` — server URL, space id, automation service-account email, project-name naming patterns (`projectNamePatterns`), environment ids per env (`environmentIds.{development,qa,staging,production}`)
   - `graylog` — host URL, support-alert stream id (`alertStreamId`, only if that alert exists in this org's Graylog)
   - `mongo` — SSH bastion user (`bastionUser`), per-env bastion host (`bastionHosts.{qa,staging,production}`), local tunnel port (`localPort`) — only if using [[ama-mongo-access]]. A stopped/restarted bastion EC2 instance gets a new public DNS name unless it's an Elastic IP, so re-confirm live rather than assuming it's stable across sessions
   - `bitbucket` — org, repo-slug prefix (`repoSlugPrefix`), default PR reviewers (`defaultPrReviewers`), ETL-fix reviewers (`etlFixReviewers`) — **currently silently skipped even though both already exist in the schema**, ask explicitly
   - `ama` — ETL assignee account id/name (`etlAssigneeAccountId`/`etlAssigneeName`) — **currently silently skipped**, ask explicitly; only applies if this org also has an AMA ETL fleet
   - `slack` — support channel id/name (`amaSupportChannelId`/`amaSupportChannelName`) — **currently silently skipped**, ask explicitly
   - `releaseNotes` — recipient list, sign-off name, PDF-approver Slack user ids (`approverSlackUserIds`), PDF footer text (`pdfFooter`)
   - `packages` — internal NuGet library prefix (`libraryPrefix`, e.g. `YourCompany.Product.`) — only if this org publishes internal libraries checked by [[ama-cut-release-branch]]
   - `app` — per-environment domains (`domains.{prod,qa,staging,adminQa,dev}`) — only if using [[ama-ui-verify]]
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
     printf 'export claude_ama_pw=%q\n' "$PW" >> ~/.bashrc && source ~/.bashrc ;;
   esac; unset PW
   ```
   See [[ama-ui-verify]]'s "Dedicated test users" section for why the variable stays
   non-sensitive (Octopus won't return a value for a sensitive one) and why
   `~/.claude/.ama-ui-credentials.json` never holds the password itself.
6. **Physical layout — handled already, run BEFORE this skill:** `scripts/install.ps1` (see README) links `skills/`/`hooks/`/`CLAUDE.md`/`harness-config.json` into `~/.claude` and merges `settings.template.json` into the adopter's real `settings.json`. This skill only fills in `harness-config.json`'s values — if links aren't set up yet, point the user at the README's install section first.
7. Tell user: AMA_APP-specific skills assume a fleet shaped like this org's (ECS-deployed .NET services, Octopus, Bitbucket, Jira/Confluence via Atlassian MCP) — different shape, skip that content. Only the general-purpose skills apply regardless of org: `commit-ticket`, `resource-efficiency`, `chat-log-reads`, `caveman`, `karpathy-guidelines`, `rename-topic`, `relocate-session`, `process-prompt-queue`, `write-a-skill`.

## Verifying it took

Scripts/hooks read config with a graceful fallback (`jq -r '.path // "<default>"'`) — a missing or malformed field silently falls back to the original hardcoded default, no error. Spot-check with:

```bash
jq '.' "$HOME/.claude/harness-config.json"
jq '.reposRoots, .sandboxTrustedRoots' "$HOME/.claude/.harness-local.json"
jq '.claudeInChromeDefaultEnabled, .cachedChromeExtensionInstalled, .hasCompletedClaudeInChromeOnboarding' "$HOME/.claude.json"
```

Confirm no `example.com` / `yourorg` / `000000000000` placeholders remain in groups the user said apply to them, and that `sandboxTrustedRoots` isn't empty/missing if the user wants routine work in their own repos to skip permission prompts. For step 5b: `claudeInChromeDefaultEnabled` is the opt-in itself; the other two keys are only **cached** history (extension seen once, ever) — not proof it's installed and connected right now. The real check is `/chrome`'s own status panel showing "Status: Enabled" and "Extension: Installed".
