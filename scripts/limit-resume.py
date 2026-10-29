#!/usr/bin/env python
"""Usage-limit resume audit (<harnessEpicKey>, user rule 2026-10-21).

When a session hits the account usage limit mid-task and later runs again, it must audit
what was unfinished and pick each item up. Nothing upstream guarantees that:
  - Claude Code's own auto-continue ("Usage limit reached - continuing automatically at
    ...") is not always armed. 44b3716a hit the limit at 13:56Z in a task-notification
    turn and got no continue record; 7b95a7f6, same window, did.
  - The scheduled-task resume (statusline.sh schedule_resume -> resume-rate-limited.sh)
    never fired (no task, undrained queue), and it would run headless anyway, where
    on-prompt.sh does nothing.
  - A durable reminder is moved to fired/ when it is CLAIMED, so a claimer cut off by the
    limit lost the 15:45 Production RDS check for good.

The limit hit is the transcript record with "apiError":"usage_limit_reached" (its uuid
and apiErrorParams.rate_limit_info.resetsAt). Everything keys off that record's uuid, so
a second hit in the same session is a new audit, and re-running is idempotent.

Subcommands (all print nothing and exit 1 when there is nothing to do):
  pending <sid>        uuid of a limit hit in <sid> not yet audited (bounded tail read)
  clear <sid>          move <sid>'s read-only resume report(s) to reports/cleared/ -- only once the
                       user has seen and decided on them (limit-resume-check.sh re-shows until then)
  cutoff <sid>         exit 0 only if <sid> really was cut off: its last usage-limit hit has no
                       completed turn after it (the drain's filter -- the queue is filled at 99%,
                       before any hit, so it also holds sessions that finished cleanly)
  audit <sid>          the checklist for that hit; records it as OWED for the Stop check
  owed <sid>           the owed uuid, if the audit was injected but not yet answered
  ack <sid>            mark the owed audit answered (the Stop check calls this)
  stalled <sid> [grace]  exit 0 if <sid>'s last turn IS the limit hit and resetsAt+grace
                       (default 300s) has passed with nothing after it; prints the uuid
  sweep <self-sid>     every session stalled past resetsAt+1800s: surface it once, and
                       re-queue durable reminders it claimed and never acked
Seams: CLAUDE_STATE_DIR, LIMIT_PROJECTS_DIR, LIMIT_SESSIONS_DIR, LIMIT_NOW (epoch).
"""
import glob
import json
import os
import re
import subprocess
import sys
import time

TAIL_BYTES = 30 * 1024 * 1024  # transcripts reach 96 MB; a limit hit is near the end
REQUEUE_CLAIM_WINDOW = 4 * 3600  # a reminder claimed earlier than this before the hit is not re-queued


def winpath(p):
    m = re.match(r'^/([a-zA-Z])/(.*)$', p or '')
    return f'{m.group(1).upper()}:/{m.group(2)}' if m else p


HOME = os.path.expanduser('~').replace('\\', '/')
STATE = winpath(os.environ.get('CLAUDE_STATE_DIR') or f'{HOME}/.claude/harness-state')
LIMITS = f'{STATE}/limits'
REMINDERS = f'{STATE}/reminders'
PROJECTS = winpath(os.environ.get('LIMIT_PROJECTS_DIR') or f'{HOME}/.claude/projects')
SESSIONS = winpath(os.environ.get('LIMIT_SESSIONS_DIR') or f'{HOME}/.claude/sessions')
NOW = int(os.environ.get('LIMIT_NOW') or time.time())


def iso_epoch(ts):
    try:
        return int(time.mktime(time.strptime(ts[:19], '%Y-%m-%dT%H:%M:%S')) - time.timezone)
    except Exception:
        return 0


def local(epoch):
    return time.strftime('%H:%M %a %d %b', time.localtime(epoch)) if epoch else '?'


def transcript(sid):
    hits = glob.glob(f'{PROJECTS}/*/{sid}.jsonl')
    return max(hits, key=os.path.getmtime) if hits else None


