# AWS-vs-Terraform sweep (PROJ-15658, 2026-10-14)

Read-only. `SWEEP_DIR` = empty work dir; `BACKBONE_WORKTREE` = the yourproduct-backbone checkout to plan. Order:

1. `list-states.sh` -> `sweep-buckets.txt`, `sweep-states.txt` (every *.tfstate in every bucket named *terraform*)
2. `python -I state_index.py` -> `state-index.tsv` (ids/arns only; each state parsed from a temp path and deleted at once -- states hold secrets)
3. AWS inventory -> `aws/<group>.json` (schema in the Workflow prompt of session 7c2235b9: service,type,id,arn,name,tags,extra). The agents' own
   collect scripts were per-session; regenerate with a workflow or the AWS CLI.
4. `python -I join.py` -> `tracked.tsv` / `untracked.tsv` / `stale.tsv`; `python -I untracked-report.py` -> `untracked-report.txt` (noise types dropped)
5. `root-project-envs.sh` (hand map root->Octopus project inside) -> `root-project-envs.tsv`; `render-all.sh` -> `plans/<root>--<env>/`
   (Octopus tokens rendered exactly like the step: root-level *.tf/*.tfvars(.json) + the step's FileSubstitution list; `Octopus.Release.Number`
   = the release currently deployed to that env; var file from the step)
6. `plan-linux.sh <par> [label-regex] [exclude-regex]` -- hashicorp/terraform:0.13.3 container, plugin cache volume, N worker loops,
   `-lock=false`; `IMAGE=hashicorp/terraform:1.16.5` for roots pinned to it; `RUNTAG` names `planlogs/results-<tag>.txt`
7. `python -I classify.py` -> `drift.tsv` (no-change | tags-only | update:<attrs> | create | destroy | replace | error | init-error)
8. `scrub-and-clean.sh` -- redact secret-named Octopus values from the logs, delete plans/ + tar. ALWAYS run it; scratch is not wiped.
Outputs are a SNAPSHOT of the inventory date: re-read any live value (cert expiry, in-use count) with the AWS CLI before reporting it --
2026-10-21 a 10-14 inventory reported `*.<tenant domain>` expiring 11-06; ACM re-import on 10-19 had already moved it to 2027-01-05.
Traps met: jq -r is CRLF here (tr -d '\r' AFTER jq); BusyBox grep -E has no lookahead; parallel first inits race on the provider cache
("text file busy") -> prewarm; `modules` symlinks need `cp -rL`; two roots pin TF 1.16.5; roots with no Octopus project break build.sh.
