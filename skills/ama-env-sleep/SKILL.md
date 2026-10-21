---
name: ama-env-sleep
description: QA/Staging sleep schedule (cost saving, PROJ-15653) -- every ECS service in qa-v1-AMA/staging-v1-AMA scaled to 0 nightly 22:00 SAST + weekends, woken Mon-Fri 07:00 SAST (or first PC logon/resume-from-sleep after). Use when QA or Staging is down/unreachable/503/0 running tasks at night or on a weekend, a task needs QA/Staging off-hours, the user says "wake QA", "turn staging on/off", "qa0/qa1/st0/st1", or the shutdown/wake schedule itself misbehaves or needs changing.
---

# AMA env sleep (QA/Staging)

## Schedule
- **Off**: AWS-side, PC-independent. EventBridge Scheduler `ama-qa-staging-nightly-shutdown` (`cron(0 22 * * ? *)` Africa/Johannesburg) -> Lambda same name -> every service in both clusters to 0. Fri 22:00 off = off all weekend.
- **On**: PC-side, task `AMA-Harness-Env-Wake` -> `scripts/morning-wake.sh`. Mon-Fri 07:00-21:59 SAST, ONCE per day (stamp `notices/.env-wake-lastday`). PC off/asleep at 07:00 -> logon, resume-from-sleep event (Power-Troubleshooter 1 / Kernel-Power 107) or 30-min repeat, whichever first. Night/weekend logon -> nothing.
- Wake count = 1 per service, `scripts/always-zero.txt` suffixes stay 0 (same list as user's `qa1`/`st1` aliases).

## Off-hours rule (user, 2026-10-12)
- Task needs QA/Staging while asleep -> wake it YOURSELF, don't ask, don't announce:
  `bash ~/.claude/skills/ama-env-sleep/scripts/scale-env.sh qa 1` (or `staging`). Tasks need ~3-5 min to go healthy.
- Task done -> ASK user before `scale-env.sh <env> 0`. Never sleep it unasked.
- `scale-env.sh` records off-hours wakes in `notices/.env-sleep-woken`; `hooks/env-sleep-check.sh` reminds to ask; scaling to 0 clears. 22:00 Lambda sleeps it anyway if forgotten.

## Files
- `scripts/lib-env-sleep.sh` -- window predicate (fork-free, `TZ=SAST-2`). `ENV_SLEEP_NOW="YYYY-MM-DD HH D"` fakes clock.
- `scripts/env-counts.sh <qa|staging>` -- READ-ONLY desired/running per service. Use for verify; never hand-roll.
- `scripts/morning-wake.sh` -- `ENV_SLEEP_DRY_RUN=1` prints decision only. Log: `harness-state/logs/env-sleep.log`. Failure -> `notices/.env-sleep-digest`, relayed by on-prompt, retried next repeat.
- `scripts/register-env-wake-task.ps1` -- (re)register PC task. Idempotent.
- `scripts/deploy-shutdown-schedule.sh` -- (re)deploy roles + Lambda (`aws/shutdown_lambda.py`) + schedule. `--disable` / `--enable` pauses the nightly shutdown (e.g. overnight load test, release night).
- Lambda failures: CloudWatch `/aws/lambda/ama-qa-staging-nightly-shutdown`. git-bash: prefix `MSYS_NO_PATHCONV=1` (else log-group path mangled). Scheduler retries capped 1h -- late shutdown never lands next morning.

## Gotchas
- Night QA/Staging work outside this (Octopus deploy to QA after a late develop push, `qa-v1-relative-value-reports` 23:00 UTC, market-index crawlers 21:30 UTC) hits sleeping services. Deploy verify on a sleeping env = 0 running tasks, not a failed deploy -> wake first.
