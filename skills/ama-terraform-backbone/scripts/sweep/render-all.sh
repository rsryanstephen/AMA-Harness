#!/usr/bin/env bash
# Render every (root, Octopus project, environment) from root-project-envs.tsv into sweep/plans/<label>/ with Octopus #{tokens} substituted
# (same recipe as skills/ama-terraform-backbone/scripts/tf-plan-readonly.sh, minus init/plan -- those run in the Linux container, see plan-linux.sh).
# Source tree = the PROJ-15658-reconcile worktree (PR #22 code). Skips roots with a sensitive token the preview masks (.skip file says why).
set -u
S="${SWEEP_DIR:?set SWEEP_DIR=<work dir>}"
SRC=${BACKBONE_WORKTREE:?set BACKBONE_WORKTREE=<checkout to plan>}
P="$S/plans"; rm -rf "$P"; mkdir -p "$P"
O=https://yourorg.octopus.app/api/Spaces-1
declare -A EN=([<development>]=dev [<qa>]=qa [<staging>]=staging [<production>]=prod [Environments-25]=clientcorpdev [Environments-26]=clientcorpprod [Environments-45]=pricingprod [Environments-46]=pricingdev [Environments-47]=pricingqa [Environments-48]=adcoprod)
tail -n +2 "$S/root-project-envs.tsv" | awk -F'\t' '$2 != "-" {print $1"\t"$2"\t"$3}' | sort -u | while IFS=$'\t' read -r root proj env; do
  en=${EN[$env]:-$env}; label="$(echo "$root" | tr '/' '_')--$en"
  D="$P/$label"; mkdir -p "$D/$(dirname "$root")"
  cp -rL "$SRC/$root" "$D/$(dirname "$root")/" 2>/dev/null; cp -r "$SRC/Shared" "$D/"   # -L: dereference the modules -> ../../Shared | ../modules symlinks
  M="$D/$root"; echo "$root" > "$D/.root"; echo "$proj $env" > "$D/.octo"
  if [ -L "$M/modules" ] || [ -f "$M/modules" ]; then rm -rf "$M/modules"; cp -r "$D/Shared" "$M/modules"; fi
  # the Octopus Terraform Plan step's var file (rds.tfvars, iam.tfvars, ...) -- default variables.tfvars
  curl -sS -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" "$O/projects/$proj/deploymentprocesses" | jq -r '[.Steps[].Actions[] | select(.ActionType=="Octopus.TerraformPlan") | .Properties["Octopus.Action.Terraform.VarFiles"] // ""][0] // ""' | tr -d '\r' > "$D/.varfile"
  MAP="$D/.vars.tsv"
  curl -sS -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" "$O/variables/preview?project=$proj&environment=$env" \
   | jq -r '.Variables[] | select(.Name|test("^Octopus")|not) | "\(.Name)\t\(if .IsSensitive then "<<SENSITIVE>>" else (.Value // "") end)"' | tr -d '\r' > "$MAP"
  # Octopus.Release.Number = the release currently deployed to this env (so a task-definition "version" env var is not plan noise)
  rel=$(curl -sS -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" "$O/deployments?projects=$proj&environments=$env&take=1" | jq -r '.Items[0].ReleaseId // ""' | tr -d '\r')
  relno=""; [ -n "$rel" ] && relno=$(curl -sS -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" "$O/releases/$rel" | jq -r '.Version // ""' | tr -d '\r')
  printf 'Octopus.Release.Number\t%s\n' "${relno:-0.0.0.0}" >> "$MAP"
  # Octopus Terraform step substitutes the ROOT-level *.tf/*.tfvars(.json) files plus the step's explicit FileSubstitution list
  # (e.g. RabbitMq: content/*.json) -- never module files. Mirror that exactly.
  curl -sS -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" "$O/projects/$proj/deploymentprocesses" | jq -r '[.Steps[].Actions[] | select(.ActionType=="Octopus.TerraformPlan") | .Properties["Octopus.Action.Terraform.FileSubstitution"] // ""][0] // ""' | tr -d '\r' | sed -E 's#^content/##' > "$D/.subst"
  { find "$M" -maxdepth 1 -type f \( -name '*.tf' -o -name '*.tfvars' -o -name '*.tf.json' -o -name '*.tfvars.json' \) -print0
    while IFS= read -r pat; do [ -n "$pat" ] && find "$M" -maxdepth 1 -type f -name "$(basename "$pat")" -print0; done < "$D/.subst"
  } | while IFS= read -r -d '' f; do
    MAP="$MAP" perl -i -pe 'BEGIN{open my $h,"<",$ENV{MAP}; while(<$h>){chomp; my($k,$v)=split /\t/,$_,2; $m{$k}=$v} }
      s/#\{([^}]+)\}/exists $m{$1} ? $m{$1} : "#{$1}"/ge' "$f"
  done
  if grep -ln '<<SENSITIVE>>' "$M"/*.tf "$M"/*.tfvars 2>/dev/null | head -n 1 | grep -q .; then
    echo "needs-secret: $(grep -ho '[A-Za-z_-]* *= *"<<SENSITIVE>>"' "$M"/*.tf "$M"/*.tfvars 2>/dev/null | sed -E 's/ *=.*//' | sort -u | tr '\n' ' ')" > "$D/.skip"
  fi
  un=$(grep -ho '#{[^}]*}' "$M"/*.tf "$M"/*.tfvars 2>/dev/null | sort -u | tr '\n' ' ')
  [ -n "$un" ] && echo "unrendered: $un" > "$D/.unrendered"
  printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$root" "$proj" "$env" "$( [ -f "$D/.skip" ] && cat "$D/.skip" || echo ok)"
done | tee "$S/render-index.tsv"
echo "rendered $(ls "$P" | wc -l) labels"
