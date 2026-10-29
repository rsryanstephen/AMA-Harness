#!/usr/bin/env bash
# Find the newest user-initiated export zip in <env>-v1-results-processor, download it,
# and unzip it. Third leg of the export verification (see ama-architecture-notes'
# EXPORT-DOWNLOADS.md for why the listing is done this way).
#
# Usage: fetch-export-zip.sh <env: qa|staging|production> <out-dir> [name-substring] [since-iso]
#   name-substring  optional filter on the key (the zip is named from the REPORT name with
#                   invalid filename chars stripped -- never assume an exact name)
#   since-iso       optional lower bound on LastModified, e.g. 2026-08-18T15:00:00Z
set -euo pipefail
export MSYS_NO_PATHCONV=1

ENV_NAME="${1:?usage: fetch-export-zip.sh <env> <out-dir> [name-substring] [since-iso]}"
OUT_DIR="${2:?out-dir required}"
NEEDLE="${3:-}"
SINCE="${4:-}"
BUCKET="${ENV_NAME}-v1-results-processor"

mkdir -p "$OUT_DIR"

# git-bash hands node POSIX paths (/c/Users/...) which node resolves against the drive root
# as C:\c\Users\... and then ENOENTs. Anything passed to node must be converted first.
to_win() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# Global newest-first sort. Deliberately NOT --max-items (returns first-N in KEY order)
# and NOT --query reverse(sort_by(...)) (sorts PER PAGE only). Both confirmed wrong live.
listing="$OUT_DIR/.listing.json"
aws s3api list-objects-v2 --bucket "$BUCKET" --output json > "$listing"

key="$(NEEDLE="$NEEDLE" SINCE="$SINCE" node -e '
const fs=require("fs");
const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const needle=(process.env.NEEDLE||"").toLowerCase();
const since=process.env.SINCE?Date.parse(process.env.SINCE):null;
let rows=(j.Contents||[]);
if(needle) rows=rows.filter(r=>r.Key.toLowerCase().includes(needle));
if(since!==null&&!isNaN(since)) rows=rows.filter(r=>Date.parse(r.LastModified)>=since);
rows.sort((a,b)=>Date.parse(b.LastModified)-Date.parse(a.LastModified));
if(!rows.length){process.stderr.write("no matching object\n");process.exit(1)}
const r=rows[0];
process.stderr.write(`newest: ${r.LastModified}  ${r.Size} bytes  ${r.Key}\n`);
for(const x of rows.slice(1,5)) process.stderr.write(`  next: ${x.LastModified}  ${x.Key}\n`);
process.stdout.write(r.Key);
' "$(to_win "$listing")")"

echo "key: $key"
# MSYS_NO_PATHCONV=1 (needed so the s3:// URI is left alone) also stops the LOCAL path being
# translated, and `aws s3 cp` then writes to a bogus relative path. Give it the Windows form.
# cygpath -m emits C:/... which bash, aws and unzip all accept.
WOUT="$(to_win "$OUT_DIR")"
zip="$WOUT/export.zip"
aws s3 cp "s3://$BUCKET/$key" "$zip"

rm -rf "$OUT_DIR/unzipped"
mkdir -p "$OUT_DIR/unzipped"
unzip -o "$zip" -d "$WOUT/unzipped" >/dev/null
echo "--- contents ---"
find "$OUT_DIR/unzipped" -type f -printf '%s\t%p\n' 2>/dev/null || find "$OUT_DIR/unzipped" -type f
