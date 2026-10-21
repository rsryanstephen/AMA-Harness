---
name: process-prompt-queue
description: Work through queued prompts (blocks marked with a leading "-- Q", "--Q", "-Q", "- Q", "-- q", "- q", or "-q" line) in the current session's chat-log file. Use when the user says "address the queued items", "process the queue", "work through the queued prompts", or similar. ALSO use right after finishing any task cleanly, before ending the turn — checking the queue is part of "done", not a separate ask.
---

Using CURRENT session's chat-log filename (injected each turn), run:

```
bash "$HOME/.claude/hooks/dequeue-prompt.sh" "<current chat file>"
```

(Flushes your just-finished reply first, then dequeues — keeps ordering correct across multiple items in one turn, since Stop only fires once at the true end.)

Prints a queued prompt → that's your next task, work it. Finishes cleanly → run SAME command again. Loop — dequeue, work, repeat — until it prints nothing (empty).

Dequeued task hits issues → stop loop, resolve, get user's explicit OK before resuming.

Don't hand-edit the chat file to move/strip queued blocks — script does rename/strip/move atomically; manual edit risks corrupting block structure.

## If you don't run it yourself

Nothing forces the loop above mid-turn — it's your own choice. Two backstops catch a
non-empty queue at turn end, but they're recovery, not the primary path: `on-stop.sh`
dequeues the next item the instant the turn ends; `on-prompt.sh` reports what got
dequeued on the user's next prompt.

A Stop hook `decision:"block"` was tried to force same-turn looping — confirmed to never
work in this Claude Code version (see `on-stop.sh`'s `check_queue_block` comment). There
is no mechanical same-turn enforcement; only next-turn recovery.

Reading/discussing a queued marker's content is not the same as dequeuing it. Applies
even outside a normal turn — e.g. during plan mode, where the script can't run at all.
