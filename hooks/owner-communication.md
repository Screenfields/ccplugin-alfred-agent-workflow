# Owner communication (alfred-agent default)

These rules apply to chat replies to the owner (the human in this terminal).
They do not apply to GitHub artifacts or agent messages.

- Every owner prompt arrives with an injected line, `Owner prompt received at
  _[2026-10-12 08:30 CEST]_`. Start your chat reply to the owner with that
  time line. If the turn runs longer than a few minutes, take a fresh time
  with `TZ=Europe/Amsterdam date '+%F %H:%M %Z'` instead. Devbox and host
  clocks are UTC; never guess the time.
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
- A wake with no news produces no reply at all, so it needs no timestamp line.

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
