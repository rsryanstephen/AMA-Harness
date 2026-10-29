#!/usr/bin/env python
"""Meaningful 'no Terraform' report from untracked.tsv: skip noise types (task-definition revisions, historical EMR clusters,
volumes/snapshots/AMIs, default parameter/option groups, backup points, workbench objects, ENIs) and group the rest by type.
Also flags env prefix (qa-/staging-/production-/development-/hs-) and the mnd-* / Name tags so a reader can place each item.
Output: sweep/untracked-report.txt"""
import csv, json, os, re, collections
S = os.path.dirname(os.path.abspath(__file__))
NOISE = {"aws_ecs_task_definition", "arn:ecs:task-definition", "arn:elasticmapreduce:cluster", "arn:elasticmapreduce:editor",
         "arn:ec2:volume", "aws_ebs_volume", "arn:ec2:snapshot", "aws_ami", "arn:ec2:image", "arn:rds:snapshot", "arn:rds:og",
         "arn:backup:recovery-point", "arn:sqlworkbench:connection", "arn:sqlworkbench:notebook", "arn:ec2:network-interface",
         "aws_lambda_layer_version", "arn:lambda:layer", "aws_launch_configuration", "aws_launch_template", "arn:ec2:launch-template",
         "aws_key_pair", "arn:ec2:key-pair", "arn:logs:log-group", "aws_cloudwatch_log_group", "arn:ecs:container-instance",
         "arn:ecs:task", "arn:ssm:managed-instance", "arn:ec2:spot-instances-request", "arn:ec2:reserved-instances",
         "arn:elasticache:parametergroup", "aws_redshift_parameter_group", "arn:redshift:parametergroup", "aws_db_option_group"}
rows = list(csv.DictReader(open(os.path.join(S, "untracked.tsv"), encoding="utf-8", newline=""), delimiter="\t"))
# the tagging group's arn:* rows duplicate service-group rows; drop a tagging row whose ARN a service group already listed
# (tracked or not), and drop arn:* types whose service a service group covers at all
allinv = []
for f in os.listdir(os.path.join(S, "aws")):
    if f.endswith(".json") and f != "tagging.json":
        try: allinv += json.load(open(os.path.join(S, "aws", f), encoding="utf-8"))
        except Exception: pass
svc_arns = {x.get("arn") for x in allinv if x.get("arn")} | {x.get("id") for x in allinv if str(x.get("id", "")).startswith("arn:")}
svc_covered = {"ec2", "ecs", "rds", "iam", "lambda", "sqs", "sns", "kms", "s3", "ecr", "logs", "cloudwatch", "elasticloadbalancing",
               "cloudfront", "route53", "acm", "secretsmanager", "ssm", "dynamodb", "elasticache", "es", "redshift", "states", "events",
               "scheduler", "cognito-idp", "cognito-identity", "wafv2", "efs", "elasticfilesystem", "transfer", "servicediscovery", "kinesis", "glue", "apigateway", "backup", "cloudtrail"}
by = collections.defaultdict(list)
for r in rows:
    t = r["type"]
    if t in NOISE: continue
    if r["group"] == "tagging":
        if r["id"] in svc_arns: continue
        if t.split(":")[1] in svc_covered: continue
    if t == "aws_db_parameter_group" and r["id"].startswith("default."): continue
    if t == "arn:rds:pg" and ":default." in r["id"]: continue
    # the tagging group duplicates service-group items by ARN; keep ARN-only (arn:*) types only when no service group covers that service
    by[t].append(r)
def env_of(name):
    m = re.match(r"(qa|staging|production|prod|development|dev|hs-(qa|staging|production|development|dev))[-_]", name or "")
    return m.group(1) if m else "-"
out = open(os.path.join(S, "untracked-report.txt"), "w", encoding="utf-8")
out.write("type\tcount\n")
for t, items in sorted(by.items(), key=lambda kv: -len(kv[1])): out.write(f"{t}\t{len(items)}\n")
out.write("\n")
for t, items in sorted(by.items(), key=lambda kv: -len(kv[1])):
    out.write(f"\n### {t} ({len(items)})\n")
    for r in sorted(items, key=lambda r: (env_of(r['name'] or r['id']), r['name'] or r['id'])):
        tags = json.loads(r["tags"] or "{}"); extra = json.loads(r["extra"] or "{}")
        mnd = {k: v for k, v in tags.items() if k.startswith("mnd")}
        tagstr = ("mnd" if mnd else "") + ("" if not tags.get("Name") else f" Name={tags['Name']}")
        ex = ", ".join(f"{k}={v}" for k, v in list(extra.items())[:4] if isinstance(v, (str, int, bool)))[:100]
        out.write(f"  [{env_of(r['name'] or r['id'])}] {r['name'] or r['id']}\t{tagstr}\t{ex}\n")
out.close()
print(open(os.path.join(S, "untracked-report.txt"), encoding="utf-8").read()[:4000])
