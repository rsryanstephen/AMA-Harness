#!/usr/bin/env bash
# Plans an AWS notice triage run. Unlike embs-notices-plan.sh -- whose source (Gmail) is
# MCP-only so it can only emit a search window -- the AWS Health API is reachable from
# bash, so this script does the real diffing work: it fetches open/upcoming events, diffs
# them against the ledger, and classifies affected entities. Claude only judges what
# survives.
#
# Three verdicts come out of the ledger diff, and they exist because Health events stay
# `open` for a year or more while their lastUpdatedTime churns:
#   suppressed -- arn + lastUpdatedTime both match a row. Dropped, zero API cost.
#   restamp    -- lastUpdatedTime moved but the description hash did NOT. Churn, not news:
#                 caller restamps the row and does NOT re-Slack. Without this, six
#                 year-old ELASTICACHE_UPDATE_AVAILABLE events re-flag every week and the
#                 monitor gets muted -- which is how the Redis OSS EOL got missed.
#   candidate  -- new arn, or description hash genuinely changed. Real triage.
# Plus watchDue[]: rows parked with disposition `watch` whose deadline is now inside
# watchLeadDays. Those re-surface regardless of key match -- a distant deadline earns a
# park, event age never does.
#
# Deliberately NO region or service filter on describe-events (only eventStatusCodes).
# Confirmed during design: `--filter regions=us-east-1` silently drops a real eu-west-1
# AWS_LAMBDA_PLANNED_LIFECYCLE_EVENT naming lpc-adept-delta-{test,prod} on 2026-11-10 --
# the same dotnet8/9 retirement date SHARED-INFRA-AND-PIPELINES.md tracks independently.
# Scoping is judgement (AMA-AWS-SURFACE.md), never a flag.
#
# BATCHED on purpose. Both describe-event-details and describe-affected-entities take up
# to 10 event ARNs per call, and aws.exe costs ~1.5-2s per invocation on this box. The
# first cut called them once per event: ~30 events x 2 calls = over two minutes. Batching
# takes the same run to seconds. Chunk size 10 is the API's own cap, not a guess.
#
# jq trap, hit twice while writing this: `end` is a jq keyword (if/then/else/end) and
# jq-1.5rc1 rejects it BOTH as a variable (`$end`) and as an unquoted object key (`end:`).
# It fails with a bare "syntax error, unexpected end" pointing at the wrong line. Hence
# `$endT` below. Don't reintroduce it.
#
# Usage: aws-notices-plan.sh
# Output: one JSON object on stdout.
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"

# Decides WHERE findings are delivered -- a silent default would DM the wrong person or
# nobody, same reasoning as hr_config_required's own comment.
TARGET="$(hr_config_required '.awsNotices.reportTarget')" || exit 1

LOOKBACK="$(hr_config '.awsNotices.lookbackDays' 120)"
OVERLAP="$(hr_config '.awsNotices.overlapDays' 3)"
MIN_TIER="$(hr_config '.awsNotices.slackMinTier' 2)"
WATCH_LEAD="$(hr_config '.awsNotices.watchLeadDays' 30)"
FORWARDERS_JSON="$(jq -c '.awsNotices.noticeForwarders // []' < "$HR_CONFIG_FILE" 2>/dev/null | sed 's/\r$//')"
[ -n "$FORWARDERS_JSON" ] || FORWARDERS_JSON='[]'
LABELS_JSON="$(jq -c '.awsNotices.noticeLabels // []' < "$HR_CONFIG_FILE" 2>/dev/null | sed 's/\r$//')"
[ -n "$LABELS_JSON" ] || LABELS_JSON='[]'

. "$HOME/.claude/hooks/lib-claude-paths.sh"
SEEN="$(hstate notices .aws-notices-seen)"
LASTRUN="$(hstate notices .aws-notices-lastrun)"
touch "$SEEN"

today="$(date +%F)"

# Gmail's after: takes YYYY/MM/DD (the email leg). Health filtering is by status, not date.
floor_lookback="$(date -d "$LOOKBACK days ago" +%Y/%m/%d 2>/dev/null)" || floor_lookback=""
if [ -z "$floor_lookback" ]; then
  printf 'aws-notices-plan.sh: date arithmetic failed (need GNU date)\n' >&2
  exit 1
