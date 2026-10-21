#!/usr/bin/env bash
# Run `terraform init` + `terraform plan -lock=false` (READ-ONLY, never apply) for every rendered label in sweep/plans/ inside the
# hashicorp/terraform:0.13.3 Linux container (worker parity; TF_PLUGIN_CACHE_DIR works on Linux, unlike Windows TF 0.13).
# Plans are tarred INTO the container (symlink-safe), logs come back to sweep/planlogs/<label>.{init,plan}.log + results.txt.
# AWS creds: ~/.aws mounted read-only. Image is alpine/busybox: POSIX sh only, N background worker loops instead of xargs -P.
# Usage: plan-linux.sh [parallelism] [label-regex]
set -u
PAR="${1:-3}"; RE="${2:-.*}"; EX="${3:-^\$}"   # 3rd arg: exclude regex (BusyBox grep -E has no lookahead)
S="${SWEEP_DIR:?set SWEEP_DIR=<work dir>}"
P="$S/plans"; L="$S/planlogs"; mkdir -p "$L"
D="$S/linux"; mkdir -p "$D"
tar -C "$P" -cf "$D/plans.tar" --exclude='.terraform' .
cat > "$D/one.sh" <<'EOF'
one() {
  label="$1"; root="$(cat /work/$label/.root)"
  if [ -f "/work/$label/.skip" ]; then echo "$label rc=SKIP $(cat /work/$label/.skip)" >> /out/results-$RUNTAG.txt; return; fi
  cd "/work/$label/$root" || { echo "$label rc=NOROOT" >> /out/results-$RUNTAG.txt; return; }
  if ! terraform init -input=false -no-color > "/out/$label.init.log" 2>&1; then echo "$label rc=INIT-FAIL $(grep -m1 -E 'Error' "/out/$label.init.log" | cut -c1-120)" >> /out/results-$RUNTAG.txt; return; fi
  vf=$(cat "/work/$label/.varfile" 2>/dev/null); [ -n "$vf" ] || vf=variables.tfvars
  varf=""; [ -f "$vf" ] && varf="-var-file=$vf"
  terraform plan -input=false -lock=false -no-color $varf > "/out/$label.plan.log" 2>&1; rc=$?
  summary=$(grep -oE '^Plan: [0-9]+ to add, [0-9]+ to change, [0-9]+ to destroy|No changes\. Infrastructure is up-to-date' "/out/$label.plan.log" | head -n 1)
  [ -z "$summary" ] && summary=$(grep -m1 -E 'Error' "/out/$label.plan.log" | cut -c1-160)
  echo "$label rc=$rc $summary" >> /out/results-$RUNTAG.txt
}
EOF
cat > "$D/run.sh" <<EOF
set -u
mkdir -p /work && cd /work && tar -xf /in/plans.tar
export TF_PLUGIN_CACHE_DIR=/cache TF_IN_AUTOMATION=1 CHECKPOINT_DISABLE=1 AWS_SDK_LOAD_CONFIG=1
. /in/one.sh
: > /out/results-$RUNTAG.txt
ls /work | grep -E '^($RE)\$' | grep -vE '$EX' > /work/.labels
n=\$(wc -l < /work/.labels); echo "labels=\$n par=$PAR" >> /out/results-$RUNTAG.txt
# pre-warm the provider cache serially (parallel first-inits race on the same file: "text file busy")
first=\$(head -n 1 /work/.labels); ( cd "/work/\$first/\$(cat /work/\$first/.root)" && terraform init -input=false -no-color > /out/prewarm.init.log 2>&1 )
i=0
while [ \$i -lt $PAR ]; do
  ( awk -v k=\$i -v p=$PAR 'NR % p == k' /work/.labels | while read -r l; do one "\$l"; done ) &
  i=\$((i+1))
done
wait
echo DONE >> /out/results-$RUNTAG.txt
EOF
docker volume create tfsweepcache > /dev/null
IMAGE="${IMAGE:-hashicorp/terraform:0.13.3}"   # IMAGE=hashicorp/terraform:1.16.5 for the roots that pin required_version 1.16.5
RUNTAG="${RUNTAG:-$(date +%m%d%H%M)}"
MSYS_NO_PATHCONV=1 docker run --rm -e RUNTAG="$RUNTAG" -v "$(cygpath -w "$D"):/in" -v "$(cygpath -w "$L"):/out" -v "$(cygpath -w "$HOME/.aws"):/root/.aws:ro" -v tfsweepcache:/cache --entrypoint sh "$IMAGE" /in/run.sh
echo "container exit $? runtag=$RUNTAG"; tail -n 3 "$L/results-$RUNTAG.txt"
