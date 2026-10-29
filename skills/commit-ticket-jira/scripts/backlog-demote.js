// Move one ticket's listItem from the main AMA Backlog page to a section of the Deferred
// child page, VERBATIM -- the entry's own paragraph content (inlineCard plus any
// hand-written annotation like "This never re-occurred") is carried across untouched.
// Rebuilding the node from the key alone would silently drop those annotations, and they
// are the whole justification for demoting an entry.
//
// Section anatomy is the same as backlog-splice.js: top-level listItems whose OWN
// paragraph text is the section name, each holding a nested bulletList; found by text,
// never by index. The main page's `Bugs` section nests one level deeper than the rest
// (a lone empty-text wrapper listItem), so both pages are searched at any depth.
//
// Env: KEY (required), SECTION (Deferred target, default "Low Priority")
// Usage: backlog-demote.js <main-in> <deferred-in> <main-out> <deferred-out>
const fs = require("fs");

const [, , mainIn, defIn, mainOut, defOut] = process.argv;
const key = process.env.KEY;
const section = (process.env.SECTION || "Low Priority").trim();
if (!mainIn || !defIn || !mainOut || !defOut || !key) {
  console.error("usage: KEY=... backlog-demote.js <main-in> <deferred-in> <main-out> <deferred-out>");
  process.exit(64);
}

const main = JSON.parse(fs.readFileSync(mainIn, "utf8"));
const deferred = JSON.parse(fs.readFileSync(defIn, "utf8"));

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

// Card URL, anchored: another entry's annotation may name this key, and 153 must not hit 1530.
const keyRe = new RegExp(`browse/${key}(?![0-9])`);
const mentionsKey = node => keyRe.test(JSON.stringify(node));

// --- 1. locate the entry on the main page -------------------------------------------
// Walk every bulletList at any depth. The entry is a listItem mentioning the key that
// holds no nested bulletList of its own -- a leaf ticket row, not the section or wrapper
// that contains it.
const hits = [];
const visit = (list, path) => {
  (list.content || []).forEach((li, i) => {
    if (li.type !== "listItem") return;
    const nested = (li.content || []).filter(c => c.type === "bulletList");
    if (mentionsKey(li) && nested.length === 0) hits.push({ list, index: i, li, path: [...path, i] });
    nested.forEach(n => visit(n, [...path, i]));
  });
};
(main.content || []).forEach((n, i) => { if (n.type === "bulletList") visit(n, [i]); });

if (hits.length === 0) {
  console.error(`${key}: no leaf entry found on the main page`);
  process.exit(1);
}
if (hits.length > 1) {
  // e.g. PROJ-14729 (Low Priority Bugs + the Automated API Tests prose block) and
  // PROJ-14731 (Tech Debt + the Terraform block). Removing one leaves the key still
  // harvested by the pickup path while the key-delta guard reads -1. Refuse.
  console.error(`${key}: listed ${hits.length} times on the main page (paths ${hits.map(h => JSON.stringify(h.path)).join(", ")}) -- refusing, a partial removal leaves the key still on the page`);
  process.exit(1);
}

const hit = hits[0];
if (JSON.stringify(hit.li).includes("mediaSingle")) {
  console.error(`${key}: entry contains a mediaSingle -- refusing, that image would move pages`);
  process.exit(1);
}

const entry = hit.li;
const annotation = ownText(entry).replace(/^\s*[-–]\s*/, "");
hit.list.content.splice(hit.index, 1);
if ((hit.list.content || []).length === 0) {
  console.error(`${key}: removing it would leave an empty list at ${JSON.stringify(hit.path.slice(0, -1))} -- refusing, that changes the page's section structure`);
  process.exit(1);
}

// --- 2. append it to the Deferred section -------------------------------------------
// Exact section-name match here, not a prefix: the Deferred page has both "Bugs" and
// "Low Priority", and a prefix match invites the wrong one on a future rename.
let target = null;
(deferred.content || []).forEach((node, i) => {
  if (node.type !== "bulletList") return;
  (node.content || []).forEach((li, j) => {
    const t = ownText(li).toLowerCase().replace(/:$/, "");
    if (target || t !== section.toLowerCase().replace(/:$/, "")) return;
    const nestedIdx = (li.content || []).findIndex(c => c.type === "bulletList");
    if (nestedIdx === -1) return;
    target = { li, nestedIdx, path: `.content[${i}].content[${j}].content[${nestedIdx}]`, label: ownText(li) };
  });
});

if (!target) {
  console.error(`Deferred section not found: "${section}". Sections seen: ` + JSON.stringify(
    (deferred.content || []).filter(n => n.type === "bulletList")
      .flatMap(n => (n.content || []).map(ownText)).filter(Boolean)));
  process.exit(1);
}

const list = target.li.content[target.nestedIdx];
const before = (list.content || []).length;
list.content = [...(list.content || []), entry];

fs.writeFileSync(mainOut, JSON.stringify(main));
fs.writeFileSync(defOut, JSON.stringify(deferred));
console.log(`${key}: removed from main at ${JSON.stringify(hit.path)}, appended to Deferred "${target.label}" (${before} -> ${list.content.length} items)${annotation ? `; annotation carried: "${annotation}"` : "; no annotation"}`);
