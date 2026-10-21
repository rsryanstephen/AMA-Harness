#!/usr/bin/env bash
# READ-ONLY plan for any yourproduct-backbone root with the Octopus variables rendered (PROJ-15658).
# Env: TFBIN=<terraform 0.13.3 exe> for worker parity; TF_DATA_DIR=C:/tfd/<label> on Windows (path length);
#      SRCDIR=<worktree> to plan uncommitted code instead of origin/master; TF_PLAN_SCRATCH, BACKBONE_REPO.
# Exports origin/master <module> + Shared, renders every #{token} in *.tf/*.tfvars from the
# Octopus variables/preview for <project>/<environment> (the same values a deploy would get),
# then `terraform plan -lock=false` -- never apply, never takes the state lock.
# Usage: tf-plan-gen.sh <module-path> <Projects-N> <Environments-N> <label> [token=value ...]
#   extra token=value pairs override/fill tokens (e.g. sensitive ones the preview masks)
set -u
mod="$1"; proj="$2"; env="$3"; label="$4"; shift 4
SP="${TF_PLAN_SCRATCH:-$HOME/.claude/scratch/terraform}"; mkdir -p "$SP"
W="$SP/tfgen-$label"; LOG="$SP/tfgen-$label.log"
B="${BACKBONE_REPO:-$HOME/Repos/AMA_APP/yourproduct-backbone}"
rm -rf "$W"; mkdir -p "$W"
if [ -n "${SRCDIR:-}" ]; then mkdir -p "$W/$(dirname "$mod")"; cp -r "$SRCDIR/$mod" "$W/$(dirname "$mod")/"; cp -r "$SRCDIR/Shared" "$W/"; else git -C "$B" archive origin/master "$mod" Shared | tar -x -C "$W"; fi
M="$W/$mod"
if [ -L "$M/modules" ] || [ -f "$M/modules" ]; then rm -rf "$M/modules"; cp -r "$W/Shared" "$M/modules"; fi
MAP="$W/.vars.tsv"
O=https://yourorg.octopus.app/api/Spaces-1
curl -sS -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" "$O/variables/preview?project=$proj&environment=$env" \
 | jq -r '.Variables[] | select(.Name|test("^Octopus")|not) | "\(.Name)\t\(if .IsSensitive then "<<SENSITIVE>>" else (.Value // "") end)"' \
 | tr -d '\r' > "$MAP"
for kv in "$@"; do printf '%s\t%s\n' "${kv%%=*}" "${kv#*=}" >> "$MAP"; done   # later lines win
find "$M" -maxdepth 1 \( -name '*.tf' -o -name '*.tfvars' \) -print0 | while IFS= read -r -d '' f; do
  MAP="$MAP" perl -i -pe 'BEGIN{open my $h,"<",$ENV{MAP}; while(<$h>){chomp; my($k,$v)=split /\t/,$_,2; $m{$k}=$v} }
    s/#\{([^}]+)\}/exists $m{$1} ? $m{$1} : "#{$1}"/ge' "$f"
done
if grep -n '#{' "$M"/*.tf "$M"/*.tfvars 2>/dev/null | grep -v '^\s*#'; then echo "WARN unrendered placeholder(s) above -- left literal, as Octostache does"; fi
if grep -ln '<<SENSITIVE>>' "$M"/*.tf "$M"/*.tfvars 2>/dev/null; then echo "sensitive value needed in the file(s) above -- pass token=value"; exit 1; fi
grep -h -E 'key|bucket' "$M/terraform.tf" | grep -v '#' | sed 's/^ */  /'
cd "$M"; terraform() { if [ -n "${TFBIN:-}" ]; then "$TFBIN" "$@"; else command terraform "$@"; fi; }
terraform init -input=false -no-color > "$LOG.init" 2>&1 || { tail -25 "$LOG.init"; exit 1; }
varf=""; [ -f variables.tfvars ] && varf="-var-file=variables.tfvars"
terraform plan -input=false -lock=false -no-color $varf > "$LOG" 2>&1; rc=$?
echo "plan rc=$rc"
grep -E '^Plan:|No changes|^  # |^Error|^│ Error' "$LOG" | head -60
