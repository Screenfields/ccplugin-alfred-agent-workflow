**Pass**

Precedent: none declared — the note carries `Precedent: none declared`.

Real alternatives: yes — The note lists A (a `--json` flag) and B (a `list-json` subcommand). Both would meet the acceptance criteria. B is dismissed only on effort:

> Recommendation: A, because the array is already built in `cmd_list` and B needs a helper first.

That reason does not rule B out. B's stated advantage also goes unanswered:

> `list` and its argument handling stay untouched, so the text output cannot regress.

Neither does A's stated cost:

> every later subcommand that wants JSON needs its own flag.

The choice sets how scripts ask for JSON across the CLI, and no precedent covers it. The item goes to the owner for architectural review (AP-ADR0035 item 2).

**Blockers**

None. The design supports the work item:
- The "Current state" claims match the quoted source. `cmd_list` builds `map({number, title, state})`, prints it with `@tsv`, and never reads its arguments.
- The problem claim is correct. `@tsv` escapes tab, newline and backslash in titles.
- `jq .` on `[]` prints `[]`, which meets AC3. The text path is untouched, which meets AC2.
- Sorting and `--format` are excluded, as the bounds require.

**Nits**

- The test plan says "run `cmd_list` with a stubbed `gh`". The script ends with a `case` dispatch that calls `usage` when there is no argument. A test that sources the file would hit that. The note does not say whether tests call the script as `bin/alfred-workitem list [--json]` with `gh` on `PATH`, or source it. A builder will have to decide, and `$REPO` also needs setting.
- The "no flag" test should assert the exact tab-separated output, `number<TAB>state<TAB>title`. AC2 says "exactly the text it prints today", and "no flag" alone does not say what is asserted.
- `--json` is recognised only as the first argument. Say whether `list --json extra` is accepted and whether an unknown first argument is still ignored, as it is today.
- `repos/$REPO/issues` also returns pull requests, and `per_page=100` has no pagination. Both are existing behaviour. The expected-effect line says "open issues the API returned", so it holds, but the JSON will contain PRs and at most 100 items.

**Claims I could not verify**

- I had no repo access. I checked the "Current state" claims only against the quoted `bin/alfred-workitem` excerpt. I did not check the rest of the file, `tests/workitem.bats`, how `usage` and `$REPO` are set, or whether other callers parse the TSV output.
- I could not confirm that bats can stub `gh` the way the note describes.