def records(path):
    """Records from the last TAIL_BYTES of the transcript, in order."""
    size = os.path.getsize(path)
    with open(path, 'rb') as fh:
        if size > TAIL_BYTES:
            fh.seek(size - TAIL_BYTES)
            fh.readline()
        raw = fh.read().decode('utf-8', 'replace')
    out = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        try:
            out.append(json.loads(line))
        except Exception:
            pass
    return out


def text_of(rec):
    c = (rec.get('message') or {}).get('content')
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return ' '.join(x.get('text', '') for x in c if isinstance(x, dict) and x.get('type') == 'text')
    return ''


def is_limit(rec):
    return rec.get('type') == 'assistant' and rec.get('apiError') == 'usage_limit_reached'


def last_hit(recs):
    for i in range(len(recs) - 1, -1, -1):
        if is_limit(recs[i]):
            return i
    return None


def resets_at(rec):
    info = (rec.get('apiErrorParams') or {}).get('rate_limit_info') or rec.get('quotaLimits') or {}
    try:
        return int(info.get('resetsAt') or 0)
    except Exception:
        return 0


def turn_completed_after(recs, i):
    """A turn that started after the hit has already finished (turn_duration / stop summary).
    Then the session moved on long ago and the hit is not an audit owed now."""
    a = None
    for k in range(i + 1, len(recs)):
        r = recs[k]
        if a is None and r.get('type') in ('user', 'assistant') and not is_limit(r):
            a = k
        elif a is not None and r.get('type') == 'system' and r.get('subtype') in ('turn_duration', 'stop_hook_summary'):
            return True
    return False


def activity_after(recs, i):
    """A real turn after the hit: a user/assistant record that is not another limit hit."""
    for r in recs[i + 1:]:
        if r.get('type') in ('user', 'assistant') and not is_limit(r):
            return r
    return None


def readf(path):
    try:
        with open(path, encoding='utf-8') as fh:
            return fh.read().strip()
    except Exception:
        return ''


