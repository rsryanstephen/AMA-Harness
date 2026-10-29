"""Print what an unattended limit-resume run did: every tool call and reply after the resume prompt.
Usage: python ~/.claude/scripts/limit-resume-review.py <session-id>  (resume-rate-limited.sh drain)"""
import json, sys, glob, os
sid = sys.argv[1]
files = glob.glob(os.path.expanduser('~/.claude/projects/*/%s.jsonl' % sid))
if not files: print('no transcript'); sys.exit(1)
lines = open(files[0], encoding='utf-8', errors='replace').read().splitlines()
start = None
for i, l in enumerate(lines):
    if 'resumed UNATTENDED by the harness' in l: start = i
if start is None: print('no unattended resume found'); sys.exit(0)
print('transcript:', files[0], 'resume at line', start, 'of', len(lines))
for l in lines[start:]:
    try: r = json.loads(l)
    except Exception: continue
    m = r.get('message') or {}
    if r.get('type') != 'assistant' or not isinstance(m.get('content'), list): continue
    for c in m['content']:
        if c.get('type') == 'tool_use':
            inp = c.get('input', {})
            s = inp.get('command') or inp.get('file_path') or inp.get('prompt') or json.dumps(inp)
            print('%s TOOL %s: %s' % (r.get('timestamp', '')[11:19], c['name'], str(s).replace('\n', ' ')[:220]))
        elif c.get('type') == 'text' and c.get('text', '').strip():
            print('%s SAYS: %s' % (r.get('timestamp', '')[11:19], c['text'].replace('\n', ' ')[:300]))
