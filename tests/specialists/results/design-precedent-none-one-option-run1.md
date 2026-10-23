**Pass**

Precedent: none declared — the note's line reads:
> Precedent: none declared

Real alternatives: no — the work item fixes the bounds: `--format` and a new subcommand are out of scope, and AC2 forbids changing the default text. The note dismisses the `--format` option and the new subcommand with reasons that hold, because the work item excludes both. It dismisses the "quote tabs in titles" option because every script would have to undo the escapes itself. That reason also holds, though it is weakly worded (see nits). A flag on `list` is the only option left inside the bounds.

**Blockers**

None.

I checked the claims about the current state against the quoted source of `bin/alfred-workitem`:
- `cmd_list` builds `jq 'map({number, title, state})'` into `$items`, then prints it with `jq -r '.[] | [.number, .state, .title] | @tsv'`. This matches the note.
- `list) shift; cmd_list "$@"` passes the arguments, and `cmd_list` reads none of them. This matches the note.
- `jq .` on `[]` prints `[]`, so AC3 holds.
- `jq .` on the array gives `number`, `title` and `state` per item, so AC1 holds.
- Leaving the existing `jq -r` line unchanged keeps AC2.

**Nits**

1. The tests are underspecified. The note says the tests "run `cmd_list` with a stubbed `gh`". In the quoted source, the `case "${1:-}"` dispatch sits at file level, below `cmd_list`. Sourcing the file for the tests would therefore run `usage` (or exit). `$REPO` is also not set in the quoted part. The note should say how the tests call `cmd_list`. The options are a source guard, or running `bin/alfred-workitem list --json` with a `gh` stub on `PATH`.
2. Behaviour is unspecified when `--json` is not the first argument, or when there is an unknown argument. The note says "tests whether its first argument is `--json`". Today such arguments are ignored. The note should say that this stays the same.
3. The first dismissed alternative is worded loosely. "Keep the text output and quote tabs" is close to the status quo, not a distinct design. The stated reason still holds.
4. `per_page=100` with no pagination means "all open items" is really "the first 100". The issues endpoint also returns PRs. Both are existing behaviour and out of scope. The expected-effect line ("number of open issues the API returned") is accurate as written, so this is only worth a mention in the baseline doc.

**Could not verify**

- The rest of `bin/alfred-workitem`: `usage`, how `REPO` is set, and any source guard.
- The existing `tests/workitem.bats`: its stub conventions, and whether `cmd_list` can already be invoked from it.
- The quoted source is the only evidence for the state claims. I had no repo checkout, so I did not check them against the repo or GitHub.
