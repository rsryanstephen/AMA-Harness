#!/usr/bin/env bash
# EXPLAIN every distinct SQL SHAPE a changed build emits, against the real Redshift planner.
#
# Usage:
#   rs-explain-shapes.sh dir:<path> [--env qa|staging|production] [--max N]
#   rs-explain-shapes.sh graylog:<application>:<env> --build <2.0.0.N> [--hours H]
#                        [--inventory-hours H] [--service <ecs-short-name>] [--max N]
#     e.g. graylog:product-service-search-api:staging --build 2.0.0.216 --inventory-hours 336
#
# Exit: 0 all OK | 1 any FAIL (planner rejected the SQL) | 2 usage / refused | 3 MISSING shapes.
#
# Why (PROJ-15416 -> 15463, da198cdd, 15801, 15808): one change at a shared builder broke
# four OTHER query shapes that wrap its output. Each was a planner rejection (42P01/42803/42601)
# that EXPLAIN catches with zero execution, but verification had run one shape -- and hand-written
# SQL, not what the builder emits. See ama-debugging-notes/SHARED-CHOKEPOINT-CHANGES.md.
#
# The SQL under test ALWAYS comes from the changed build:
#   dir:      golden/expected SQL a test suite produced from the changed code (real table names).
#   graylog:  SQL the app logged (Debug, QA/Staging only -- Production does not log SQL) AFTER
#             --build became the running image on every task. The window start is the ECS
#             DEPLOYMENT's createdAt + 10 min (not the task start: QA/Staging sleep nightly and
#             wake with a fresh task, which would discard yesterday's runs on the same build), and
#             an earlier window is refused: logs from before the deploy are the OLD code's SQL and
#             would pass green on a broken build.
# --inventory-hours reads the window BEFORE the rollout, but only as a list of shape keys to
# cover -- nothing from it is EXPLAINed. A key there with no new-build sample prints MISSING:
# a shape nobody exercised on the new build (run the `main` cache update, or drive that report).
#
# Shape key = log prefix + the CTE names and wrapper constructs (UNION ALL, sub-select wrap,
# GROUP BY, HAVING, window fn, LIMIT) -- deliberately NOT a hash of the text, which every change
# to a measure would alter, matching nothing across builds. Up to 3 samples per key are EXPLAINed.
#
# EXPLAIN is planner-only: allowed inside the Mon-Fri 9-5 ET Redshift window (AGENTS.md).
set -uo pipefail
export MSYS_NO_PATHCONV=1

HERE="$(cd "$(dirname "$0")" && pwd)"
RSQ="$HERE/rs-query.sh"
RECON="$HOME/.claude/skills/ama-graylog-search/scripts/graylog-reconstruct-sql.sh"
PREFIXES="ExecuteAsync::SQL ExecuteRowCountAsync::SQL ExecuteTopRowAsync::SQL BuildQueryForExport::SQL"

die() { echo "rs-explain-shapes: $*" >&2; exit 2; }
src="${1:-}"; [ -n "$src" ] || die "usage: see header"; shift
ENV=""; BUILD=""; HOURS=24; INVH=0; SERVICE=""; MAX=80
while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --hours) HOURS="$2"; shift 2 ;;
    --inventory-hours) INVH="$2"; shift 2 ;;
    --service) SERVICE="$2"; shift 2 ;;
    --max) MAX="$2"; shift 2 ;;
    *) die "unknown arg $1" ;;
  esac
done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/new" "$WORK/inv"
. "$HOME/.claude/hooks/lib-claude-paths.sh" || die "lib-claude-paths.sh missing"
FAILDIR="$(dirname "$(hscratch sql-shape-sweep x)")"   # failing SQL kept here for the fix

