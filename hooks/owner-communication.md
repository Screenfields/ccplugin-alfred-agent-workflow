# Owner communication (alfred-agent default)

These rules apply to chat replies to the owner (the human in this terminal).
A reply to a wake turn is still a chat reply the owner reads (for example
through Remote Control), so they apply to it too. They do not apply to GitHub
artifacts or agent messages.

- A reply starts with the time line only when this turn's context carries an
  injected `Time now` line (a new set of actions), for example
  `Time now _[2026-10-12 08:30 CEST]_`. The hook injects it on the first turn
  after the session was idle for `reply-time-idle-minutes` or more, whether the
  turn started with your message or with a wake. Start the first reply of that
  turn with the injected time line. Otherwise a reply carries no time line:
  replies later in the same set of actions get none. The time to use is the
  injected one, or a fresh `TZ=Europe/Amsterdam date '+%F %H:%M %Z'` reading
  when the turn runs longer than a few minutes, never a guessed one. Devbox and
  host clocks are UTC. The time line is the injected value of this turn, or a
  fresh `TZ=Europe/Amsterdam date '+%F %H:%M %Z'` reading no older than the
  tolerance (`reply-time-tolerance-minutes`) when the reply is written; never
  estimated, extrapolated or carried over from an earlier turn or reading. A
  Stop-hook check compares the time line with the clock and flags a wrong one
  once per turn.
- Show the owner every time in Europe/Amsterdam local time (CEST/CET),
  converted from UTC. UTC stays fine internally: logs, records, agent messages.
- Link every GitHub record (issues, PRs, commits, runs, releases, files) with
  its full URL; never a bare `#N` or ID.
  - In the terminal (lead chat does not render markdown links): a short label
    plus the bare full URL, e.g.
    `PR #122 https://github.com/Screenfields/metis/pull/122`. Never the
    `[text](url)` form there; it shows literally.
  - Where markdown renders:
    `[metis#122](https://github.com/Screenfields/metis/pull/122)`, the short
    record name as text and the full URL as target.
- A wake with no news produces no reply at all.
- A turn that exists only because a Stop hook or a wake required it ends with
  no text, or a one-line status, when nothing changed for the owner. The status
  never restates a parked question.

## Asking the owner something

A menu question (the AskUserQuestion tool) blocks the whole session until the
owner answers in this terminal. While it is open, no wake gets through and
your inbox stalls, possibly for hours (alfred-platform#917).

- Use a menu only when the owner is typing in this conversation right now: the
  turn started with their own message, not a wake, a background-task
  notification or an agent message. `/alfred-agent:waiting` and other
  walkthroughs the owner started are fine.
- Everywhere else (wake turns, autonomous work, an owner who has gone quiet),
  never open a menu. Instead:
  1. Park it at once on the item it blocks (file one first when none exists):
     a comment on the item plus the waiting label, whose name you read with
     `alfred-config get waiting-label`, so `/waiting` finds it. Parking takes
     the whole item out of the actionable set, even when the question blocks
     only part of it (the Escalate paragraph of `agreement/lead.md`). A
     question that blocks nothing is a comment on the item, with no label. A
     question relayed through `[owner-join]` is parked on the item the
     owner-join names, and one that names no item gets one filed first.
  2. Write the question as plain text as your last output: the decision, the
     options with your recommendation, and what is blocked.
  3. If it blocks you and a written question is not enough, send
     `hub` an `[owner-join] <project>: <decision>` message
     (Decision, Options, Blocked, Session). The hub brings it to the owner.
  4. Keep working on everything that is not blocked, and keep relaunching the
     wake bridge.
- Ask once, in every turn, whoever started it:
  - Never repeat a pending question in a later reply. A changed question is
    stated once, as the change.
  - A menu the owner dismisses without answering counts as asked: park it as in
    the steps above.
  - A parked question comes back only through `/waiting`, or when the owner asks
    for the open points. On that request, run the `/waiting` gather step instead
    of listing them from memory.
  - Urgent requests under AP-ADR0031 are the one exception: they keep ending
    every reply of the sending session, as `/waiting` describes.
- Once the owner decides, record it on the issue or PR in English. If you
  sent an owner-join, also send the hub `[owner-join] resolved: <decision>`.
