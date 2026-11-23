# alfred-test-run --print-lines

Baseline for the `--print-lines <text>` flag of `bin/alfred-test-run` (CCW-249). The motion lead needs
one marker line (`e2e summary: ...`) from the log of passed builds, and the job log path already holds
the token, scope and endpoint for it.

## Behaviour

- The match is a fixed string, case sensitive, on the cleaned log (escape sequences and control
  characters removed). It is not limited to the last 50 lines the failed-job tail shows.
- Output is `<job name>: <line>` per matched line. It comes after the failed-job log tails and before
  `state:`. Without the flag the output and the exit codes are unchanged.
- States: matching runs for script jobs in `passed`, `failed`, `timed_out` or `broken`. A script job in
  any other state prints `<job name>: print-lines: not read (state <state>)` and gets no log request.
- A job with no match prints `<job name>: print-lines: no match`; a log that cannot be fetched prints
  `<job name>: print-lines: log unavailable`. No job is silent, and the exit code never changes.
- Cap: at most 20 lines per job (the first 20), then the note
  `<job name>: print-lines cap of 20 reached, more lines match`. At most 200 matched lines per run; at
  that point the line `print-lines: total cap of 200 reached, later jobs not matched` is printed once
  and later jobs are not matched (their failed tails still print).
- Line length: each matched line is scrubbed whole first, then cut to 500 characters (the job prefix
  not counted) with ` [cut]` appended. The cut never comes first: cutting before the scrub could leave
  a token prefix that no longer equals the token.
- Input: the value is one non-empty line, no control characters, at most 300 characters, given once.
  Each violation is exit 2 at parse time, before any network call.

## Two phases and the budget

Phase 1 is the failed-log loop as before: up to 5 failed jobs, each log fetched once, the 50-line tail
printed. With the flag, each raw log fetched there is kept in a shell variable (never a file). Phase 2
matches every job in build order. It uses the kept log when phase 1 fetched one, and a failed job
whose tail fetch failed is not fetched again. Every other log is fetched once. Each variable is
cleared after its job is matched. All of it runs inside the one `REPORT_CAP` budget (default 120 s);
a used-up budget makes the remaining jobs `log unavailable` without a request.

## Secrets

Raw logs live only in shell variables. The script uses no heredoc and no here-string. Every matched
line goes through the same `scrub` as all other output before it is cut. No token, scope or endpoint is
added: the log of a passed job uses the same call as a failed one.

## Limits

The design assumes logs of a few MB (a motion-visual-tests build has 2 jobs, each under 1 MB). There is
no log size guard; `REPORT_CAP` is the time brake.
