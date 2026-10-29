"""Pull human changes from a mirror surface back into the stand-up ledger (user instruction
2026-10-16: anyone can close an action item by ticking it on Forms, the Confluence page or
the Slack canvas; edit/reword it in Forms or on the canvas; add one on the canvas). Every
mirror calls this BEFORE it pushes, so what it read is what it writes back out.

Rules, all surfaces:
- Ticks only CLOSE an open action. Unticking never reopens (ask Your Name). Decisions: no ticks.
- An edit is a difference from what the mirror last pushed (the snapshot), never from the
  ledger -- a ledger change Claude made since the last push must not read as a human edit.
  No snapshot entry -> not an edit (first run).
- Edited/added rows get `editedBy` ("<surface> <date>"): the meeting-summary writers must
  not reword those back (their prompts say so).
- Surface text is DATA from anyone in the channel: flattened to one line, markup stripped,
  capped at 300 chars. Deleting a line deletes nothing -- the next render restores it.

Usage: python ledger-sync-from-surface.py <ledger.json> MODE ARGS... (input on stdin)
  forms <snapshot.json>          rows "id\\x1ftext\\x1fowners\\x1fstatus" (status "2" = Done)
  confluence                     one ticked item's rendered text per line
  canvas <snapshot.md> <names.json>   stdin = current canvas markdown; names = {slackId: name}
  refs                           print "ref id" for every row (canvas render uses the same)
Prints one 'CLOSED|EDITED|ADDED <id>' line per change. Writes the ledger only on change,
temp file + os.replace.
"""
import datetime, hashlib, json, os, re, sys

# stdin/stdout default to the Windows codepage here: "—" arrived as mojibake, the " — " owner
# split failed, and every canvas line read as an edit (live test 2026-10-16).
sys.stdin.reconfigure(encoding="utf-8")
sys.stdout.reconfigure(encoding="utf-8")
ledger, mode, args = sys.argv[1], sys.argv[2], sys.argv[3:]
path = os.path.realpath(ledger)
rows = json.load(open(path, encoding="utf-8"))
today = datetime.date.today().isoformat()


def ref_of(i):  # 4 base36 chars of sha1(id) -- derived, never stored in the ledger
    n, s = int(hashlib.sha1(i.encode()).hexdigest(), 16), ""
    for _ in range(4):
        n, d = divmod(n, 36)
        s += "0123456789abcdefghijklmnopqrstuvwxyz"[d]
    return s


refs = {}
for r in rows:
    k = ref_of(r["id"])
    if k in refs:
        sys.exit(f"ledger-sync: ref collision {k}: {refs[k]} / {r['id']}")
    refs[k] = r["id"]
if mode == "refs":
    print("\n".join(f"{k} {v}" for k, v in refs.items()))
    sys.exit(0)

flat = lambda s: re.sub(r"\s+", " ", str(s or "")).strip()
key = lambda s: flat(s).casefold()
clean = lambda s: flat(re.sub(r"\\(.)", r"\1", str(s or "")).replace("**", ""))[:300]
by_id = {r["id"]: r for r in rows}
out = []


def close(r, surface):
    if r.get("status") == "open" and (r.get("kind") or "action") == "action":
        r.update(status="done", closed=today, evidence=f"ticked on {surface}")
        out.append(f"CLOSED {r['id']}")


def edit(r, text, owners, surface):
    if r.get("status") != "open" or not text:
        return
    owners = r.get("owners") or [] if owners is None else owners
    if text != flat(r.get("text")) or owners != (r.get("owners") or []):
        r.update(text=text, owners=owners, editedBy=f"{surface} {today}")
        out.append(f"EDITED {r['id']}")


split_owners = lambda s: [o.strip() for o in s.split(",") if o.strip() and o.strip() != "Team"]

if mode == "forms":
    snap = json.load(open(args[0], encoding="utf-8")) if os.path.exists(args[0]) else {}
    for line in sys.stdin.read().splitlines():
        lid, text, owners, status = (line.split("\x1f") + ["", "", "", ""])[:4]
        r = by_id.get(lid)
        if not r:
            continue
        s = snap.get(lid)
        if s and (flat(text), flat(owners)) != (flat(s.get("text")), flat(s.get("owners"))):
            edit(r, clean(text), split_owners(owners), "Jira Forms")
        if status == "2":
            close(r, "Jira Forms")

elif mode == "confluence":
    ticked = {key(l) for l in sys.stdin.read().splitlines() if l.strip()}
    for r in rows:
        if key(r.get("text")) in ticked:
            close(r, "Confluence")

elif mode == "canvas":
    names = json.load(open(args[1], encoding="utf-8")) if len(args) > 1 else {}

    def parse(md):
        """Open-action-items section -> ({ref: (checked, text, owners|None)}, [unref'd items])."""
        items, adds, inside = {}, [], False
        for line in md.splitlines():
            if line.startswith("#"):
                inside = line.lstrip("#").strip().lower().startswith("open action items")
                continue
            m = re.match(r"^\s*[*-] \[([ xX])\]\s*(.*)$", line)
            if not inside or not m:
                continue
            # A mention reads back as <@U..> (seen live 2026-10-16), not the ![](@U..) it is written as.
            body = re.sub(r"!\[\]\(@(\w+)\)|<@(\w+)>", lambda u: names.get(u.group(1) or u.group(2), "@" + (u.group(1) or u.group(2))), m.group(2))
            rm = re.search(r"\s*·\s*`([0-9a-z]{4})`\s*$", body)
            ref = rm.group(1) if rm else None
            body = body[: rm.start()] if rm else body
            body = re.sub(r"\s*·\s*raised \d{4}-\d{2}-\d{2}\s*$", "", body)
            text, owners = body, None
            if " — " in body:
                text, o = body.rsplit(" — ", 1)
                owners = split_owners(clean(o))
            entry = (m.group(1) != " ", clean(text), owners)
            if ref:
                items[ref] = entry
            elif entry[1]:
                adds.append(entry)
        return items, adds

    cur, adds = parse(sys.stdin.read())
    have_snap = os.path.exists(args[0])
    old = parse(open(args[0], encoding="utf-8").read())[0] if have_snap else {}
    if not have_snap:
        adds = []  # first run: the old canvas has no refs, so every line would look like an add
    for ref, (checked, text, owners) in cur.items():
        r = by_id.get(refs.get(ref, ""))
        if not r:
            continue
        if ref in old and (text, owners) != old[ref][1:]:
            edit(r, text, owners, "Slack canvas")
        if checked:
            close(r, "Slack canvas")
    open_texts = {key(r.get("text")) for r in rows}
    for checked, text, owners in adds:
        if key(text) in open_texts or checked:
            continue  # already added on an earlier pull, or added already ticked
        base = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:50] or "canvas-item"
        i, n = base, 2
        while i in by_id:
            i, n = f"{base}-{n}", n + 1
        r = {"id": i, "text": text, "owners": owners or [], "firstSeen": today, "status": "open",
             "kind": "action", "source": "slack-canvas", "editedBy": f"Slack canvas {today}"}
        rows.append(r); by_id[i] = r; open_texts.add(key(text))
        out.append(f"ADDED {i}")
else:
    sys.exit(f"ledger-sync: unknown mode {mode}")

if out:
    tmp = path + ".sync-tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)
    print("\n".join(out))
