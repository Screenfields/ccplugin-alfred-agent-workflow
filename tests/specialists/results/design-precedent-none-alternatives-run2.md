**Pass**

Precedent: none declared — the note says `Precedent: none declared`, so no link or passage needs checking.

Real alternatives: yes — the note lists two options, A (`--json` flag) and B (`list-json` subcommand). B is viable, and the issue's own bounds make the way a script asks for JSON an open choice: "the `list` subcommand and the way a script asks for the JSON form". B's dismissal reason is only cost:
> Recommendation: A, because the array is already built in `cmd_list` and B needs a helper first.

A missing helper is a small amount of work, not something that rules B out. B's own advantage is that `list` stays untouched, which protects acceptance criterion 2, and the note never answers it. The item therefore goes to the owner for architectural review (AP-ADR0035 item 2), not straight to a baseline doc.

**Blockers**

None. I checked the claims about state against the quoted `bin/alfred-workitem`:
- `cmd_list` builds `{number, title, state}` with `jq 'map({number, title, state})'`.
- It prints with `jq -r '... | @tsv'`.
- `list) shift; cmd_list "$@"` passes the arguments, and `cmd_list` reads none.

The note's claims about the current state hold. The design covers the three behaviours in criteria 1–3 and the three tests in criterion 4. The expected effect is measurable.

**Nits**

1. The test method is under-specified.
   > Three new tests in `tests/workitem.bats` run `cmd_list` with a stubbed `gh`…

   The quoted script runs its `case` dispatch at top level, so sourcing it to call `cmd_list` directly would run `usage` or exit. The note doesn't say how the tests load `cmd_list`. Options are a source guard, or running the script with a stub `gh` on `PATH`. It also doesn't say that the no-flag test must compare against the exact current TSV text, which criterion 2 requires.
2. Any argument other than `--json` is silently ignored.
   > `cmd_list` tests whether its first argument is `--json`.

   So `list --jsno` prints text without an error. The note should state whether that is intended.
3. The pagination limit goes unmentioned.
   > `jq length` equals the number of open issues the API returned.

   The fetch uses `per_page=100` with no pagination. With more than 100 open items, the array is not "one object per open item" (criterion 1). The expected-effect wording avoids this by saying "the API returned". The limit was already there, but the JSON form makes it matter to scripts.
4. The `issues` endpoint also returns open pull requests, so "open issues" in the expected effect may not match what `list` prints. I couldn't check this against the API here.
5. A's listed con (every later subcommand needs its own flag) argues against the recommended option, yet it isn't weighed in the recommendation.
6. Output is pretty-printed by `jq .`. That is valid JSON and fits the criteria, but `jq -c` would be the usual choice for a script. State which is intended.

**Not verified**

- The rest of `bin/alfred-workitem`: `usage`, how `REPO` is set, `set -e` behaviour, and whether the file can be sourced.
- The current `tests/workitem.bats`: how it stubs `gh` today, and whether it already tests `list`.
- The real API response: whether it includes pull requests, and the count of open items in the repo.