fi
since="$floor_lookback"
if [ -s "$LASTRUN" ]; then
  last="$(tr -d ' \r\n' < "$LASTRUN")"
  cand="$(date -d "$last -$OVERLAP days" +%Y/%m/%d 2>/dev/null || true)"
  if [ -n "$cand" ] && [ "$cand" \> "$floor_lookback" ]; then since="$cand"; fi
fi

tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT

# One --filter with comma-separated k=v pairs. Repeated --filter flags silently keep only
# the LAST one -- a trap worth naming because the failure is quiet, not an error.
# NO --max-items. It caps the CLI's own pagination and emits a NextToken this script never
# read, and describe-events returns NEWEST first -- so truncation silently discarded the
# OLDEST open events, which is exactly the long-open EOL shape this skill exists to catch.
# Verified: without the flag the CLI aggregates all pages into one JSON object with no
# NextToken, so the jq parse below is unaffected.
if ! MSYS_NO_PATHCONV=1 aws health describe-events \
      --filter eventStatusCodes=open,upcoming \
      --output json > "$tmpd/events.json" 2>"$tmpd/events.err"; then
  printf 'aws health describe-events failed:\n' >&2
  cat "$tmpd/events.err" >&2
  exit 1
fi
# A NextToken here would mean the CLI paginator stopped early after all -- fail loud
# rather than silently reporting a partial event set as complete.
if [ "$(jq -r 'has("NextToken")' < "$tmpd/events.json" 2>/dev/null)" = "true" ]; then
  printf 'aws health describe-events returned a NextToken -- event set is PARTIAL, refusing to report it as complete\n' >&2
  exit 1
fi

jq -r '.events[] | [.arn, .eventTypeCode, (.region // "global"), (.service // ""),
       (.eventTypeCategory // ""), (.lastUpdatedTime // ""), (.startTime // ""),
       (.endTime // ""), (.statusCode // "")] | @tsv' \
  < "$tmpd/events.json" | sed 's/\r$//' > "$tmpd/events.tsv"
health_event_count="$(wc -l < "$tmpd/events.tsv" | tr -d ' ')"

# --- The surfaces Health structurally cannot see (PROJ-15336) --------------------
# aws-notices-surfaces.sh reads Trusted Advisor, pending maintenance, ACM, Access Analyzer
# and the version censuses, and emits them in THIS script's own row shape. They join
# events.tsv here, before the ledger diff, so they inherit suppress/restamp/watch unchanged
# -- the whole reason they are synthetic rows rather than a second pipeline.
#
# They carry their own description and entities, so they must never reach pass 2: there is
# no Health event behind a `synthetic:` arn and describe-event-details would fail the whole
# chunk of 10 it landed in, marking nine real events unfetched. Pass 1 routes them out.
#
# A failure here is NOT fatal. Health is the older, load-bearing leg and a broken new
# surface must not take the weekly sweep down with it; the count reaching the caller says
# whether the legs ran, so a silent zero is still visible as a zero.
: > "$tmpd/synthetic.jsonl"
SURFACES="$(dirname "${BASH_SOURCE[0]}")/aws-notices-surfaces.sh"
surface_err=""
if [ -x "$SURFACES" ]; then
  if ! bash "$SURFACES" > "$tmpd/synthetic.jsonl" 2>"$tmpd/surfaces.err"; then
    surface_err="$(tr -d '\r\n' < "$tmpd/surfaces.err" | cut -c1-200)"
    : > "$tmpd/synthetic.jsonl"
  fi
else
  surface_err="aws-notices-surfaces.sh missing or not executable at $SURFACES"
fi

jq -r '[.arn, .typeCode, .region, .service, .eventTypeCategory, .lastUpdatedTime,
        .startTime, .endTime, .statusCode] | @tsv' \
  < "$tmpd/synthetic.jsonl" 2>/dev/null | sed 's/\r$//' >> "$tmpd/events.tsv"

synthetic_count="$(wc -l < "$tmpd/synthetic.jsonl" | tr -d ' ')"
event_count="$(wc -l < "$tmpd/events.tsv" | tr -d ' ')"

# --- Pass 1: ledger diff, no API calls. Decide who needs a detail fetch. -------------
#
# Suppression is CONDITIONAL ON lastrun EXISTING, and that is the whole point. The first
# real run wrote 15 ledger rows and never called `finish`, so `lastrun` was absent while
# the rows were present -- which suppressed those 15 events (they matched on
# arn+lastUpdatedTime) at the same time as aws-notices-check.sh read "never swept" and
# nudged. The next run was told to sweep and would have found the 15 most important events
# invisible. The design claimed "an interrupted run re-fires"; that was true of the STAMP
# and false of the TRIAGE.
# No lastrun => the previous run never closed => suppress nothing, and hand the caller the
# prior tier/disposition so it can see what was already judged.
prior_run="closed"
[ -s "$LASTRUN" ] || prior_run="unclosed"

: > "$tmpd/need_detail.txt"
: > "$tmpd/suppressed.txt"
while IFS=$'\t' read -r arn code region service category lastupd start endT status; do
  [ -n "$arn" ] || continue
  prev_upd="$(awk -F'\t' -v a="$arn" '$1==a{print $2; exit}' "$SEEN")"
  if [ "$prior_run" = "closed" ] && [ -n "$prev_upd" ] && [ "$prev_upd" = "$lastupd" ]; then
    printf '%s\n' "$arn" >> "$tmpd/suppressed.txt"
    continue
  fi
  # Synthetic rows already carry their description and entities -- never send them to the
  # Health detail API (see the surfaces block above for why one would poison a whole chunk).
  case "$arn" in synthetic:*) continue ;; esac
  printf '%s\n' "$arn" >> "$tmpd/need_detail.txt"
