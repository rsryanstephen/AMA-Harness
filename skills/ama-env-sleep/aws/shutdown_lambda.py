# PROJ-15653: nightly QA/Staging shutdown. Invoked by EventBridge Scheduler at 22:00
# SAST (schedule ama-qa-staging-nightly-shutdown). Scales every ECS service in the listed
# clusters to desired count 0. Deployed by ../scripts/deploy-shutdown-schedule.sh -- edit
# here, re-run that script. Startup is NOT here: the harness PC task does that
# (../scripts/morning-wake.sh), see ../SKILL.md.
import os
import boto3

ecs = boto3.client("ecs")
CLUSTERS = os.environ.get("CLUSTERS", "qa-v1-AMA,staging-v1-AMA").split(",")


def handler(event, context):
    event = event or {}
    clusters = event.get("clusters") or CLUSTERS
    dry = bool(event.get("dryRun"))  # list/describe only -- proves IAM + targeting safely
    scaled, failed = [], []
    for cluster in clusters:
        arns = []
        for page in ecs.get_paginator("list_services").paginate(cluster=cluster):
            arns += page["serviceArns"]
        for i in range(0, len(arns), 10):
            for svc in ecs.describe_services(cluster=cluster, services=arns[i:i + 10])["services"]:
                if svc["desiredCount"] == 0:
                    continue
                if dry:
                    scaled.append(svc["serviceName"])
                    continue
                try:
                    ecs.update_service(cluster=cluster, service=svc["serviceArn"], desiredCount=0)
                    scaled.append(svc["serviceName"])
                except Exception as e:  # keep going; one bad service must not leave the rest up
                    failed.append(f"{svc['serviceName']}: {e}")
    print({"dryRun": dry, "scaled": scaled, "failed": failed})
    if failed:
        raise RuntimeError(f"{len(failed)} service(s) not scaled: {failed}")
    return {"dryRun": dry, "scaled": scaled}
