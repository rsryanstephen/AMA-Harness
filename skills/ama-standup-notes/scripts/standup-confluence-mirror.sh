#!/usr/bin/env bash
# Mirrors the stand-up ledger onto ONE Confluence page (user instruction 2026-10-07: action
# items on a single URL nobody needs an issue number for). Runs ALONGSIDE
# standup-forms-mirror.sh, not instead of it -- the user asked to maintain both.
#
# MIRROR, not replacement. `~/.claude/harness-state/standup/.standup-action-items.json`
# stays the working store -- firstSeen ageing, close-with-evidence, restated-item-updates
# and .standup-dismissed.json all keep working against it. This renders a visible copy.
#
# Whole-body regenerate every run: closed, dismissed and deleted rows come out right with no
# diff logic. PUT skipped when the rendered body hash is unchanged -- three runners call this
# (morning standup, 12:00 pull, Monday team notes) and each PUT is a page version + watcher mail.
# No "open N days" column for the same reason: it would change the body every day.
#
# NEVER render `sourceDoc` -- Zoom doc ids are access credentials and the page is shared.
#
# Usage: standup-confluence-mirror.sh [--dry-run|--pull]   (dry-run prints the XHTML, writes nothing;
#   --pull reads ticks into the ledger only)
# Exit 1 on any API failure. Callers DEGRADE on that, never abort the run.
set -uo pipefail

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

. "$HOME/.claude/hooks/lib-harness-repos.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"
HOST="$(hr_config_required '.atlassian.cloudId')" || exit 1
PAGE="$(hr_config_required '.atlassian.standupActionItemsPageId')" || exit 1

LEDGER="$HOME/.claude/harness-state/standup/.standup-action-items.json"
[ -f "$LEDGER" ] || { echo "standup-confluence-mirror.sh: no ledger at $LEDGER" >&2; exit 1; }
HASHF="$(hstate standup .action-items-page-hash)"

FORMS="$(hr_config_required '.atlassian.standupTrackingIssueKey')" || exit 1

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
BODY="$TMPD/body.xhtml"

# --- pull: a task someone ticked on the page closes its ledger row (user instruction
# 2026-10-16) before the render below would put it back unticked. Text edits on the page are
# NOT read -- the info macro says so; rewording goes through the canvas or Forms.
meta="$(bash "$HOME/.claude/skills/ama-confluence-api/scripts/confluence-get-page.sh" "$PAGE" "$TMPD/cur.xhtml" storage)" \
  || { echo "standup-confluence-mirror.sh: page read failed, not pushing over unread ticks" >&2; exit 1; }
curver="$(printf '%s' "$meta" | cut -f2 | tr -d '\r')"
if [ "$DRY" -eq 0 ]; then
  PYTHONIOENCODING=utf-8 python - "$TMPD/cur.xhtml" <<'EOF' | python "$(dirname "$0")/ledger-sync-from-surface.py" "$LEDGER" confluence
import html, re, sys
s = open(sys.argv[1], encoding="utf-8").read()
for t in re.findall(r"<ac:task>(.*?)</ac:task>", s, re.S):
    if re.search(r"<ac:task-status>\s*complete\s*</ac:task-status>", t):
        b = re.search(r"<ac:task-body>(.*?)</ac:task-body>", t, re.S)
        text = html.unescape(re.sub(r"<[^>]+>", "", b.group(1) if b else "")).rsplit(" — ", 1)[0]
        print(re.sub(r"\s+", " ", text).strip())
EOF
fi
[ "${1:-}" = "--pull" ] && exit 0  # noon wrapper: every surface pulled before any is pushed

PYTHONIOENCODING=utf-8 python - "$LEDGER" "$BODY" "$HOST" "$FORMS" <<'EOF' || { echo "standup-confluence-mirror.sh: render failed" >&2; exit 1; }
import json, sys, html, datetime
ledger, out, host, forms = sys.argv[1:5]
rows = json.load(open(ledger, encoding="utf-8"))
e = lambda s: html.escape(str(s or "").replace("\r", " ").replace("\n", " "), quote=True)
today = datetime.date.today()
cutoff = (today - datetime.timedelta(days=14)).isoformat()