def writef(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(text + '\n')


def session_name(sid):
    for line in readf(f'{HOME}/.claude/sessions.txt').splitlines():
        if sid in line:
            return line.split(' ', 1)[0]
    return sid[:8]


def owner_alive(sid):
    for f in glob.glob(f'{SESSIONS}/*.json'):
        if sid not in readf(f):
            continue
        pid = os.path.basename(f)[:-5]
        try:
            out = subprocess.run(['tasklist.exe', '/FI', f'PID eq {pid}', '/NH'],
                                 capture_output=True, text=True, timeout=15).stdout
            if 'claude' in out.lower():
                return True
        except Exception:
            return True  # cannot tell -> treat as alive (never resume behind a live window)
    return False


def is_real_prompt(rec):
    if rec.get('type') != 'user' or rec.get('isMeta'):
        return False
    origin = (rec.get('origin') or {}).get('kind', '')
    if origin in ('task-notification', 'auto-continuation'):
        return False
    t = text_of(rec).strip()
    return bool(t) and not t.startswith('<') and not t.startswith('This session is being continued')


def tool_uses(rec):
    c = (rec.get('message') or {}).get('content')
    return [x for x in c if isinstance(x, dict) and x.get('type') == 'tool_use'] if isinstance(c, list) else []


def tool_results(rec):
    c = (rec.get('message') or {}).get('content')
    return [x for x in c if isinstance(x, dict) and x.get('type') == 'tool_result'] if isinstance(c, list) else []


def describe_tool(tu):
    inp = tu.get('input') or {}
    what = inp.get('description') or inp.get('command') or inp.get('prompt') or inp.get('file_path') or json.dumps(inp)
    return f"{tu.get('name')}: {str(what)[:200]}"


def cmd_pending(sid):
    path = transcript(sid)
    if not path:
        return 1
    recs = records(path)
    i = last_hit(recs)
    if i is None:
        return 1
    uuid = recs[i].get('uuid', '')
    if uuid and uuid != readf(f'{LIMITS}/{sid}.audited') and not turn_completed_after(recs, i):
        print(uuid)
        return 0
    return 1


def cmd_cutoff(sid):
    path = transcript(sid)
    if not path:
        return 1
    recs = records(path)
    i = last_hit(recs)
    return 0 if i is not None and not turn_completed_after(recs, i) else 1


def cmd_clear(sid):
    done = f'{LIMITS}/reports/cleared'
    os.makedirs(done, exist_ok=True)
    n = 0
    for p in glob.glob(f'{LIMITS}/reports/{sid}.*.md'):
        os.replace(p, f'{done}/{os.path.basename(p)}')
        n += 1
    print(f'cleared {n} report(s) for {sid}')
    return 0 if n else 1


def cmd_audit(sid):
    path = transcript(sid)
    if not path:
        return 1
    recs = records(path)
    i = last_hit(recs)
    if i is None:
        return 1
    hit = recs[i]
    uuid = hit.get('uuid', '')
    if uuid == readf(f'{LIMITS}/{sid}.audited') or turn_completed_after(recs, i):
        return 1
    hit_t = iso_epoch(hit.get('timestamp', ''))
    reset = resets_at(hit)
    after = activity_after(recs, i)
    auto = after if after is not None and (after.get('origin') or {}).get('kind') == 'auto-continuation' else None

    before = recs[:i]
    lines = [f"USAGE-LIMIT RESUME AUDIT -- this session was cut off by the usage limit at {local(hit_t)} "
             f"(limit reset {local(reset)}; {'Claude Code auto-continued it' if auto else 'resumed by the next prompt/wake'}). "
             "Before anything else, work through every item below; nothing that was in flight may be left unfinished."]

    prompt = next((r for r in reversed(before) if is_real_prompt(r)), None)
    if prompt:
        lines.append(f"1. Request in force when the limit hit ({local(iso_epoch(prompt.get('timestamp', '')))}): "
                     f"{' '.join(text_of(prompt).split())[:700]}")
    notes = [r for r in before[-400:] if r.get('type') == 'user' and (r.get('origin') or {}).get('kind') == 'task-notification']
    if notes:
        last_note = ' '.join(text_of(notes[-1]).split())
        m = re.search(r'<summary>(.*?)</summary>', last_note)
        lines.append(f"2. The turn that hit the limit was answering a background-task notification: "
                     f"{(m.group(1) if m else last_note)[:300]}")

    said = [' '.join(text_of(r).split()) for r in before[-300:] if r.get('type') == 'assistant' and text_of(r).strip()]
    if said:
        lines.append("3. What you last said you were doing (latest last): " + ' || '.join(s[:350] for s in said[-3:]))

    # Last tool call: did its result come back unread?
    last_tu, tu_idx = None, None
    for k in range(len(before) - 1, -1, -1):
        tus = tool_uses(before[k])
        if tus:
            last_tu, tu_idx = tus[-1], k
            break
    if last_tu:
        got = any(tr.get('tool_use_id') == last_tu.get('id') for r in before[tu_idx + 1:] for tr in tool_results(r))
        lines.append(f"4. Last tool call before the hit: {describe_tool(last_tu)} -- "
                     + ("its RESULT CAME BACK BUT WAS NEVER READ: re-read or re-run it and act on it."
                        if got else "it never returned a result: re-run it."))

    # Background work launched before the hit with no completion notification consumed before it.
    launched = {}
    for r in before[-3000:]:
        for tu in tool_uses(r):
            inp = tu.get('input') or {}
            if inp.get('run_in_background') or tu.get('name') in ('Workflow', 'Monitor') or (tu.get('name') == 'Agent' and inp.get('run_in_background')):
                launched[tu.get('id')] = describe_tool(tu)
    done_ids = set()
    task_ids = {}
    for r in recs[max(0, i - 3000):]:
        t = text_of(r) if r.get('type') == 'user' else ''
        for tr in tool_results(r):
            body = json.dumps(tr.get('content'))
            m = re.search(r'(?:ID|Task ID): ?([a-z0-9]{6,})', body)
            if m and tr.get('tool_use_id') in launched:
                task_ids[tr['tool_use_id']] = m.group(1)
        if '<task-notification>' in t:
            for m in re.finditer(r'<tool-use-id>([^<]+)</tool-use-id>', t):
                if re.search(r'<status>(completed|failed|killed|stopped)', t):
                    done_ids.add(m.group(1))
    open_bg = [f"{v} [{task_ids.get(k, k)}]" for k, v in launched.items() if k not in done_ids]
    if open_bg:
        lines.append("5. Background work launched before the hit with no completion seen: " + ' | '.join(open_bg[-8:])
                     + " -- check each one's output file/status (a workflow resumes itself after the limit; read its result rather than relaunching it).")

    claimed = []
    for f in glob.glob(f'{REMINDERS}/fired/*.{sid}.rem'):
        due_line = readf(f).splitlines()
        if len(due_line) >= 4:
            claimed.append(f"{os.path.basename(f).split('.')[0]} (due {due_line[2]}): {' '.join(' '.join(due_line[3:]).split())[:300]}")
    requeued = [os.path.basename(f).split('.')[0] for f in glob.glob(f'{REMINDERS}/fired/*.{sid}.requeued')]
    if claimed:
        lines.append("6. Durable reminders this session claimed and never acked done: " + ' | '.join(claimed)
                     + " -- finish each, then `bash ~/.claude/scripts/reminder.sh done <id>`.")
    if requeued:
        lines.append("6b. Reminders this session claimed were RE-QUEUED to another session while it was stalled "
                     f"({', '.join(requeued)}): do NOT redo them; check `bash ~/.claude/scripts/reminder.sh fired` before touching that work.")

    lines.append("7. Queued prompts: run the chat-file dequeue (`bash \"$HOME/.claude/hooks/dequeue-prompt.sh\" \"<chat file>\"`) once the items above are done.")
    lines.append("Then RESUME each unfinished item now, where it left off -- do not repeat completed work, do not just report it. "
                 "Your reply MUST contain a section headed `Limit-resume audit` listing every item above with its status "
                 "(already done / resumed now / running in background <id> / not needed, and why). "
                 "The Stop hook (limit-resume-stop-check.sh) sends the reply back once if that section is missing.")
    writef(f'{LIMITS}/{sid}.owed', uuid)
    writef(f'{LIMITS}/{sid}.audited', uuid)
    print('\n'.join(lines))
    return 0


def cmd_owed(sid):
    u = readf(f'{LIMITS}/{sid}.owed')
    if u:
        print(u)
        return 0
    return 1


def cmd_ack(sid):
    try:
        os.remove(f'{LIMITS}/{sid}.owed')
    except FileNotFoundError:
        pass
    return 0


def stalled_hit(sid, grace):
    path = transcript(sid)
    if not path:
        return None
    recs = records(path)
    i = last_hit(recs)
    if i is None or activity_after(recs, i) is not None:
        return None
    reset = resets_at(recs[i])
    if not reset or NOW < reset + grace:
        return None
    return recs, i


def cmd_stalled(sid, grace=300):
    got = stalled_hit(sid, grace)
    if not got:
        return 1
    recs, i = got
    if recs[i].get('uuid') == readf(f'{LIMITS}/{sid}.woke'):
        return 1
    writef(f'{LIMITS}/{sid}.woke', recs[i].get('uuid', ''))
    print(recs[i].get('uuid', ''))
    return 0


QUEUE = f'{STATE}/sessions/.rate-limited-sessions'


def enqueue(sid):
    rows = readf(QUEUE).splitlines()
    if not any(r.startswith(sid + '|') for r in rows):
        os.makedirs(os.path.dirname(QUEUE), exist_ok=True)
        with open(QUEUE, 'a', encoding='utf-8', newline='\n') as fh:
            fh.write(f'{sid}|claude --resume {sid} -p "continue" --no-chrome\n')


def cmd_sweep(self_sid):
    grace = 1800
    out = []
    for path in glob.glob(f'{PROJECTS}/*/*.jsonl'):
        if NOW - os.path.getmtime(path) > 3 * 86400:
            continue
        sid = os.path.basename(path)[:-6]
        if sid == self_sid:
            continue
        got = stalled_hit(sid, grace)
        if not got:
            continue
        recs, i = got
        uuid = recs[i].get('uuid', '')
        hit_t = iso_epoch(recs[i].get('timestamp', ''))
        # Re-queue durable reminders it claimed (after their due time) and never acked.
        for f in glob.glob(f'{REMINDERS}/fired/*.{sid}.rem'):
            body = readf(f).splitlines()
            if len(body) < 4:
                continue
            try:
                due = int(body[0])
            except ValueError:
                continue
            if hit_t < due:
                continue  # hit before it was even due -> not the cause
            # Claimed long before the hit = almost certainly finished, just never acked (`done` is
            # advisory, and every pre-2026-10-21 claim is unacked). Only a claim shortly before
            # the hit can be the work the limit cut off. mtime = claim time (reminder.sh claim).
            if not (hit_t - REQUEUE_CLAIM_WINDOW <= os.path.getmtime(f) <= hit_t + 60):
                continue
            rid = os.path.basename(f).split('.')[0]
            note = (f"[RE-QUEUED {local(NOW)}: first claimed by session {sid[:8]} ({session_name(sid)}), which was cut off by the "
                    f"usage limit at {local(hit_t)} and never resumed. It may have done part of this -- check before redoing.] ")
            body[3] = note + body[3]
            os.makedirs(f'{REMINDERS}/pending', exist_ok=True)
            writef(f'{REMINDERS}/pending/{rid}.rem', '\n'.join(body))
            os.replace(f, f[:-4] + '.requeued')
            out.append(f"re-queued durable reminder {rid} (claimed by stalled session {sid[:8]}) -- it is due now and goes to the first session to claim it")
        flag = f'{LIMITS}/surfaced/{sid}.{uuid}'
        if os.path.exists(flag):
            continue
        writef(flag, str(NOW))
        said = [' '.join(text_of(r).split()) for r in recs[max(0, i - 300):i] if r.get('type') == 'assistant' and text_of(r).strip()]
        req = said[-1][:240] if said else '?'
        if owner_alive(sid):
            how = "its window is still open but idle: type anything in that session (e.g. \"continue\") and it will run the limit-resume audit"
        else:
            how = "its window is closed, so it is queued for the one-at-a-time headless resume (hooks/resume-rate-limited.sh)"
            enqueue(sid)
        out.append(f"SESSION STALLED BY THE USAGE LIMIT: \"{session_name(sid)}\" ({sid[:8]}) was cut off at {local(hit_t)}, "
                   f"the limit reset at {local(resets_at(recs[i]))}, and it never continued. Its last words: {req}. "
                   f"Tell the user now -- {how}.")
    if out:
        print(' | '.join(out))
        return 0
    return 1


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    cmd, sid = argv[1], argv[2]
    if cmd == 'pending':
        return cmd_pending(sid)
    if cmd == 'clear':
        return cmd_clear(sid)
    if cmd == 'cutoff':
        return cmd_cutoff(sid)
    if cmd == 'audit':
        return cmd_audit(sid)
    if cmd == 'owed':
        return cmd_owed(sid)
    if cmd == 'ack':
        return cmd_ack(sid)
    if cmd == 'stalled':
        return cmd_stalled(sid, int(argv[3]) if len(argv) > 3 else 300)
    if cmd == 'sweep':
        return cmd_sweep(sid)
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