done < "$tmpd/events.tsv"

suppressed_count="$(wc -l < "$tmpd/suppressed.txt" | tr -d ' ')"

# --- Pass 2: batched detail + entity fetches (10 ARNs per call, the API cap). ---------
: > "$tmpd/details.jsonl"
: > "$tmpd/entities.jsonl"
if [ -s "$tmpd/need_detail.txt" ]; then
  split -l 10 "$tmpd/need_detail.txt" "$tmpd/chunk_"
  for chunk in "$tmpd"/chunk_*; do
    [ -s "$chunk" ] || continue
    # shellcheck disable=SC2046
    set -- $(cat "$chunk")
    # Errors are CAPTURED, not discarded, and failedSet is read. Before this, a throttle,
    # an expired token mid-run or one bad ARN in a chunk of 10 produced desc="" -> the
    # hash of the empty string -> an event that looked empty, entity-less and
    # sentinel-shaped. Triage it T5 and it is suppressed forever; and because sha1("") is
    # a stable value, a REPEATED failure routed it to `restamp` as "churn, not news" --
    # an event whose description was never read once.
    if ! MSYS_NO_PATHCONV=1 aws health describe-event-details --event-arns "$@" \
          --output json > "$tmpd/det.json" 2>"$tmpd/det.err"; then
      # Whole call failed: mark every arn in the chunk as unfetched.
      while IFS= read -r a; do
        [ -n "$a" ] || continue
        jq -nc --arg arn "$a" --arg err "$(tr -d '\r\n' < "$tmpd/det.err" | cut -c1-200)" \
          '{arn:$arn, desc:"", fetchError:$err}' >> "$tmpd/details.jsonl"
      done < "$chunk"
    else
      jq -c '.successfulSet[]? | {arn:.event.arn, desc:(.eventDescription.latestDescription // ""), fetchError:null}' \
        < "$tmpd/det.json" >> "$tmpd/details.jsonl" || true
      jq -c '.failedSet[]? | {arn:.eventArn, desc:"", fetchError:((.errorName // "unknown") + ": " + (.errorMessage // ""))}' \
        < "$tmpd/det.json" >> "$tmpd/details.jsonl" || true
    fi
    arns_csv="$(paste -sd, "$chunk")"
    MSYS_NO_PATHCONV=1 aws health describe-affected-entities \
      --filter eventArns="$arns_csv" \
      --query 'entities[].{arn:eventArn,value:entityValue}' \
      --output json 2>/dev/null \
      | jq -c '.[]?' >> "$tmpd/entities.jsonl" || true
  done
fi

# arn -> description, and arn -> newline-joined entity values. Built once, read per event.
jq -sc 'map(select(.arn != null)) | map({(.arn): (.desc // "")}) | add // {}' \
  < "$tmpd/details.jsonl" > "$tmpd/desc_map.json" 2>/dev/null || echo '{}' > "$tmpd/desc_map.json"
