**Fail**

Precedent: invalid — the design note has no `Precedent:` line. The step-4 rule makes a missing line an invalid precedent, whatever the design's merit.

Real alternatives: yes — the note lists two viable options. A is a `--json` flag on `list`. B is a new `list-json` subcommand. B is dismissed only because "B needs a helper first", and that is a cost, not a barrier. The recommendation of A rests on size, which is a judgment call between two workable designs. This item goes to the owner for architectural review (AP-ADR0035 item 2). It does not go ahead on a baseline doc.

**Blockers**

1. No precedent line. The note has no line starting `Precedent: `. It needs either `Precedent: <link> | "<passage>"` pointing at an accepted ADR or baseline doc, or `Precedent: none declared`. Declaring none leads to the owner review above.

2. The test mechanism cannot be built as written. The note says:
   > Three new tests in `tests/workitem.bats` run `cmd_list` with a stubbed `gh`…

   The source ends with a top-level `case "${1:-}" in … *) usage ;; esac`. Sourcing the file to call `cmd_list` directly would run that dispatch and hit `usage`. The note doesn't say how `cmd_list` is reached in tests. It could be a source guard, running the script as `alfred-workitem list --json` with `gh` on `PATH`, or something else. Acceptance criterion 4 depends on this, and a builder would have to ask. I could not read `tests/workitem.bats`, so I can't tell whether it already has a pattern for this.

**Nits**

- **Failure behaviour is not stated.** In `items=$(gh api … | jq …)`, a failing `gh` does not fail the pipeline unless `pipefail` is set. With `--json`, a script could then get empty output and exit 0, which is neither `[]` nor an error. A machine-readable form should say what happens when the fetch fails.
- **Arguments other than `--json` are not specified.** Today `list foo` is silently ignored. The note says only "first argument is `--json`". It doesn't say what `list foo --json` or `list --json foo` do.
- **The expected effect is partly circular.** `jq length` "equals the number of open issues the API returned" compares the output with the same fetch. The URL also has `per_page=100` and no pagination, so for more than 100 items "open issues" and "returned" differ. Say the effect is bounded to the first page, or test it against the stub's fixed array.
- **The problem statement is slightly off.** jq's `@tsv` also escapes carriage return (`\r`). The note lists only tab, newline and backslash. This doesn't change the design.
- **The `/issues` endpoint also returns pull requests.** That is existing behaviour and out of scope, but "open items" in the JSON contract inherits it. You could say so in one line.

**Claims I could not verify**

- The repo was not available to me, so I checked the claims about `cmd_list` and the `case` dispatch only against the quoted source. They match: the array is `{number, title, state}`, and `cmd_list "$@"` receives arguments it doesn't read.
- I did not check that `tests/workitem.bats` exists, what stubbing pattern it uses, or whether it already covers `list`.
- I did not check that `jq .` on `[]` prints exactly `[]`. I expect it does.