# shape_key <file> <prefix> -> one line
shape_key() {
  perl -0777 -ne '
    $s = lc $_; my %f;
    while ($s =~ /\b([a-z_][a-z0-9_]*)\s+as\s*\(/g) { my $n = $1; $n =~ s/__.*//; $n =~ s/[0-9a-f]{8,}/H/g; $n =~ s/\d+/N/g; $f{"cte:$n"} = 1 }
    $f{union} = 1   if $s =~ /\bunion\s+all\b/;
    $f{wrap} = 1    if $s =~ /\)\s*(as\s+)?sq\b/;
    $f{groupby} = 1 if $s =~ /\bgroup\s+by\b/;
    $f{having} = 1  if $s =~ /\bhaving\b/;
    $f{window} = 1  if $s =~ /\bover\s*\(/;
    $f{limit} = 1   if $s =~ /\blimit\s+\d/;
    print((join(",", sort keys %f) || "plain"), "\n");' "$1" | sed "s/^/$2|/"
}
# families <file>... -> "<family>\t<sample alias>" per select-alias family. The shape key above
# deliberately ignores measures, so a sweep can be all OK while a whole measure KIND (trend
# columns, pivots) never ran -- exactly the 15808 blind spot. Family = alias prefix before `__`
# with the period collapsed (`count_202511_<table>` -> `trend:count`); table-named prefixes are
# group-by columns, not measures, and are skipped.
families() {
  perl -0777 -ne '
    $s = lc $_;
    while ($s =~ /\bas\s+"?([a-z][a-z0-9_]*__[a-z0-9_]+)"?/g) {
      my $a = $1; (my $f = $a) =~ s/__.*//;
      if ($f =~ /^([a-z]+)_\d{6}_/) { $f = "trend:$1" } elsif ($f =~ /_source$/) { next }
      $f =~ s/\d+/N/g; print "$f\t$a\n" unless $seen{$f}++;
    }' "$@"
}
# Normalised text hash: same query, different literals/aliases -> same sample.
norm_hash() { perl -0777 -pe '$_ = lc; s/\x27[^\x27]*\x27/?/g; s/\ba[0-9a-f]{32}\b/A/g; s/\d+/0/g; s/\s+/ /g' "$1" | md5sum | cut -c1-12; }
# resultsprocessor logs the bare SELECT, but strip an UNLOAD wrapper if one appears.
unwrap_unload() {
  perl -0777 -i -pe 'if (/^\s*unload\s*\(\s*\x27/i) { s/^\s*unload\s*\(\s*\x27//i; s/\x27\s*\)\s*to\s+\x27[\s\S]*$//i; s/\x27\x27/\x27/g } s/;\s*$//' "$1"
}

# split_recon <prefix> <outdir> <window> <env>: reconstructed groups -> one .sql file each
split_recon() {
  local p="$1" out="$2" win="$3" env="$4" tag wend
  tag="$(printf '%s' "$p" | tr -cd 'A-Za-z')"
  # A query straddling a window edge arrives cut (tail past the end -> "syntax error at end of
  # input"). Fetch 60 s past the end, keep only groups that START by the end and at Part 1.
  wend="${win#*..}"; win="${win%..*}..$(iso $(( $(date -u -d "$wend" +%s) + 60 )))"
  GRAYLOG_NO_SUPPRESS=1 GRAYLOG_RECON_LIMIT=1000 bash "$RECON" "$APP" "$win" "$p" "$env" 2>/dev/null \
    | awk -v d="$out" -v t="$tag" -v e="${wend:0:23}" '
        /^=== / { match($0, /\(([0-9]+) part/, m); parts += m[1]
                  if (substr($0, 5, 23) > e || $0 !~ /from part 1\)$/) { f = ""; next }
                  n++; f = sprintf("%s/%s_%04d.sql", d, t, n); next }
        f { print >> f }
        END { print parts+0 > (d "/" t ".parts") }'
  # Hit the 1000-message cap -> the oldest group may be missing its first parts; drop it.
  if [ "$(cat "$out/$tag.parts" 2>/dev/null || echo 0)" -ge 1000 ]; then rm -f "$out/${tag}_0001.sql"; fi
  rm -f "$out/$tag.parts"
  for f in "$out/${tag}"_*.sql; do [ -s "$f" ] || rm -f "$f"; done 2>/dev/null
  printf '%s\n' "$tag"
}

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }

case "$src" in
  dir:*)
    d="${src#dir:}"; [ -d "$d" ] || die "no such dir $d"
    ENV="${ENV:-staging}"
    find "$d" -type f -name '*.sql' | sort | awk -v w="$WORK/new" '{ printf "cp \"%s\" \"%s/DIR_%04d.sql\"\n", $0, w, NR }' | bash
    ;;
  graylog:*)
    rest="${src#graylog:}"; APP="${rest%%:*}"; ENV="${rest#*:}"
    [ -n "$APP" ] && [ "$ENV" != "$rest" ] || die "graylog:<application>:<env>"
    [ -n "$BUILD" ] || die "graylog: needs --build <version> -- without it old-code SQL could be tested"
    [ "$ENV" = production ] && die "Production does not log SQL (Debug off) -- sweep QA or Staging"
    short="${SERVICE:-$(printf '%s' "$APP" | sed -e 's/^product-service-//' -e 's/-api$//')}"
    case "$short" in
      *-esvc|*-isvc) svc="$short" ;;
      search) svc="$ENV-v1-search-api-isvc" ;;
      export-cohort|cohorts) svc="$ENV-v1-cohorts-api-esvc" ;;
      *) svc="$ENV-v1-$short-api-esvc" ;;
    esac
    cluster="$ENV-v1-AMA"
    arns="$(aws ecs list-tasks --cluster "$cluster" --service-name "$svc" --desired-status RUNNING --query 'taskArns' --output text 2>/dev/null | tr -d '\r')"
    [ -n "$arns" ] && [ "$arns" != None ] || die "no RUNNING tasks for $svc in $cluster (wrong --service?)"
    # shellcheck disable=SC2086
    tasks="$(PYTHONUTF8=1 aws ecs describe-tasks --cluster "$cluster" --tasks $arns --output json 2>/dev/null)"
    imgs="$(printf '%s' "$tasks" | jq -r '.tasks[].containers[0].image | sub(".*:"; "")' | tr -d '\r' | sort -u)"
    [ "$imgs" = "$BUILD" ] || die "$svc RUNNING images are [$(echo $imgs)] -- not all $BUILD yet; wait for the rollout (wait-ecs-rollout.sh)"
    # Anchor on the DEPLOYMENT, not the task: QA/Staging scale to zero nightly (ama-env-sleep), so
    # every morning's task has a fresh startedAt and yesterday's runs on the same build would read
    # as old-code SQL. deployments[0].createdAt is when this task definition was rolled out and
    # survives the sleep/wake cycle (updatedAt does not -- it moves on every wake). +10 min covers
    # the old tasks draining (ALB deregistration delay 5 min) before their SQL stops.
    dep="$(PYTHONUTF8=1 aws ecs describe-services --cluster "$cluster" --services "$svc" \
      --query 'services[0].deployments[0].{created:createdAt,td:taskDefinition,n:length(@)}' --output json 2>/dev/null | tr -d '\r')"
    created="$(printf '%s' "$dep" | jq -r '.created // empty')"
    [ -n "$created" ] || die "could not read the deployment of $svc"
    dep_img="$(PYTHONUTF8=1 aws ecs describe-task-definition --task-definition "$(printf '%s' "$dep" | jq -r .td)" \
      --query 'taskDefinition.containerDefinitions[0].image' --output text 2>/dev/null | tr -d '\r' | sed 's/.*://')"
    [ "$dep_img" = "$BUILD" ] || die "$svc current deployment is $dep_img, not $BUILD"
    since=$(( $(date -u -d "$created" +%s) + 600 ))
    now=$(date -u +%s); from=$(( now - HOURS*3600 )); [ "$from" -lt "$since" ] && from=$since
    [ "$from" -lt "$now" ] || die "build $BUILD has run under 2 min -- nothing to sweep yet"
    echo "new-build window: $(iso "$from")..$(iso "$now") ($svc @ $BUILD)"
    for p in $PREFIXES; do split_recon "$p" "$WORK/new" "$(iso "$from")..$(iso "$now")" "$ENV" >/dev/null; done
    if [ "$INVH" -gt 0 ]; then
      ifrom=$(( since - 120 - INVH*3600 ))
      for p in $PREFIXES; do split_recon "$p" "$WORK/inv" "$(iso "$ifrom")..$(iso $(( since - 120 )))" "$ENV" >/dev/null; done
    fi
    ;;
  *) die "source must be dir:<path> or graylog:<application>:<env>" ;;