[ -s "$tmpd/desc_map.json" ] || echo '{}' > "$tmpd/desc_map.json"

# arn -> fetch error, so pass 3 can refuse to hash or restamp an event it never read.
jq -sc 'map(select(.arn != null and .fetchError != null))
        | map({(.arn): .fetchError}) | add // {}' \
  < "$tmpd/details.jsonl" > "$tmpd/err_map.json" 2>/dev/null || echo '{}' > "$tmpd/err_map.json"
[ -s "$tmpd/err_map.json" ] || echo '{}' > "$tmpd/err_map.json"

# Sentinel strip happens HERE, before anything is counted: entity count > 0 is not
# relevance. Four sentinel shapes, all found on the real account -- the documented
# AWS_ACCOUNT/UNKNOWN pair covered only half of them:
#   AWS_ACCOUNT / UNKNOWN  -- the documented pair
#   the bare account number -- returned verbatim (e.g. "000000000000") by the BILLING,
#     CLOUDWATCH, ECR, ECS, S3 and TRUSTEDADVISOR lifecycle events. Semantically identical
#     to AWS_ACCOUNT; left unstripped it produced ~8 phantom "unclassified" rows a run,
#     each one demanding a pointless human decision.
#   a bare region name -- AWS_SDK_PLANNED_LIFECYCLE_EVENT lists 14 of them (ap-south-1,
#     eu-west-2 ...). Regions are scope, not resources.
#
# Regions are matched against a REAL ALLOWLIST, not a shape regex. The first cut used
# `^[a-z]{2}(-[a-z]+)+-[0-9]+$`, which also matches real resource names -- verified:
# `hs-prod-1`, `hs-qa-2`, `db-main-2` and `es-node-3` were all stripped as "regions". A
# production node named that way would have had its only entity deleted, leaving the event
# looking sentinel-only and benign. The allowlist is fetched per run so it cannot go stale.
ACCT="$(hr_config '.aws.accountNumber' '')"
REGIONS_JSON="$(MSYS_NO_PATHCONV=1 aws ec2 describe-regions --all-regions \
                  --query 'Regions[].RegionName' --output json 2>/dev/null | jq -c '.' 2>/dev/null)"
if [ -z "$REGIONS_JSON" ] || [ "$REGIONS_JSON" = "null" ]; then
  # Fail closed: strip nothing rather than guess by shape. A few extra `unclassified`
  # rows to ask about beats silently deleting a production resource.
  printf 'aws-notices-plan.sh: could not fetch the region list -- not stripping region-shaped entities this run\n' >&2
  REGIONS_JSON='[]'
fi
jq -sc --arg acct "$ACCT" --argjson regions "$REGIONS_JSON" \
       'map(select(.arn != null and .value != null))
        | map(select(.value | test("^(AWS_ACCOUNT|UNKNOWN)$") | not))
        | map(select(($acct | length) == 0 or .value != $acct))
        | map(select(.value as $v | ($regions | index($v)) | not))
        | group_by(.arn) | map({(.[0].arn): (map(.value) | unique)}) | add // {}' \
  < "$tmpd/entities.jsonl" > "$tmpd/ent_map.json" 2>/dev/null || echo '{}' > "$tmpd/ent_map.json"
[ -s "$tmpd/ent_map.json" ] || echo '{}' > "$tmpd/ent_map.json"

# Merge the synthetic rows' own descriptions and entities into the maps pass 3 reads. They
# skipped pass 2 entirely, so without this every one of them would look like an event whose
# description is the empty string -- which this script's own pass-2 comment explains is the
# worst possible shape: sha1("") is stable, so it would read as sentinel-shaped and benign
# on the first run and as "churn, not news" on the second.
# Synthetic entities go in AFTER the sentinel/region strip on purpose: they are resource
# names this script chose, not Health's, so there is nothing to strip and running them
# through the account/region filter could only remove something real.
if [ -s "$tmpd/synthetic.jsonl" ]; then
  jq -sc 'map({(.arn): (.desc // "")}) | add // {}' \
    < "$tmpd/synthetic.jsonl" > "$tmpd/syn_desc.json" 2>/dev/null || echo '{}' > "$tmpd/syn_desc.json"
  jq -sc 'map({(.arn): (.entities // [])}) | add // {}' \
    < "$tmpd/synthetic.jsonl" > "$tmpd/syn_ent.json" 2>/dev/null || echo '{}' > "$tmpd/syn_ent.json"
  jq -sc '.[0] * .[1]' "$tmpd/desc_map.json" "$tmpd/syn_desc.json" > "$tmpd/desc_map.merged.json" \
    2>/dev/null && mv "$tmpd/desc_map.merged.json" "$tmpd/desc_map.json"
  jq -sc '.[0] * .[1]' "$tmpd/ent_map.json" "$tmpd/syn_ent.json" > "$tmpd/ent_map.merged.json" \
    2>/dev/null && mv "$tmpd/ent_map.merged.json" "$tmpd/ent_map.json"
