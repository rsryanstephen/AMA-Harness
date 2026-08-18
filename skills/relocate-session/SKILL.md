---
name: relocate-session
description: Move the current session (its transcript, chat log file, and all bookkeeping) to a different working directory. Use when the user says "move this session to X", "relocate this session to X", "relocate this session to another directory", or similar.
---

Relocating a session moves Claude Code's own transcript, not just this repo's chat-log
file — only supported way is the built-in `/cd` command. No tool lets you invoke it
yourself; it's a CLI input-layer command the user has to type.

1. Resolve target directory user named (expand `~`, relative paths off current cwd) to
   an absolute path.
2. Tell user to run it themselves **in this Claude session** (it's a Claude Code
   slash command, not a terminal command — say "run this in the Claude session:", not
   just "run this yourself:", so they don't try it in a terminal):
   ```
   /cd <resolved absolute path>
   ```
3. Tell them: after `/cd`, send **one more message** (anything, e.g. "done") — required.
   `/cd` is client-side, doesn't trigger `UserPromptSubmit`; nothing else runs till next
   real prompt (checking immediately after `/cd` shows nothing moved — expected). That
   next prompt makes `on-prompt.sh` notice chat file's dir ≠ cwd, move `.md` + bookkeeping +
   `sessions.txt` line, then tell you (injected context) to confirm + give resume cmd.
   No conversation history/context touched — `/cd` relocates transcript, rest is just
   this repo's mirror following along.
4. Don't move the transcript file (`~/.claude/projects/.../<id>.jsonl`) yourself — its
   on-disk layout and any other state `/cd` updates aren't safe to replicate manually;
   risks corrupting session history, exactly what this flow avoids.
