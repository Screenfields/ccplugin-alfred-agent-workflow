# Reply time line (idle gate)

Baseline record for CCW-180 part one (version 2.39.0) and the stamp audit of
CCW-184 (version 2.40.0, see "Stamp audit" below). The design of CCW-180, with its
review, is the issue comment
https://github.com/Screenfields/ccplugin-alfred-agent-workflow/issues/180#issuecomment-6548572206
(lead's notes: https://github.com/Screenfields/ccplugin-alfred-agent-workflow/issues/180#issuecomment-6548572464).
This file records the result in short form (AP-ADR0035 item 7). The code is the
source of truth: `lib/reply-time.sh` holds the gate and the state functions,
`hooks/reply-timestamp.sh` and `hooks/stop.sh` call them. The design of CCW-184 is
the issue comment
https://github.com/Screenfields/ccplugin-alfred-agent-workflow/issues/184#issuecomment-6548903861
and its review the next comment.

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

The stamp audit (CCW-184) adds two keys, `injected` and `flagged`; see "Stamp
audit" below. Every write merges into the stored object, so keys of other
writers survive.

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
no news does not use up the line.

The record runs as a background child started right after the clock reading, in
parallel with the bridge and loop parts (design lever C2), and `stop.sh` waits
for it before any output, so it adds close to no wall time (bound: 50 ms on an
allowed Stop, measured in the PR). The child ignores TERM, INT and HUP and
`on_signal` waits for it instead of killing it, so a signalled Stop leaves no
half-written `*.json.tmp.*` file and still prints the bridge answer. The wait is
bounded (10 polls of 0.1 s, about 1 s, for a `rec.done` marker the child writes
last, because `wait` has no time limit). A record still unfinished then is left to
finish by itself after `stop.sh` has exited; if the input file it still had to
read is gone by then, that Stop is not recorded and the gate sees the older state
(at worst one extra or one missing line). Only SIGKILL could leave a temp file; a
day-old one is pruned when a session's file is first created. `stop.sh` also waits
for the record before it starts the audit, so the audit's flag write and the
record's write of the same file never overlap.

## Stamp audit

`hooks/reply-audit.sh` is the third part of the Stop entry (run last by `stop.sh`
with its own 1 s limit, and `--now <epoch>`, the clock `stop.sh` read before any
part ran). When the final reply starts with a stamp (`_[YYYY-MM-DD HH:MM CET|CEST]_`
or `Time now _[...]_`) that is in the future, or more than
`reply-time-tolerance-minutes` (2) behind both the clock and every time injected
this turn, it records `flagged:true` and blocks the Stop once, with the correct
time. Stamp and references are floored to the minute; a stamp ahead of the clock's
minute is flagged at any distance; exactly the tolerance off passes. It never asks
for a stamp: a reply without one, an empty reply, a worker and every failure of
the check are silent. `ALFRED_REPLY_TS_AUDIT=0` (exactly `0`) turns it off: the
audit reads nothing and `stop.sh` does not start it; the idle gate keeps working.
The audit's functions and the two keys are declared once, in `lib/reply-time.sh`.

| Key | Written by | Meaning |
|---|---|---|
| `injected` | prompt hook | epochs injected in this turn, newest 8 |
| `flagged` | prompt hook (clears), audit (sets) | a flag was issued this turn |

Restart rule. A non-worker prompt restarts `injected` (to empty) when the stored
`open` is `false`, that is, when a Stop has been recorded since the list was last
extended, injecting or not; the merge decides this from its own read of the file.
A prompt that injects then adds its epoch. A mid-turn prompt (`open` true) keeps
the list. Every non-worker prompt clears `flagged`. A Stop never changes the list,
and a passing or silent Stop leaves both audit keys as they were. `stop_hook_active`
is ignored: `flagged` is the only once-per-turn guard, written before the block is
printed, and if it cannot be written nothing is flagged.

Limits (also in the README):
- An interrupted turn (no Stop recorded) leaves its epoch in the list into the next
  turn, so a stamp carried over from it, within the tolerance, can pass.
- A Stop that blocks records `open:false` although the turn continues, so a prompt
  that arrives in that continuation restarts the list, and a stamp that uses the
  turn's first injected time can then be flagged. One flag per prompt, one short
  extra turn.
- A long turn may end with its first injected time, which the rule allows and the
  audit passes while it is in the list.
- Late-reading window: a time read at 07:20:58, stamped 07:20 and sent after
  07:23:00 can be flagged although it was true when read; bounded by the reply's
  generation time. The audit does not claim never to flag what the rule allows.
- A flag cut by the 1 s limit after `flagged:true` was written is spent and not
  reported: a lost flag, never a repeated one.

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