fi

# Classify one bare resource name. Patterns + confirmed examples: AMA-AWS-SURFACE.md.
# `unclassified` is deliberately NOT a synonym for irrelevant -- the caller asks.
#
# thirdparty is checked FIRST: Datadog's integration lambdas are named
# Datadog-AWS-Integration-Dat-DatadogAPICallFunction-*, which no env pattern matches, and
# they are not ours to upgrade.
#
# `*production*` (not just `production-*`) because the real account holds
# `hs-production-zip-files` -- an S3 bucket on the production path that the narrower
# prefix missed entirely, classifying a production resource as unclassified. Found by
# running this, not by reading the naming convention.
classify_entity() {
  case "$1" in
    Datadog-*|*-Datadog-*) printf 'thirdparty' ;;
    *production*|hs-prod-*|prod-*|*-prod|*-prod-*) printf 'prod' ;;
    staging-*|hs-staging-*|*staging*|qa-*|hs-qa-*|*-qa|development-*|dev-*|*-test|*-test-*) printf 'nonprod' ;;
    *) printf 'unclassified' ;;
  esac
}

# Worst-case class across an event's entities: prod dominates, because prod membership is
# what separates T1 from T5.
roll_up_class() {
  local seen_prod=0 seen_nonprod=0 seen_unc=0 seen_tp=0 e c
  for e in "$@"; do
    c="$(classify_entity "$e")"
    case "$c" in
      prod) seen_prod=1 ;;
      nonprod) seen_nonprod=1 ;;
      thirdparty) seen_tp=1 ;;
      *) seen_unc=1 ;;
    esac
  done
  if [ "$seen_prod" = 1 ]; then printf 'prod'
  elif [ "$seen_unc" = 1 ]; then printf 'unclassified'
  elif [ "$seen_nonprod" = 1 ]; then printf 'nonprod'
  elif [ "$seen_tp" = 1 ]; then printf 'thirdparty'
  else printf 'none'; fi
}

# --- Pass 3: assemble, using only local data. ----------------------------------------
: > "$tmpd/candidates.jsonl"
: > "$tmpd/restamp.jsonl"

