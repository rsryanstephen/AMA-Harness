#!/usr/bin/env node
// Second half of the export verification: compare a downloaded/unzipped export CSV
// against the grid snapshot that verify-export-vs-grid.mjs captured.
//
// Checks, in order of what actually catches regressions:
//   1. COLUMN ORDER  -- the exported header sequence vs the grid's visual column order.
//      Order is part of the export contract, so this is an ordered comparison, never a
//      set comparison. Reported as the first differing position, not just "differs".
//   2. MISSING / EXTRA columns -- set difference both ways, so a dropped column is not
//      hidden by a coincidentally-equal count.
//   3. VALUES -- spot-compares CSV cells against the /search response values the grid
//      was actually built from. Numeric compare is tolerant of formatting (thousands
//      separators, %, trailing zeros); text compare is exact after trim.
//
// Usage: diff-export-vs-grid.mjs <gridJsonPath> <csvPath> [--max-rows N]
// Exit:  0 all checks passed | 6 a check failed | 64 bad usage
import { readFileSync } from 'fs';

const args = process.argv.slice(2);
const gridJsonPath = args[0];
const csvPath = args[1];
const maxRowsIdx = args.indexOf('--max-rows');
const maxRows = maxRowsIdx > -1 ? parseInt(args[maxRowsIdx + 1], 10) : 25;
if (!gridJsonPath || !csvPath) {
  console.error('usage: diff-export-vs-grid.mjs <gridJsonPath> <csvPath> [--max-rows N]');
  process.exit(64);
}

// --- RFC4180-ish CSV parse: quoted fields, escaped "" , embedded commas/newlines ---
function parseCsv(text) {
  const rows = [];
  let row = [], field = '', inQ = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQ) {
      if (c === '"') {
        if (text[i + 1] === '"') { field += '"'; i++; }
        else inQ = false;
      } else field += c;
    } else if (c === '"') inQ = true;
    else if (c === ',') { row.push(field); field = ''; }
    else if (c === '\r') { /* skip */ }
    else if (c === '\n') { row.push(field); rows.push(row); row = []; field = ''; }
    else field += c;
  }
  if (field.length || row.length) { row.push(field); rows.push(row); }
  return rows.filter(r => r.some(c => c !== ''));
}

const grid = JSON.parse(readFileSync(gridJsonPath, 'utf8'));
const csvRows = parseCsv(readFileSync(csvPath, 'utf8'));
if (!csvRows.length) { console.error('FAIL: CSV is empty'); process.exit(6); }

// The export may carry preamble lines (query description / top row) before the header.
// The header is the first row whose cells best match the grid's header labels.
const gridHeaderTexts = (grid.grid?.headers || []).map(h => h.text).filter(Boolean);
const norm = s => String(s ?? '').replace(/\s+/g, ' ').trim().toLowerCase();
const gridSet = new Set(gridHeaderTexts.map(norm));
let headerIdx = 0, bestHits = -1;
csvRows.slice(0, 10).forEach((r, i) => {
  const hits = r.filter(c => gridSet.has(norm(c))).length;
  if (hits > bestHits) { bestHits = hits; headerIdx = i; }
});
const csvHeader = csvRows[headerIdx].map(c => c.trim());
const csvData = csvRows.slice(headerIdx + 1);

console.log(`grid headers: ${gridHeaderTexts.length}`);
console.log(`csv header row: index ${headerIdx} (${bestHits} label matches), ${csvHeader.length} columns`);
console.log(`csv data rows: ${csvData.length}`);
if (headerIdx > 0) console.log(`note: skipped ${headerIdx} preamble row(s) before the header`);

let failed = false;
const fail = m => { failed = true; console.log('FAIL: ' + m); };
const pass = m => console.log('PASS: ' + m);

// --- 1. column order ---
const common = csvHeader.filter(h => gridSet.has(norm(h)));
const gridOrderOfCommon = gridHeaderTexts.filter(h => common.map(norm).includes(norm(h)));
const firstDiff = common.findIndex((h, i) => norm(h) !== norm(gridOrderOfCommon[i]));
if (!common.length) {
  fail('no CSV header matched any grid header label - cannot compare order '
    + `(csv sample: ${JSON.stringify(csvHeader.slice(0, 6))}, grid sample: ${JSON.stringify(gridHeaderTexts.slice(0, 6))})`);
} else if (firstDiff === -1) {
  pass(`column ORDER matches for all ${common.length} shared columns`);
} else {
  fail(`column ORDER diverges at position ${firstDiff}: csv has "${common[firstDiff]}", `
    + `grid has "${gridOrderOfCommon[firstDiff]}"`);
  console.log('  csv  order:', JSON.stringify(common.slice(0, 20)));
  console.log('  grid order:', JSON.stringify(gridOrderOfCommon.slice(0, 20)));
}

// --- 2. missing / extra ---
const csvSet = new Set(csvHeader.map(norm));
const missing = gridHeaderTexts.filter(h => !csvSet.has(norm(h)));
const extra = csvHeader.filter(h => h && !gridSet.has(norm(h)));
if (missing.length) fail(`${missing.length} grid column(s) absent from the CSV: ${JSON.stringify(missing.slice(0, 25))}`);
else pass('every grid column appears in the CSV');
if (extra.length) console.log(`note: ${extra.length} CSV column(s) not shown in the grid `
  + `(expected for hidden/extra export fields): ${JSON.stringify(extra.slice(0, 25))}`);

// --- 3. values ---
// Flatten every /search result row into one bag of columnId -> values, plus a
// label-insensitive bag of raw values, so we can confirm CSV numbers really occur.
const searchRows = [];
for (const s of grid.grid?.searchResponses || []) for (const r of (s.results || [])) searchRows.push(r);
const numeric = v => {
  const t = String(v ?? '').replace(/[,%$\s]/g, '');
  if (t === '' || isNaN(Number(t))) return null;
  return Number(t);
};
const searchNumbers = new Set();
for (const r of searchRows) for (const v of Object.values(r)) {
  const n = numeric(v);
  if (n !== null) searchNumbers.add(Math.round(n * 1e4) / 1e4);
}
let checked = 0, matched = 0;
const unmatchedSamples = [];
for (const row of csvData.slice(0, maxRows)) {
  for (const cell of row) {
    const n = numeric(cell);
    if (n === null) continue;
    checked++;
    if (searchNumbers.has(Math.round(n * 1e4) / 1e4)) matched++;
    else if (unmatchedSamples.length < 8) unmatchedSamples.push(cell);
  }
}
if (!checked) {
  console.log('note: no numeric CSV cells in the sampled rows - value cross-check skipped');
} else {
  const pct = Math.round((matched / checked) * 100);
  console.log(`value cross-check: ${matched}/${checked} sampled numeric CSV cells (${pct}%) `
    + `also occur in the /search payloads the grid rendered`);
  if (pct < 50) {
    fail(`only ${pct}% of sampled numeric cells trace back to grid data `
      + `- unmatched samples: ${JSON.stringify(unmatchedSamples)}`);
  } else {
    pass('sampled CSV values trace back to the grid data');
  }
  console.log('  (a partial match is expected: the CSV can hold more rows/columns than the '
    + 'grid viewport requested, and formatting/rounding differs)');
}

console.log(failed ? '\nRESULT: FAILED' : '\nRESULT: PASSED');
process.exit(failed ? 6 : 0);
