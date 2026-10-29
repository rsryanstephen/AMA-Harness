"""Pull the LAST slack_read_canvas result out of a `claude -p --output-format stream-json
--verbose` transcript, so the canvas mirror reads the canvas byte-exact instead of asking a
model to echo ~12 KB back (a copy slip would read as a human edit and land in the ledger).

Usage: python canvas-stream-extract.py <stream.jsonl> <out.md> <out-sections.json>
Writes markdown_content and section_id_mapping (ordered, title first). Exit 1 if no
read_canvas result is in the stream.
"""
import json, sys

stream, out_md, out_map = sys.argv[1:4]
read_ids, last = set(), None
for line in open(stream, encoding="utf-8", errors="replace"):
    try:
        o = json.loads(line)
    except ValueError:
        continue
    for c in (o.get("message") or {}).get("content") or []:
        if not isinstance(c, dict):
            continue
        if c.get("type") == "tool_use" and c.get("name", "").endswith("slack_read_canvas"):
            read_ids.add(c.get("id"))
        elif c.get("type") == "tool_result" and c.get("tool_use_id") in read_ids:
            body = c.get("content")
            text = body if isinstance(body, str) else "".join(x.get("text", "") for x in body or [])
            try:
                d = json.loads(text)
            except ValueError:
                continue
            if "markdown_content" in d:
                last = d
if last is None:
    sys.exit("canvas-stream-extract: no slack_read_canvas result in the stream")
open(out_md, "w", encoding="utf-8").write(last["markdown_content"])
json.dump(list((last.get("section_id_mapping") or {}).keys()), open(out_map, "w", encoding="utf-8"))
print(f"{len(last['markdown_content'])} chars, {len(last.get('section_id_mapping') or {})} sections")