while IFS=$'\t' read -r arn code region service category lastupd start endT status; do
  [ -n "$arn" ] || continue
  grep -qxF -- "$arn" "$tmpd/suppressed.txt" 2>/dev/null && continue

  desc="$(jq -r --arg a "$arn" '.[$a] // ""' < "$tmpd/desc_map.json" | sed 's/\r$//')"
  fetch_err="$(jq -r --arg a "$arn" '.[$a] // ""' < "$tmpd/err_map.json" | sed 's/\r$//')"

  prev_row="$(awk -F'\t' -v a="$arn" '$1==a{print; exit}' "$SEEN")"
  prev_tier=""; prev_disp=""
  [ -n "$prev_row" ] && prev_tier="$(printf '%s' "$prev_row" | cut -f4)"
  [ -n "$prev_row" ] && prev_disp="$(printf '%s' "$prev_row" | cut -f9)"

  # An event we could not read is NOT hashed and NOT restamped. Hashing "" would give a
  # stable value that looks like a real (empty) description, which is how an unread event
  # previously came out as either a benign T5 candidate or, on a repeat failure, as
  # "churn". Emit it as a candidate carrying the error so the caller re-fetches.
  if [ -n "$fetch_err" ]; then
    jq -nc --arg arn "$arn" --arg code "$code" --arg region "$region" --arg service "$service" \
           --arg category "$category" --arg upd "$lastupd" --arg start "$start" \
           --arg endT "$endT" --arg status "$status" --arg err "$fetch_err" \
           --arg ptier "$prev_tier" --arg pdisp "$prev_disp" \
      '{arn:$arn, typeCode:$code, region:$region, service:$service,
        eventTypeCategory:$category, lastUpdatedTime:$upd, startTime:$start, endTime:$endT,
        statusCode:$status, descHash:null, entityClass:"unknown", entities:[],
        entityCount:0, description:"", fetchError:$err,
        priorTier:(if ($ptier|length)>0 then $ptier else null end),
        priorDisposition:(if ($pdisp|length)>0 then $pdisp else null end),
        scopeHint:"DETAIL FETCH FAILED -- re-fetch this event; do NOT triage or record it from this run"}' \
      >> "$tmpd/candidates.jsonl"
    continue
  fi

  new_hash="$(printf '%s' "$desc" | sha1sum | cut -c1-12)"

  if [ -n "$prev_row" ]; then
    prev_hash="$(printf '%s' "$prev_row" | cut -f3)"
    if [ "$new_hash" = "$prev_hash" ]; then
      jq -nc --arg arn "$arn" --arg upd "$lastupd" --arg tier "$prev_tier" \
             --arg disp "$prev_disp" \
        '{arn:$arn, lastUpdatedTime:$upd, tier:$tier, disposition:$disp,
          reason:"lastUpdatedTime moved, description unchanged"}' \
        >> "$tmpd/restamp.jsonl"
      continue
    fi
  fi

  ents_json="$(jq -c --arg a "$arn" '.[$a] // []' < "$tmpd/ent_map.json")"
  # Bare resource name for classification: ARNs put the name last after ':' or '/', and
  # ECS entities arrive as `cluster|service`.
  #
  # `tr -d '\r'` is LOAD-BEARING, not tidiness. This jq build emits CRLF on -r output
  # (the same trap lib-harness-repos.sh's _jqr exists to fix). Without the strip, values
  # arrive as "lpc-adept-delta-prod\r", which silently fails every ANCHORED case pattern
  # -- `*-prod` misses while `*production*` still matches, so the bug shows up on some
  # resources and not others. Real symptom: two eu-west-1 production lambdas classified
  # `unclassified`.
  shorts="$(printf '%s' "$ents_json" \
    | jq -r '.[]? | sub("^.*:";"") | sub("^.*/";"") | sub("^.*\\|";"")' 2>/dev/null \
    | tr -d '\r' | tr '\n' ' ')"
  # shellcheck disable=SC2086
  cls="$(roll_up_class $shorts)"

  # Deadline is NOT derived here. startTime is the ANNOUNCEMENT date, and the real
  # apply-by often sits ~30 days later in the prose (confirmed: an event dated 2026-07-31
  # carried `AWS Recommended Apply By Date: 2026-08-30`, `Auto-Update: no`, on
  # hs-prod-exporter-v3). Emitting a guess here would invite the caller to trust it, so
  # the prose goes out raw and SKILL.md rule 2 does the rest.
  # priorTier/priorDisposition are carried so the caller can see what was already judged.
  # They matter most when priorRun is "unclosed": nothing is suppressed that run, so a
  # previously-triaged event reappears and the caller needs to know it is a re-presentation
  # rather than something new -- and that `retriage`, not `add`, is the way to record it.
  jq -nc --arg arn "$arn" --arg code "$code" --arg region "$region" --arg service "$service" \
         --arg category "$category" --arg upd "$lastupd" --arg start "$start" \
         --arg endT "$endT" --arg status "$status" --arg hash "$new_hash" \
         --arg cls "$cls" --arg desc "$desc" --argjson entities "$ents_json" \
         --arg ptier "$prev_tier" --arg pdisp "$prev_disp" \
    '{arn:$arn, typeCode:$code, region:$region, service:$service,
      eventTypeCategory:$category, lastUpdatedTime:$upd, startTime:$start, endTime:$endT,
      statusCode:$status, descHash:$hash, entityClass:$cls, entities:$entities,
      entityCount:($entities|length), description:$desc, fetchError:null,
      priorTier:(if ($ptier|length)>0 then $ptier else null end),
      priorDisposition:(if ($pdisp|length)>0 then $pdisp else null end),
      scopeHint:(if $cls=="none"
                 then "no-real-entities-after-sentinel-strip: judge at stage 3, do not auto-discard"
                 else "has-real-entities: triage" end)}' \
    >> "$tmpd/candidates.jsonl"
