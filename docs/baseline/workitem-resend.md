# Work item mark re-send (24 h)

Baseline record for CCW-255 (version 2.54.1). The spec and its design review are the issue
https://github.com/Screenfields/ccplugin-alfred-agent-workflow/issues/255 and its design comments
(AP-ADR0035 item 7: the design is recorded here in short form). The code is the source of truth:
`bin/alfred-workitem` (`stamp_due`, `stamp_write`, `read_mark_item`, `resend_due`).

## Problem

The agent-run store attributes a request to the latest `work_item` marker at or before the request,
within a 7-day lookback. `alfred-workitem` sent a session's marker at `mark` and at `SessionStart`
(resume) only. A session that ran longer than 7 days without a resume dropped out of the window, its
requests counted as unattributed and `AgentRunsWorkItemDeviation` fired on a valid mark file. The
lookback cannot be widened on the store (monitoring#70 memory growth).

## Rule

On `UserPromptSubmit`, when the mark file holds a non-empty valid item and the last acknowledged send is
more than 86400 s (24 h, `RESEND_EVERY`) old, the hook re-sends the marker inline (`POST_TIMEOUT` 2 s).
It prints nothing and always exits 0, so no model turn or token is spent. Same-item re-sends are
idempotent on the store and re-anchor later requests. There is no entrypoint or role gate: long
non-interactive sessions need the keep-alive too.

An empty item is never re-sent in this path. The store reads an empty `work_item` as an explicit clear,
so a re-send of a cleared mark would be a second clear, not a keep-alive. An unreadable mark file or an
item the store would reject sends nothing either. (The `SessionStart` resume send of an empty item is
unchanged.)

## The stamp: `<session_id>.resend`

One integer, epoch seconds, in the state dir beside the mark file. Three states:

| State | Meaning |
|---|---|
| value `T` | the last acknowledged send of a non-empty marker, at `T`. Due when `now - T > 86400`. |
| value `now-82800` | retry reference, written after a failed hook send: due again after one hour (`RESEND_RETRY` 3600). Not an acknowledgement; CCW-153 must tell the two apart. |
| absent | due once (a session marked before the upgrade, or a refused `mark`), then stamped. |

Missing, corrupt (anything but 1 to 12 digits, read with the builtin `read`, forced to base 10) and
future values count as due, and are rewritten as a plain integer. A stamp that cannot be recorded (the
path is not a regular file, or a temp file cannot be written beside it) sends nothing: it could not be
throttled, so the send would repeat on every prompt. Writes go to a temp file and `mv -fT`.

Written after each accepted send of a non-empty marker: `mark <item>`, `SessionStart` resume, the
re-send. `mark none` removes it. A refused `mark <item>` removes it, so the kept mark is due at the next
prompt (requests are being misattributed now). After a failed hook send the store still holds a marker
less than 24 h old, inside the lookback, so the retry is throttled to one hour instead.

`mark` also removes stamps unused for 90 days (never the current session's) and temp files older than a
day.

## Why a separate stamp file

A field in the mark file would make the re-send rewrite the mark file and race `mark`, and the mark
file's mtime feeds the 90-day cleanup and is touched on every hook event, so it is no "last send" time.
The stamp file follows `remind_due` (`<sid>.prompts`).

## Store facts relied on

7-day marker lookback; latest marker wins; same-item re-send idempotent; empty `work_item` clears; the
compactor runs every 300 s.

## Out of scope

Store changes, the lookback, a detached send, the unacknowledged-mark re-mark at `SessionStart`
(CCW-153), the `hooks.json` timeouts (`UserPromptSubmit` stays 5).
