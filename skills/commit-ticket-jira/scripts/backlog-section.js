// List one section of the AMA Backlog ADF body, in page order (= priority order):
// rank <TAB> key <TAB> hand-written note (the entry's own text, card excluded).
// Same section lookup as backlog-splice.js (prefix match, Bugs wrapper descended).
// Env: SECTION (empty -> print the section names instead). Usage: backlog-section.js <body.json>
const fs = require("fs");
const doc = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const want = (process.env.SECTION || "").trim().toLowerCase().replace(/:$/, "");
const ownText = li => {
  const para = (li.content || []).find(c => c.type === "paragraph");
  let out = "";
  const walk = x => { if (!x) return; if (x.type === "text" && x.text) out += x.text; (x.content || []).forEach(walk); };
  walk(para);
  return out.replace(/\s+/g, " ").trim();
};
const sections = (doc.content || []).filter(n => n.type === "bulletList").flatMap(n => n.content || [])
  .filter(li => ownText(li) && (li.content || []).some(c => c.type === "bulletList"));
if (!want) { sections.forEach(li => console.log(ownText(li))); process.exit(0); }
const target = sections.find(li => ownText(li).toLowerCase().replace(/:$/, "").startsWith(want));
if (!target) { console.error(`section not found: "${want}". Sections: ` + JSON.stringify(sections.map(ownText))); process.exit(1); }
let list = target.content.find(c => c.type === "bulletList");
for (let d = 0; d < 2 && list.content.length === 1 && ownText(list.content[0]) === "" &&
  (list.content[0].content || [])[0]?.type === "bulletList"; d++) list = list.content[0].content[0];
let rank = 0;
list.content.forEach(li => {
  const m = JSON.stringify((li.content || [])[0] || {}).match(/browse\/([A-Z]+-\d+)/);
  if (!m) return;
  console.log(`${++rank}\t${m[1]}\t${ownText(li).replace(/^[\s\-:]+/, "").slice(0, 160)}`);
});