def kind(r): return r.get("kind") or "action"
def table(headers, body_rows):
    h = "".join(f"<th><p><strong>{e(x)}</strong></p></th>" for x in headers)
    b = "".join("<tr>" + "".join(f"<td><p>{e(c)}</p></td>" for c in r) + "</tr>" for r in body_rows)
    return f"<table><tbody><tr>{h}</tr>{b}</tbody></table>"

open_rows = sorted([r for r in rows if r.get("status") == "open"],
                   key=lambda r: (r.get("firstSeen") or "", r.get("id")), reverse=True)
actions = [r for r in open_rows if kind(r) == "action"]
decisions = [r for r in open_rows if kind(r) == "decision"]
closed = sorted([r for r in rows if r.get("status") != "open" and (r.get("closed") or "") >= cutoff],
                key=lambda r: (r.get("closed") or "", r.get("id")), reverse=True)

parts = [
  '<ac:structured-macro ac:name="info"><ac:rich-text-body><p>Maintained automatically by Claude '
  'from meeting summaries, DMs and email, and kept in sync with the Slack canvas in #<amaSupportChannelName> and '
  f'the <a href="https://{host}/browse/{forms}">Jira Forms on {forms}</a> at the morning and 12:00 SAST runs.'
  'Anyone can close an action item by ticking it here, on the canvas or in the Forms. Reword an item on '
  'the canvas or in the Forms; add one on the canvas. Text edits on this page are overwritten. Unticking does '
  'not reopen an item and deleting a line does not remove it; ask Your Name.</p></ac:rich-text-body></ac:structured-macro>',
  f"<h2>Open action items ({len(actions)})</h2>",
  # Task list, not a table: a tick here is a real Confluence task status the next run reads.
  "<ac:task-list>" + "".join(
      f"<ac:task><ac:task-id>{n}</ac:task-id><ac:task-status>incomplete</ac:task-status><ac:task-body>"
      f"{e(r.get('text'))} — <strong>{e(', '.join(r.get('owners') or []) or 'Team')}</strong> · raised {e(r.get('firstSeen'))}"
      "</ac:task-body></ac:task>" for n, r in enumerate(actions, 1)) + "</ac:task-list>"
        if actions else "<p>None open.</p>",
  f"<h2>Open decisions ({len(decisions)})</h2>",
  table(["Decision", "First raised"], [[r.get("text"), r.get("firstSeen")] for r in decisions])
        if decisions else "<p>None open.</p>",
  f"<h2>Closed in the last 14 days ({len(closed)})</h2>",
  table(["Item", "Closed", "How we know"],
        [[r.get("text"), r.get("closed"), r.get("evidence")] for r in closed])
        if closed else "<p>Nothing closed in the last 14 days.</p>",
]
open(out, "w", encoding="utf-8").write("".join(parts))
print(f"{len(actions)} open actions, {len(decisions)} open decisions, {len(closed)} closed (14d)")
EOF

if [ "$DRY" -eq 1 ]; then cat "$BODY"; echo; exit 0; fi

# Skip only when the body is unchanged AND nobody has saved the page since our last write
# (stored "<hash> <version>") -- else a tick on a decision row, or a stray edit, would sit
# there until the ledger next changed.
new="$(sha1sum "$BODY" | cut -d' ' -f1)"
if [ -f "$HASHF" ] && [ "$(cat "$HASHF")" = "$new $curver" ]; then
  echo "standup-confluence-mirror.sh: unchanged, skipped -> https://${HOST}/wiki/pages/viewpage.action?pageId=${PAGE}"
  exit 0
fi
bash "$HOME/.claude/skills/ama-confluence-api/scripts/confluence-update-page.sh" \
  "$PAGE" "$BODY" "action items synced from the stand-up ledger" storage >/dev/null || exit 1
newver="$(bash "$HOME/.claude/skills/ama-confluence-api/scripts/confluence-get-page.sh" "$PAGE" "$TMPD/after.xhtml" storage | cut -f2 | tr -d '\r')"
printf '%s %s\n' "$new" "$newver" > "$HASHF"
echo "standup-confluence-mirror.sh: page updated -> https://${HOST}/wiki/pages/viewpage.action?pageId=${PAGE}"
