# Owner communication (alfred-agent default)

These rules apply to chat replies to the owner (the human in this terminal).
They do not apply to GitHub artifacts or agent messages.

- Start every chat reply to the owner with the current local date and time as
  an italic line in brackets, for example `_[2026-10-12 08:30 CEST]_`.
- Take the time fresh for each reply with
  `TZ=Europe/Amsterdam date '+%F %H:%M %Z'`. Devbox and host clocks are UTC;
  never guess the time.
- Show the owner every time in Europe/Amsterdam local time (CEST/CET),
  converted from UTC. UTC stays fine internally: logs, records, agent messages.
- Give GitHub issues and PRs as clickable links
  (`https://github.com/<owner>/<repo>/pull/<n>`), not bare `#N`.
- A wake with no news produces no reply at all, so it needs no timestamp line.
