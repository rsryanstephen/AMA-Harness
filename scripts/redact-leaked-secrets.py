"""Scrub leaked credentials out of this session's transcript, chat log and scratch files.

Deliberately reports only FILENAMES and COUNTS -- printing a match to prove the match would
recreate the leak it is cleaning up.

Matches by assignment context rather than by value shape where the value shape is generic:
an AWS secret key is 40 chars of [A-Za-z0-9/+], which as a bare regex would eat half a JWT
and every base64 blob in the transcript.

Rewrites in place with open(w), which truncates the existing inode -- it does NOT rename a
temp file over the target, so a symlinked path stays a symlink (the thing sed -i breaks).
"""
import os
import re
import sys

PATTERNS = [
    # value-shaped, safe to match anywhere
    (re.compile(r"AKIA[0-9A-Z]{16}"), "[REDACTED-AWS-ACCESS-KEY-ID]"),
    (re.compile(r"API-[A-Z0-9]{20,}"), "[REDACTED-OCTOPUS-API-KEY]"),
    # assignment-context, for values too generic to match on their own
    (re.compile(r"(AWS_SECRET_ACCESS_KEY\s*=\s*)([A-Za-z0-9/+=]{20,})"), r"\1[REDACTED]"),
    (re.compile(r"(APP_PASSWORD\s*=\s*)(\S{8,})"), r"\1[REDACTED]"),
    (re.compile(r"(OCTOPUS_CLI_API_KEY\s*=\s*)(\S{8,})"), r"\1[REDACTED]"),
    # any credential-named env var as printed by env/printenv/set (2026-10-08: a `env | grep
    # CLAUDE` dumped claude_*_pw test-user passwords). Value stops at whitespace, quote or the
    # backslash of a JSON-escaped \n. Placeholders skipped -- $VAR, <x>, [REDACTED], `...`,
    # null/none/true/false: the first cut rewrote `PGPASSWORD=...` and `claude_ama_pw=null`
    # in tracked docs/gates (reverted).
    # 2026-10-28: also quoted values (`export X="v"`, `\"` once JSONL-escaped) and
    # API_KEY/_PAT/PASSPHRASE names -- a Read of ~/.bashrc slipped past all of this.
    (re.compile(r"(?:(?<![A-Za-z0-9_])|(?<=\\[nrt]))([A-Za-z_][A-Za-z0-9_]*?(?:_pw|_PW|_pass|_PASS|PASSWORD|password|Password|SECRET|secret|TOKEN|token|API_KEY|api_key|APIKEY|_PAT|PASSPHRASE|passphrase)=(?:\\?[\"'])?)(?![$<\[%{(`.*])(?!(?:null|none|None|true|false)(?![^\s\"'\\`]))([^\s\"'\\`]{4,})"), r"\1[REDACTED]"),
    # JSON forms, in case a value was captured as a field rather than a printed line
    (re.compile(r'("(?:AWS_SECRET_ACCESS_KEY|APP_PASSWORD|OCTOPUS_CLI_API_KEY)"\s*:\s*")[^"]+'), r"\1[REDACTED]"),
    (re.compile(r'("(?:Proposed)?Password"\s*:\s*")[^"]+'), r"\1[REDACTED]"),
]

# By VALUE: every credential-named env var's own value, wherever it appears (bare, quoted,
# inside a URL) -- read from the environment, never argv, so the value is never typed. Run
# from a shell that sourced ~/.bashrc. 12+ chars only (short values hit unrelated text).
ENV_NAME = re.compile(r"(?:_pw|_PW|_pass|_PASS|PASSWORD|SECRET|TOKEN|API_KEY|APIKEY|_PAT|PASSPHRASE)$", re.I)
for _name, _val in sorted(os.environ.items()):
    if ENV_NAME.search(_name) and len(_val) >= 12 and not _val.startswith(("$", "<", "[")):
        PATTERNS.append((re.compile(re.escape(_val)), f"[REDACTED-{_name}]"))

SKIP_DIRS = {".git", "node_modules", "obj", "bin", ".vs", "dist"}
SKIP_SELF = os.path.abspath(__file__)


def scrub(path):
    try:
        with open(path, "r", encoding="utf-8", errors="surrogateescape") as fh:
            original = fh.read()
    except (OSError, UnicodeDecodeError):
        return 0

    text = original
    hits = 0
    for rx, repl in PATTERNS:
        text, n = rx.subn(repl, text)
        hits += n

    if hits and text != original:
        with open(path, "w", encoding="utf-8", errors="surrogateescape", newline="") as fh:
            fh.write(text)
    return hits


def walk(root):
    if os.path.isfile(root):
        yield root
        return
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            yield os.path.join(dirpath, name)


def main(roots):
    total_files = 0
    total_hits = 0
    for root in roots:
        if not os.path.exists(root):
            print(f"  (absent) {root}")
            continue
        for path in walk(root):
            if os.path.abspath(path) == SKIP_SELF:
                continue
            try:
                if os.path.getsize(path) > 200 * 1024 * 1024:
                    continue
            except OSError:
                # dangling symlink (chat logs are symlinks; some targets are gone)
                continue
            n = scrub(path)
            if n:
                total_files += 1
                total_hits += n
                print(f"  {n:>4} redaction(s)  {path}")
    print(f"\nfiles changed: {total_files}   redactions: {total_hits}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
