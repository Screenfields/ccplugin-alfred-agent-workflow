**Pass**

Precedent: none declared — the note carries `Precedent: none declared`, so there is no link to check.

Real alternatives: no — The note lists three alternatives. The `--format` option and the new subcommand are rejected because the work item puts them out of scope, and that holds. "Keep the text output and quote tabs" is rejected with a reason that holds. A more direct reason also exists: changing the text output would break acceptance criterion 2. The success state names `list --json`, so the flag is the only form the work item allows. The item goes ahead and its design is recorded in a baseline doc (AP-ADR0035 item 7).

**Blockers**

None. I checked the claims about state against the quoted source:

> `cmd_list` in `bin/alfred-workitem` already builds the open items as a JSON array of `{number, title, state}` and then prints them as tab-separated text.

This matches the source. `$items` comes from `jq 'map({number, title, state})'` and is printed by `jq -r '.[] | [.number, .state, .title] | @tsv'`.

> `list` takes its arguments through `cmd_list "$@"`, and `cmd_list` reads none of them.

This matches the source. `list) shift; cmd_list "$@" ;;` is there, and `cmd_list` has no `$1`.

The design meets the acceptance criteria:
- **Criteria 1 and 3:** `jq . <<<"$items"` prints the array. For `[]` it prints `[]`.
- **Criterion 2:** the existing `jq -r` line is left untouched.
- **Criterion 4:** the three named tests map to the three behaviours.
- **Bounds:** no other subcommand, `--format`, or sorting is touched.

**Nits**

1. The note says the tests "run `cmd_list` with a stubbed `gh`", but the script ends in a `case` that runs `usage` when there are no arguments. A builder has to guess whether the tests source the script or run `bin/alfred-workitem list --json` with a stub `gh` on `PATH`. The note should say which.
2. "Tests whether its first argument is `--json`" leaves open what happens with `list foo --json` or `list --json extra`. Today extra arguments are ignored. The note should say that only the first argument counts, so the builder doesn't have to decide.
3. The expected effect says `list --json | jq length` equals "the number of open issues the API returned". The `issues` endpoint also returns pull requests, and `per_page=100` caps the result at 100 items. Both behaviours already exist and are out of scope. The note should say the check is against the API response, not the repository's open-issue count, so it doesn't read as a claim about the repository.
4. The `@tsv` problem statement doesn't affect the design. A short note that the text output keeps its escapes by design, because of criterion 2, would remove any doubt.

**Claims I could not verify**

- I could only read the quoted `list` part of `bin/alfred-workitem`. I did not see the rest of the file (`usage`, `REPO`, the other commands) or `tests/workitem.bats`. How the existing tests invoke the script, and whether a `gh` stub already exists, are unchecked.
- I did not check that issue #162 matches the quoted work item.
- I did not check what the GitHub API returns for the `issues?state=open` call. That includes the pull-request and pagination behaviour in nit 3.
