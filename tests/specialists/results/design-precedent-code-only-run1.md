**Fail**

Precedent: invalid — the link points to `bin/alfred-config`, which is code. It is not an accepted ADR under `docs/adr/` or `docs/decisions/`, and it is not a baseline doc under `docs/baseline/`. Code counts only when a baseline doc describes it, and the note cites no such doc. The brief carries the passage, "# names [--json]: print the config keys, as a JSON array with --json". That passage is a comment in a script. The repo and the link are not available in this session, so I checked the passage as carried and could not read it at source.

Real alternatives: no — the note lists three alternatives. Two are dismissed because the work item puts them out of scope, and that holds. The third, quoting tabs inside titles, is dismissed on a reason that holds: every script would have to undo the `@tsv` escapes. Nothing viable is missing inside the bounds. Because the precedent is invalid, the item goes ahead and its design is recorded in a baseline doc (AP-ADR0035 item 7).

**Blockers**

1. The precedent is invalid, as above. The note has to either cite an accepted ADR or baseline doc whose passage covers a `--json` flag on a subcommand, or declare `Precedent: none declared`. The `none declared` route is not a blocker on its own.

**Nits**

1. The argument handling is under-specified. The note says "`cmd_list` tests whether its first argument is `--json`", but it does not say what happens when:
   - `--json` is not the first argument, for example `list foo --json`.
   - There is an unknown argument, for example `list --foo`.

   Today `cmd_list` ignores all arguments. A builder needs to know whether to keep ignoring them (silently printing text) or to reject them. Acceptance criterion 2 only covers the no-flag case.
2. The test approach does not say how `cmd_list` is reached from `tests/workitem.bats`. The script ends in a `case "${1:-}"` dispatcher that runs on load. The note says the tests "run `cmd_list` with a stubbed `gh`". It does not say whether that means sourcing the script, which would trigger `usage`, or invoking `alfred-workitem list` with a stub `gh` on `PATH`. Name the mechanism.
3. The "no flag" test needs to pin the exact current output, as criterion 2 requires ("exactly the text it prints today"). The note should say the expected text comes from the current `jq -r` line, in tab-separated order `number, state, title`.
4. The expected effect, "`jq length` equals the number of open issues the API returned", is measurable. It is weak, though, because it compares the output with itself. The bats tests with fixed fixtures are the real check.
5. The first alternative's rejection reason also cites "the array is already built as JSON inside `cmd_list`". That is an argument for the chosen design, not against quoting. The first half of the reason ("every script would have to undo the `@tsv` escapes itself") is enough.

**Claims I could not verify**

- The repo, `bin/alfred-workitem` and `tests/workitem.bats` are not in this session, so I checked the `cmd_list` and dispatcher claims only against the source quoted in the brief. On that quote they match: the `jq 'map({number, title, state})'` array, the `@tsv` line, and `cmd_list "$@"`.
- I could not check that `tests/workitem.bats` exists or how it stubs `gh` today.
- I could not check the `@tsv` escaping behaviour in the problem statement against the repo. It matches standard jq behaviour.
- I could not check the claim that `bin/alfred-config` has that `names [--json]` comment, or what it does.
- `per_page=100` caps the output at 100 items. The note does not mention this, and neither does the work item. It is not new in this design.
