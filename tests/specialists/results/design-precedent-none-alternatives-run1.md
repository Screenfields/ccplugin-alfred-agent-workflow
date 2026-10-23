**Pass**

Precedent: none declared — the note declares none.

Real alternatives: yes — The note lists A (`--json` flag) and B (`list-json` subcommand), and B is viable. It is dismissed only because "B needs a helper first", which is a cost of building it. It is not a defect of B. B's own advantage, that the text output cannot regress, is not weighed against A. This goes to the owner for architectural review (AP-ADR0035 item 2).

**Blockers**

None. The design matches the work item's three behaviours and its bounds: only `list`, no `--format`, no sorting.

**Nits**

1. Argument handling is under-specified. The note says:
   > `cmd_list` tests whether its first argument is `--json`.

   It does not say what `list --jsn`, `list foo` or `list x --json` do. As written they silently print text, so a script that mistypes the flag gets TSV where it expects JSON. A builder should be told whether unknown arguments are ignored or rejected.

2. A failed fetch may look like an empty result. The source has `items=$(gh api ... | jq ...)`. I can't see whether `set -o pipefail` is on. If it isn't, a failing `gh` leaves `$items` empty. Then `jq .` prints nothing and exits 0, which is not `[]`. Criterion 3 only holds for "no open items", not for an API error. The design should state the failure behaviour.

3. The tests' harness is not described. The quoted source ends with a top-level `case` that dispatches on `$1`. The note says the tests "run `cmd_list` with a stubbed `gh`", but not how: by sourcing the script, or by running it with `gh` on a stubbed `PATH`. Sourcing would trigger the dispatch and `usage`. The "no flag" test should also assert the exact current tab-separated text, because criterion 2 says "exactly".

4. The listed con of A is weak:
   > every later subcommand that wants JSON needs its own flag.

   That is speculative and outside scope. A real con is that `--json` becomes a one-off if a `--format` option comes later, and `--format` is explicitly out of scope.

5. The note does not mention that the call uses `per_page=100` with no pagination. With more than 100 open items, "one JSON array of the open items" is truncated. The `jq length` check in the expected effect would still pass, because it compares against what the API returned. This is existing behaviour, but the JSON form makes it more visible. Also, the `issues` endpoint returns pull requests too.

6. The expected effect says "three more passing tests", which assumes the current test count and file. That is fine as a delta, but state the baseline.

**Could not verify**

- I could not read the repo, so `bin/alfred-workitem` is checked only against the quoted excerpt. That includes whether `pipefail` is set, how `REPO` is defined, and the rest of the file.
- The existing contents of `tests/workitem.bats` and the stub conventions are unread.
- I did not check issue #162 itself beyond the quoted text.