esac

case "$ENV" in qa) user=ama_qa ;; staging) user=ama_staging ;; production) user=ama_production ;; *) die "--env qa|staging|production" ;; esac

# Pick samples: <= 3 per shape key, distinct normalised text, total <= MAX.
: > "$WORK/picked"
for f in "$WORK"/new/*.sql; do
  [ -e "$f" ] || continue
  unwrap_unload "$f"
  grep -qi 'select' "$f" || continue   # a stray log fragment, not a query
  b="$(basename "$f")"; key="$(shape_key "$f" "${b%%_*}")"
  printf '%s\t%s\t%s\n' "$key" "$(norm_hash "$f")" "$f"
done | sort -t$'\t' -k1,1 -k2,2 -u | awk -F'\t' -v max="$MAX" '{ if (++c[$1] <= 3 && ++t <= max) print }' > "$WORK/picked"

total=0; ok=0; fail=0
while IFS=$'\t' read -r key _ f; do
  total=$((total+1))
  { printf 'EXPLAIN '; cat "$f"; } > "$WORK/q.sql"
  if err="$(RS_DB_USER="$user" bash "$RSQ" "@$WORK/q.sql" 2>&1 >/dev/null)"; then
    ok=$((ok+1)); echo "OK    $key"
  else
    fail=$((fail+1)); echo "FAIL  $key  :: $(printf '%s' "$err" | tr -d '\r' | tr '\n' ' ' | cut -c1-220)"
    kept="$FAILDIR/$(date -u +%Y%m%dT%H%M%S)-$total.sql"; cp "$f" "$kept" && echo "      sql: $kept"
  fi
done < "$WORK/picked"
[ "$total" -gt 0 ] || { echo "no SQL found to EXPLAIN"; exit 3; }

missing=0
if [ -n "$(ls "$WORK"/inv/*.sql 2>/dev/null)" ]; then
  cut -f1 "$WORK/picked" | sort -u > "$WORK/newkeys"
  for f in "$WORK"/inv/*.sql; do b="$(basename "$f")"; shape_key "$f" "${b%%_*}"; echo; done | sed '/^$/d' | sort -u > "$WORK/invkeys"
  comm -23 "$WORK/invkeys" "$WORK/newkeys" > "$WORK/missing"
  while IFS= read -r k; do missing=$((missing+1)); echo "MISSING $k"; done < "$WORK/missing"
  # Informational ONLY -- never counted in missing/exit 3: the preflight gate reads those, and
  # trend/pivot requests may never come from the cache-update crawl, so folding this in would
  # block every SQL-touching deploy. A FAMILY line = drive a report using that column, then re-run.
  families "$WORK"/new/*.sql 2>/dev/null | cut -f1 | sort -u > "$WORK/newfam"
  families "$WORK"/inv/*.sql 2>/dev/null | sort -t$'\t' -k1,1 -u > "$WORK/invfam"
  join -t$'\t' -v1 "$WORK/invfam" "$WORK/newfam" | while IFS=$'\t' read -r fam sample; do
    echo "FAMILY  $fam  not emitted by the new build -- e.g. a column aliased $sample (informational, not in the exit code)"
  done
fi

echo "SUMMARY ok=$ok fail=$fail missing=$missing explained=$total env=$ENV build=${BUILD:-dir}"
printf '%s\t%s\t%s\tok=%s fail=%s missing=%s\t%s\n' "$(date -u +%FT%TZ)" "${APP:-$src}" "$ENV" "$ok" "$fail" "$missing" "${BUILD:-dir}" >> "$(hstate tickets sql-shape-sweep)"
[ "$fail" -gt 0 ] && exit 1
[ "$missing" -gt 0 ] && exit 3
exit 0
