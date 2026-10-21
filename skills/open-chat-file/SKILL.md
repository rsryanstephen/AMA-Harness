---
model: haiku
name: open-chat-file
description: Open this session's chat-log file (*.Chat.md) in its default editor. Use when the user says "open chat file", "open the chat log", "open this session's chat file", "show me the chat file", or similar.
---

Open it yourself — don't just hand over a path.

```
powershell -NoProfile -Command "Start-Process '<full path to chat file>'"
```

Path = injected context's chat filename + directory (every turn names both). No injected
context → `cat "$HOME/.claude/.session-chatfiles/<full session id>"`.

**Use the REAL `Chat files/` path, not the `Local Chat Files/` one the injected context
names.** That directory is a git-bash symlink and `Start-Process` cannot follow it — it
fails with "The system cannot find the file specified" on a file that plainly exists.
Swap the directory for `<repo>/Chat files/`, same filename. Confirmed live 2026-08-31:
symlink path exit 1, real path exit 0.

Worked → say so, name the file, done. **Don't read the file** — opening it is not reading
it, that's [[chat-log-reads]]' job and costs tokens for nothing here.

Failed (no default handler, no GUI session, tool denied) → give the user the command to
run themselves, don't retry variants:

```
explorer "<full path to chat file>"
```

(`explorer` over `start`/`Start-Process` for the user-facing line — same result, and it's
the one form that works unchanged in cmd, PowerShell, and git-bash. It exits **1 even on
success** — don't read that as a failure.)
