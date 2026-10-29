// Rewrite the "Epics" index section of the AMA Backlog ADF body: one entry per epic in
// DESIRED (comma list). Created just above "Features" in the page's first list when absent.
// Entries already there keep their place and note; missing ones are appended; ones not in
// DESIRED are dropped. A desired key already listed ELSEWHERE on the page is skipped and
// reported (a duplicate key breaks prune/demote) -- move it with backlog-move-first.sh --section Epics.
// Env: DESIRED, HOSTNAME_CFG. Usage: backlog-epics.js <in.json> <out.json>
const fs = require("fs");
const [, , inPath, outPath] = process.argv;
const doc = JSON.parse(fs.readFileSync(inPath, "utf8"));
const host = process.env.HOSTNAME_CFG || "yourorg.atlassian.net";
const desired = (process.env.DESIRED || "").split(",").map(s => s.trim()).filter(Boolean);
const ownText = li => {
  const p = (li.content || []).find(c => c.type === "paragraph");
  let o = "";
  const w = x => { if (!x) return; if (x.type === "text" && x.text) o += x.text; (x.content || []).forEach(w); };
  w(p);
  return o.replace(/\s+/g, " ").trim();
};
const keyOf = li => (JSON.stringify((li.content || [])[0] || {}).match(/browse\/([A-Z]+-\d+)/) || [])[1];
const card = k => ({ type: "listItem", content: [{ type: "paragraph", content: [{ type: "inlineCard", attrs: { url: `https://${host}/browse/${k}` } }] }] });

let sec = null, featHost = null, featIdx = -1;
(doc.content || []).forEach(n => {
  if (n.type !== "bulletList") return;
  (n.content || []).forEach((li, j) => {
    const t = ownText(li).toLowerCase();
    if (!sec && t.startsWith("epics")) sec = li;
    if (!featHost && t.startsWith("features")) { featHost = n; featIdx = j; }
  });
});
let created = false;
if (!sec) {
  if (!featHost) { console.error("no Features section to anchor the Epics index above"); process.exit(1); }
  sec = { type: "listItem", content: [
    { type: "paragraph", content: [{ type: "text", text: "Epics", marks: [{ type: "strong" }] },
      { type: "text", text: " (tickets inside an epic are not listed separately -- open the epic for them)" }] },
    { type: "bulletList", content: [] }] };
  featHost.content.splice(featIdx, 0, sec);
  created = true;
}
const list = sec.content.find(c => c.type === "bulletList");
const placeholder = li => !keyOf(li);
const secJson = JSON.stringify(sec);
const outside = JSON.stringify(doc.content).replace(secJson, "");
const elsewhere = desired.filter(k => new RegExp(`browse/${k}["?]`).test(outside));
const keep = list.content.filter(li => !placeholder(li) && desired.includes(keyOf(li)));
const removed = list.content.filter(li => !placeholder(li) && !desired.includes(keyOf(li))).map(keyOf);
const have = new Set(keep.map(keyOf));
const added = desired.filter(k => !have.has(k) && !elsewhere.includes(k));
list.content = [...keep, ...added.map(card)];
if (list.content.length === 0) list.content = [{ type: "listItem", content: [{ type: "paragraph", content: [{ type: "text", text: "(none)" }] }] }];
fs.writeFileSync(outPath, JSON.stringify(doc));
console.log(JSON.stringify({ created, added, removed, elsewhere, total: keep.length + added.length }));
