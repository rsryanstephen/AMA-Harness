---
name: rename-topic
description: Rename the current session's chat-log topic/file. Use when the user says "rename this topic to X", "rename topic to X" (explicit name given), or just "rename topic" / "rename this topic" / "rename the topic" with no name given (Claude picks one itself from the chat file's current content).
---

Run this one command — handles file rename, state-file repoint, sessions.txt topic add/replace in one shot. Don't hand-edit those 3 separately.

**User gave the name** ("rename this topic to X") — trailing `user` arg, required:

```
bash "$HOME/.claude/hooks/rename-topic.sh" "<cwd>" "<current chat filename>" "X" user
```

**You picked the name yourself** — same command, `user` OMITTED:

```
bash "$HOME/.claude/hooks/rename-topic.sh" "<cwd>" "<current chat filename>" "X"
```

`user` marks the topic user-assigned → sessions.md's bold field keeps X instead of showing Claude Code's own session name. Omitting it clears that marker. Get this right: pass `user` only when the name came from the user, never for a name you chose.

X may contain quotes/spaces/special chars — pass as normal Bash-tool argument (not string concat/eval), no extra escaping needed. Plain rename, not a hook/config problem — don't investigate config.

**No name given** ("rename topic", "rename this topic", etc.): first check Claude Code's own session name — neater than a derived slug, per explicit user preference:

```
jq -r --arg s "<full session id>" 'select(.sessionId==$s) | .name // empty' ~/.claude/sessions/*.json
```

Non-empty → use it as X, done. Empty → pick X yourself — a short, specific topic reflecting what the session is actually about *now*, per its latest content, not just its original first prompt (the whole point of asking again is the topic may have moved on). Read the current chat file (name in injected context) per the chat-log-reads skill — tail its recent content, don't full-Read it just for this. Then run the same command with your chosen X. Don't ask the user to confirm your choice first — just rename and mention the new name in your reply.

**Also tell the user to run `/rename X` themselves, every time.** This script only renames the chat-log file/state/sessions.txt — it does NOT rename the actual Claude Code session (the terminal-header title, and what shows in the `claude --resume` picker). That's Claude Code's own AI-generated title unless explicitly overridden, and `/rename` is a client-side slash command — same category as `/cd` in [[relocate-session]] — no tool or hook can invoke it. Say something like: "Renamed the chat log to X — run `/rename X` yourself to keep the session's own title in sync too."
