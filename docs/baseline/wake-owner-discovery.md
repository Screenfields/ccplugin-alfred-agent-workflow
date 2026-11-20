# alfred-wake owner discovery

Baseline record of how `alfred-wake` finds the Claude Code process that owns a
wait (CCW-239). The rule itself is in the header of `bin/alfred-wake`, in the
Owner paragraph. This doc holds the why and the alternatives. It does not repeat
the rule, so the rule has one home. The code is `find_owner` and
`owner_versioned` in `bin/alfred-wake`.

## Who uses owner discovery

- `take_over` calls `find_owner` and writes the result to `alfred-wake.owner`.
- `owner_check` reads that file for `status` and `status --json`. It never
  looks at the process name again.
- The hooks (`bridge-check.sh`, `session-check.sh`, `session-nudge.sh`) read
  only the exit code of `alfred-wake status`.

## Why the nearest ancestor

The owner is the process whose death ends the session. In daemon mode that is
the session process, the child of `claude bg-pty-host`. The nearest ancestor
that matches is that process. If the pty host dies, its child dies too. If the
pty host outlives a crashed session, only the nearest rule sees the orphan.
So the nearest ancestor is right whichever process lives longer.

## The match rule

The exact rule is in the header of `bin/alfred-wake`. For an ancestor whose comm
is a version, there are three outcomes:

- The exe is readable and has the expected path: it is the owner.
- The exe is readable and has another path: it is passed over, and the walk goes up.
- The exe is unreadable: there is no owner, and the walk stops. Climbing could
  skip the session process and record a higher one, which is a false "armed".

An explicit `ALFRED_WAKE_OWNER_COMM` is exact and applies alone. The bats setup
relies on that to keep a real `claude` ancestor from becoming an owner in tests.

## Alternatives

- **argv[0] or cmdline:** spoofable, because `exec -a` changes argv[0] only, so comm and exe stay different.
- **A cached owner:** goes stale on a revive, when the session process is replaced.
- **Exe alone:** weaker than exe plus comm, and it would take any process started from that path.
- **Matching `bg-pty-host`:** that is the topmost rule, which gives a false "armed", and it couples the matcher to a subcommand name.
- **Topmost:** the same false "armed" when the pty host outlives the session.
- **An override that adds to the defaults:** it breaks the test isolation and the meaning of an explicit value.
- **A separate test opt-out variable:** not needed, because the exact-only override already isolates the tests.