done < "$tmpd/events.tsv"

# watch rows whose lead window has opened -- re-surface regardless of key match.
watch_cut="$(date -d "+$WATCH_LEAD days" +%F 2>/dev/null || echo "$today")"
watch_due="$(awk -F'\t' -v cut="$watch_cut" \
  '$9=="watch" && $10!="-" && $10<=cut {print $1 "\t" $10 "\t" $4}' "$SEEN" \
  | jq -Rsc 'split("\n") | map(select(length>0)) | map(split("\t"))
             | map({arn:.[0], watchUntil:.[1], tier:.[2]})' 2>/dev/null)"
[ -n "$watch_due" ] || watch_due='[]'

pending="$(awk -F'\t' '$9=="pending"{print $1}' "$SEEN" \
  | jq -Rsc 'split("\n") | map(select(length>0))' 2>/dev/null)"
[ -n "$pending" ] || pending='[]'

# Assemble via --argfile, NOT --argjson. The candidate array carries every event's full
# multi-paragraph description; passing that on the command line dies with "Argument list
# too long" (hit for real at ~30 events). --argjson is fine for the small scalars only.
# jq-1.5rc1 has no --slurpfile/--rawfile, but --argfile works -- same constraint
# ama-jira-api's SKILL.md already records.
jq -sc '.' < "$tmpd/candidates.jsonl" > "$tmpd/candidates.json" 2>/dev/null
[ -s "$tmpd/candidates.json" ] || echo '[]' > "$tmpd/candidates.json"
jq -sc '.' < "$tmpd/restamp.jsonl" > "$tmpd/restamp.json" 2>/dev/null
[ -s "$tmpd/restamp.json" ] || echo '[]' > "$tmpd/restamp.json"
printf '%s' "$watch_due" > "$tmpd/watchdue.json"
printf '%s' "$pending" > "$tmpd/pending.json"

jq -nc \
  --arg since "$since" \
  --arg target "$TARGET" \
  --argjson minTier "$MIN_TIER" \
  --argjson watchLead "$WATCH_LEAD" \
  --argjson suppressed "${suppressed_count:-0}" \
  --argjson eventCount "${event_count:-0}" \
  --argjson healthEventCount "${health_event_count:-0}" \
  --argjson syntheticCount "${synthetic_count:-0}" \
  --arg surfaceError "$surface_err" \
  --arg priorRun "$prior_run" \
  --argjson forwarders "$FORWARDERS_JSON" \
  --argjson labels "$LABELS_JSON" \
  --argfile candidates "$tmpd/candidates.json" \
  --argfile restamp "$tmpd/restamp.json" \
  --argfile watchDue "$tmpd/watchdue.json" \
  --argfile pendingArns "$tmpd/pending.json" \
  '{since:$since, reportTarget:$target, slackMinTier:$minTier, watchLeadDays:$watchLead,
    noticeForwarders:$forwarders, noticeLabels:$labels,
    eventCount:$eventCount,
    healthEventCount:$healthEventCount,
    syntheticCount:$syntheticCount,
    surfaceError:(if ($surfaceError|length)>0 then $surfaceError else null end),
    surfaceNote:(if ($surfaceError|length)>0
      then "The non-Health surfaces (Trusted Advisor, pending maintenance, ACM, Access Analyzer, version censuses) did NOT run this sweep -- this window is Health-only and is NOT a clean bill of health for them. Say so rather than reporting an all-clear."
      else "Health events plus the five non-Health surfaces. Synthetic rows carry `synthetic:` arns and are standing conditions, not dated events." end),
    priorRun:$priorRun,
    priorRunNote:(if $priorRun=="unclosed"
      then "Previous run never called finish, so NOTHING was suppressed this run. Events already triaged reappear under restamp[] (verdicts preserved) or as candidates carrying priorTier/priorDisposition -- record those with `retriage`, not `add`."
      else "Previous run closed cleanly; unchanged events were suppressed." end),
    candidates:$candidates, candidateCount:($candidates|length),
    restamp:$restamp, restampCount:($restamp|length),
    watchDue:$watchDue, watchDueCount:($watchDue|length),
    pendingArns:$pendingArns, pendingCount:($pendingArns|length),
    suppressedUnchanged:$suppressed}' \
  | sed 's/\r$//'
