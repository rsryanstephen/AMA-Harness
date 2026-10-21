// Splice one ticket listItem into a named section of the AMA Backlog ADF body.
//
// Sections are top-level listItems whose OWN paragraph text is the section name, each
// holding a nested bulletList of ticket listItems. They are not headings, and the page is
// several sibling bulletLists -- so the section is found by text, never by a fixed index
// ("the Nth bulletList on the page" is confirmed wrong).
//
// Env: KEY (required), SECTION (default Bugs), POSITION (last|first), HOSTNAME_CFG
// Usage: backlog-splice.js <in-body.json> <out-body.json>
const fs = require("fs");

const [, , inPath, outPath] = process.argv;
const key = process.env.KEY;
const section = (process.env.SECTION || "Bugs").trim();
const position = (process.env.POSITION || "last").trim();
const host = process.env.HOSTNAME_CFG || "yourorg.atlassian.net";
if (!inPath || !outPath || !key) {
  console.error("usage: KEY=... backlog-splice.js <in-body.json> <out-body.json>");
  process.exit(64);
}

const doc = JSON.parse(fs.readFileSync(inPath, "utf8"));

const ownText = li => {
  const para = (li.content || []).find(c => c.type === "paragraph");
  if (!para) return "";
  let out = "";
  const walk = x => {
    if (!x) return;
    if (x.type === "text" && x.text) out += x.text;
    (x.content || []).forEach(walk);
  };
  walk(para);
  return out.replace(/\s+/g, " ").trim();
};

// Find the section listItem across every top-level bulletList; match by prefix because
// some section names carry a trailing colon and some do not.
const want = section.toLowerCase().replace(/:$/, "");
let target = null;
(doc.content || []).forEach((node, i) => {
  if (node.type !== "bulletList") return;
  (node.content || []).forEach((li, j) => {
    const t = ownText(li).toLowerCase().replace(/:$/, "");
    if (target || !t.startsWith(want)) return;
    const nestedIdx = (li.content || []).findIndex(c => c.type === "bulletList");
    if (nestedIdx === -1) return;
    target = { li, nestedIdx, path: `.content[${i}].content[${j}].content[${nestedIdx}]`, label: ownText(li) };
  });
});

if (!target) {
  console.error(`section not found: "${section}". Sections seen: ` + JSON.stringify(
    (doc.content || []).filter(n => n.type === "bulletList")
      .flatMap(n => (n.content || []).map(ownText)).filter(Boolean)));
  process.exit(1);
}

// Descend a wrapper listItem. `Bugs` nests one level deeper than every other section:
// its own bulletList holds a SINGLE empty-text listItem whose only child is another
// bulletList, and the 36 bug tickets live in that inner list. Appending to the outer list
// makes the new entry a sibling of the wrapper -- wrong depth, and the +1 key-delta guard
// in backlog-add-ticket.sh passes either way, so it fails silently. Confirmed live
// 2026-09-04 (v131).
let list = target.li.content[target.nestedIdx];
let descended = 0;
while (
  (list.content || []).length === 1 &&
  ownText(list.content[0]) === "" &&
  (list.content[0].content || []).length === 1 &&
  list.content[0].content[0].type === "bulletList"
) {
  list = list.content[0].content[0];
  descended++;
  if (descended > 2) {
    console.error(`refusing to descend past ${descended} wrapper levels in "${target.label}" -- structure changed, check the page`);
    process.exit(1);
  }
}

// Every ticket entry in the chosen list must be a plain listItem holding a paragraph. If
// the list we landed on still contains a nested bulletList, we are at the wrong depth.
const stray = (list.content || []).findIndex(li => (li.content || []).some(c => c.type === "bulletList"));
if (stray !== -1 && (list.content || []).length === 1) {
  console.error(`"${target.label}": target list looks like a wrapper, not a ticket list (item ${stray} contains a bulletList)`);
  process.exit(1);
}

const before = (list.content || []).length;
const item = {
  type: "listItem",
  content: [{ type: "paragraph", content: [{ type: "inlineCard", attrs: { url: `https://${host}/browse/${key}` } }] }],
};
// Optional one-line annotation (env ANNOTATION) as plain text after the card.
if (process.env.ANNOTATION) item.content[0].content.push({ type: "text", text: " - " + process.env.ANNOTATION });
list.content = position === "first" ? [item, ...(list.content || [])] : [...(list.content || []), item];

fs.writeFileSync(outPath, JSON.stringify(doc));
console.log(`section "${target.label}" at ${target.path}${descended ? ` (descended ${descended} wrapper level${descended > 1 ? "s" : ""})` : ""}: ${before} -> ${list.content.length} items, ${key} inserted ${position}`);
