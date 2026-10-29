#!/usr/bin/env bash
# Read-only. Which INFRASTRUCTURE Octopus projects must deploy with this AMA_APP release?
# Infra projects (YourProduct-Backbone group, 49 build.sh components: Base_*, Pricing_*, Applications_*,
# Ingress, Elasticsearch, ClientSFTP...) are a separate Octopus track, never swept into a release,
# so an app change needing infra first (IAM policy, queue, SG, listener) ships without it unless
# someone notices. Keyed on TICKETS, not Octopus versions: most infra projects have never deployed
# to Production through Octopus, so "latest != prod" flags noise (26 projects, 2026-10-15).
#
# Usage: infra-paired-check.sh <version|fix-version> [days=180]   e.g. 131.0.0, hotfix/130.0.4
# (bare version = release/<version>). Run by release-preflight.sh. Commits naming a ticket with that Fix Version -> Octopus project(s) their files map to (the repo's own
# _build/build.sh PACKAGE_PATH -> OCTOPUS_PROJECT_NAME), one line per project:
#   LIVE           prod's last deploy SUCCEEDED and its build commit contains every such commit
#   NOT-IN-PROD    prod's build lacks one, or prod's last deploy FAILED
#   NO-PROD-DEPLOY never deployed to Production through Octopus -- check state/AWS
#   NO-PROJECT     dir has no Octopus project (e.g. Base/Certificates) -- applied locally, check by hand
# Infra repos: INFRA_REPOS (space-separated clone dirs), default the yourproduct-backbone clone.
# Exit 0 always unless Jira/git/Octopus can't be read (2).
set -uo pipefail
fv="${1:?usage: infra-paired-check.sh <version|fix-version> [days]}"; days="${2:-180}"
case "$fv" in */*) ;; *) fv="release/$fv" ;; esac
REPOS="${INFRA_REPOS:-$HOME/Repos/AMA_APP/yourproduct-backbone}"
O="https://yourorg.octopus.app/api/Spaces-1"; H="X-Octopus-ApiKey: ${OCTOPUS_API_KEY:?OCTOPUS_API_KEY unset}"
PB="$HOME/.claude/skills/ama-bitbucket-api/scripts/pipeline-build.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

keys="$(bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-search.sh" \
  "project = PROJ AND fixVersion = \"$fv\"" key 500 | cut -f1 | tr -d '\r' | sort -u)" \
  || { echo "Jira search failed" >&2; exit 2; }
[ -n "$keys" ] || { echo "NONE: no tickets carry Fix Version $fv yet"; exit 0; }
re="$(printf '%s\n' "$keys" | paste -sd'|')"
curl -sfS -H "$H" "$O/projects/all" | tr -d '\r' | jq -r '.[] | "\(.Name)\t\(.Id)"' | tr -d '\r' > "$tmp/proj.tsv" || exit 2
curl -sfS -H "$H" "$O/dashboard?includePrevious=false" | tr -d '\r' \
  | jq -r '.Items[] | select(.EnvironmentId=="<production>") | "\(.ProjectId)\t\(.ReleaseVersion)\t\(.State)\t\(.TaskId)"' | tr -d '\r' > "$tmp/prod.tsv" || exit 2
# A "Failed" prod deploy is often a REJECTED plan approval (nothing applied, on purpose) -- say so,
# and who, so nobody re-investigates it (BackBone_Elasticsearch 2.0.0.74, PROJ-15814).
why_failed() {
  [ -n "${1:-}" ] || return 0
  local r who
  r="$(curl -sfS -H "$H" "$O/interruptions?regarding=$1" | tr -d '\r' \
    | jq -r '[.Items[] | select(.Form.Values.Result=="Abort")][0] // empty | "\(.Title)\t\(.ResponsibleUserId)"' | tr -d '\r')"
  [ -n "$r" ] || return 0
  who="$(curl -sfS -H "$H" "https://yourorg.octopus.app/api/users/$(printf '%s' "$r" | cut -f2)" | jq -r '.DisplayName // empty' | tr -d '\r')"
  printf ' -- REJECTED at "%s" by %s, nothing applied; read that plan before re-deploying' "$(printf '%s' "$r" | cut -f1)" "${who:-?}"
}

: > "$tmp/rows.tsv"   # repo  project  ticket  sha  on-master
for repo in $REPOS; do
  [ -d "$repo/.git" ] || { echo "infra clone not found: $repo" >&2; exit 2; }
  git -C "$repo" fetch -q origin 2>/dev/null || echo "WARN: fetch failed for $repo, cached refs" >&2
  awk '/OCTOPUS_PROJECT_NAME=/{gsub(/.*="|"/,"");p=$0} /PACKAGE_PATH=/{gsub(/.*BASE_PATH\/|"/,""); if(p!="") print $0"\t"p; p=""}' \
    "$repo/_build/build.sh" > "$tmp/map.tsv" 2>/dev/null
  git -C "$repo" log --remotes=origin --no-merges --since="$days days ago" --format='%H%x09%s' \
    | grep -E "($re)([^0-9]|$)" > "$tmp/hits.tsv"
  while IFS=$'\t' read -r sha subj; do
    tk="$(printf '%s' "$subj" | grep -oE "($re)" | head -1)"
    onm=no; git -C "$repo" merge-base --is-ancestor "$sha" origin/master && onm=yes
    # .tf/.tfvars/.json/.py/.sh only -- README/.gitignore changes deploy nothing
    git -C "$repo" show --name-only --format= "$sha" | grep -E '\.(tf|tfvars|json|py|sh|js|yml|yaml)$' \
      | grep -v '^_build/' > "$tmp/files"
    awk -F'\t' 'NR==FNR{m[$1]=$2;next} {hit="";for(k in m) if(index($0,k)==1) hit=m[k];
      if(hit==""){n=split($0,a,"/"); hit="NO-PROJECT:" a[1] (n>2?"/" a[2]:"")} print hit}' \
      "$tmp/map.tsv" "$tmp/files" | sort -u | while read -r pn; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$pn" "$tk" "$sha" "$onm"; done >> "$tmp/rows.tsv"
  done < "$tmp/hits.tsv"
done
[ -s "$tmp/rows.tsv" ] || { echo "NONE: no infra commit in ${days}d names a $fv ticket ($(printf '%s\n' "$keys" | wc -l | tr -d ' ') tickets)"; exit 0; }

cut -f1,2 "$tmp/rows.tsv" | sort -u | while IFS=$'\t' read -r repo pn; do
  tks="$(awk -F'\t' -v r="$repo" -v p="$pn" '$1==r&&$2==p{print $3}' "$tmp/rows.tsv" | sort -u | paste -sd, )"
  offm="$(awk -F'\t' -v r="$repo" -v p="$pn" '$1==r&&$2==p&&$5=="no"{print substr($4,1,8)}' "$tmp/rows.tsv" | sort -u | paste -sd, )"
  case "$pn" in NO-PROJECT:*) st="NO-PROJECT (${pn#NO-PROJECT:}: no Octopus project -- applied locally, check by hand)"; pid="-" ;;
  *)
    pid="$(awk -F'\t' -v n="$pn" 'tolower($1)==tolower(n){print $2}' "$tmp/proj.tsv")"
    pv="$(awk -F'\t' -v p="$pid" '$1==p{print $2" "$3}' "$tmp/prod.tsv")"
    ptask="$(awk -F'\t' -v p="$pid" '$1==p{print $4}' "$tmp/prod.tsv")"
    if [ -z "$pid" ]; then st="NO-PROJECT (build.sh names $pn, Octopus has none)"
    elif [ -z "$pv" ]; then st="NO-PROD-DEPLOY (never via Octopus -- check state/AWS)"
    elif [ "${pv##* }" != "Success" ]; then st="NOT-IN-PROD (prod last deploy $pv$(why_failed "$ptask"))"
    else
      n="${pv%% *}"; n="${n%%-*}"; n="${n##*.}"
      bsha="$(bash "$PB" "$repo" "$n" 2>/dev/null | grep -oE 'sha=[0-9a-f]+' | cut -d= -f2)"
      st="LIVE (prod $pv)"
      if [ -z "$bsha" ]; then st="UNKNOWN (prod $pv, build $n unresolved)"
      else
        for s in $(awk -F'\t' -v r="$repo" -v p="$pn" '$1==r&&$2==p{print $4}' "$tmp/rows.tsv" | sort -u); do
          git -C "$repo" merge-base --is-ancestor "$s" "$bsha" 2>/dev/null || { st="NOT-IN-PROD (prod $pv lacks ${s:0:8})"; break; }
        done
      fi
    fi ;;
  esac
  printf '%-48s %-13s %s  tickets=%s%s\n' "$pn" "[$pid]" "$st" "$tks" "${offm:+  NOT-ON-MASTER=$offm}"
done
echo "ACTION: every row not LIVE ships WITH this release -- tell the user, agree order (infra first unless the app must stop using it first), plan-review + approval per ama-terraform-backbone; NOT-ON-MASTER -> merge first."
