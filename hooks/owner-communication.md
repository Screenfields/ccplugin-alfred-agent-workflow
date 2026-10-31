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
  host clocks are UTC.
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
  1. Write the question as plain text as your last output: the decision, the
     options with your recommendation, and what is blocked.
  2. If it blocks you and a written question is not enough, send
     `hub` an `[owner-join] <project>: <decision>` message
     (Decision, Options, Blocked, Session). The hub brings it to the owner.
  3. Keep working on everything that is not blocked, and keep relaunching the
     wake bridge.
- Once the owner decides, record it on the issue or PR in English. If you
  sent an owner-join, also send the hub `[owner-join] resolved: <decision>`.
