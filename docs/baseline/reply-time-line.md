# Reply time line (idle gate)

Baseline record for CCW-180 part one, version 2.39.0. The design, with its
review, is the issue comment
https://github.com/Screenfields/ccplugin-alfred-agent-workflow/issues/180#issuecomment-6548572206
(lead's notes: https://github.com/Screenfields/ccplugin-alfred-agent-workflow/issues/180#issuecomment-6548572464).
This file records the result in short form (AP-ADR0035 item 7). The code is the
source of truth: `lib/reply-time.sh` holds the gate and the state functions,
`hooks/reply-timestamp.sh` and `hooks/stop.sh` call them.

## Rule

A reply starts with the Europe/Amsterdam time line only when a new set of
actions starts: the first turn after the session was idle for
`reply-time-idle-minutes` (15, in `config/thresholds.json`) or more. The model
cannot measure idleness, so the `UserPromptSubmit` hook decides and injects the
line; the model stamps the first reply of a turn if and only if a line was
injected for that turn. A Stop block reason never carries a line.

## State file

`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/alfred-reply-ts/<session_id>.json`, one per
session, written to a temp file and moved. The session id is sanitised as in
`bin/alfred-loop-check` (every character outside `A-Za-z0-9._-` becomes `_`).
Epochs and flags only, never prompt or reply text. Files older than a day are
pruned when a session's file is first created. Epochs are whole seconds from
1000000000 to 9999999999; anything else counts as unusable state.

| Key | Written by | Meaning |
|---|---|---|
| `last_prompt` | prompt hook | epoch of the latest non-worker prompt |
| `line_at` | prompt hook | epoch of the latest injection; absent until one was made |
| `open` | both | `true` after a prompt, `false` after a Stop |
| `last_stop` | `stop.sh` | epoch (its start clock) of the latest Stop |
| `stop_nonempty` | `stop.sh` | whether that Stop's final message was non-empty |
| `last_activity` | `stop.sh` | `last_stop` of the latest Stop with a non-empty final message |

`injected` and `flagged` are reserved for CCW-184 (the Stop audit) and neither
read nor written here. Every write merges into the stored object, so keys of
other writers survive.

## Gate rule

With T = `reply-time-idle-minutes` x 60 seconds, the hook emits when
`last_activity` is absent or `now - last_activity >= T`, and not when a turn is
open and `now - line_at` is in 0 to T-1 (a mid-turn wake). The gap is in whole
seconds. The hook reads the clock once per run; that reading is the gap's
"now", the stored time and the stamp. The gate never looks at the wake type.
When it cannot decide (no state, unreadable or garbage state, a directory, no
session id, unreadable threshold, unwritable state directory, last activity in
the future, an epoch out of range) it emits the line, and at most one line goes
to stderr. `ALFRED_ROLE=worker` emits nothing, reads nothing and writes nothing.

## Stop record

At every Stop of a non-worker session with a session id (allowed, blocked, and
`stop_hook_active` true), `stop.sh` records its clock reading, taken before any
part runs, and whether `last_assistant_message` held a non-whitespace
character. Only a non-empty final message moves `last_activity`, so a wake with
no news does not use up the line. Cost on an allowed Stop: at most 50 ms
(measured in the PR).

## Debug log

`ALFRED_REPLY_TS_LOG` lines: `{ts, source, entrypoint, owner, emitted, gap}`;
`gap` is seconds, `null` with no state.

## Known limits

- A turn that opens without a line and runs long can get a line mid-turn when a
  wake arrives at or after the threshold; suppression keys on the injection.
- An interrupted turn leaves no Stop and stays open; a prompt less than T after
  its injection gets no line, one at T or more does.
- A blocked Stop is recorded, so `open` is `false` while its Stop-hook continuation
  still runs (no prompt hook fires for it). A wake during that continuation, after
  a blocked Stop whose final message was empty, is gated as a new turn and can get
  a second line.
- Whether the model puts the line on the first reply only is not checked by the
  hooks. The live script reports the reply text; the lead's canary judges it.
- The state is merged without a lock. Two windows (the merge, about 20 ms; gate
  read to prompt write, about 107 ms median) need a second writer of the same
  session; the effect is one extra or one missing line.
