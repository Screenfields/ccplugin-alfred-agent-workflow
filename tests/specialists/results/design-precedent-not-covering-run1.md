**Blockers**

1. The precedent is invalid. I could not read the link, so this is "passage carried, not read at source". The carried passage does not cover this work either.
   > Precedent: https://github.com/Screenfields/alfred-platform/blob/main/docs/adr/0038-retry-policy-for-github-calls.md | "Decision: A call to the GitHub API that fails with HTTP 5xx is retried up to 3 times with a pause of 2 seconds."

   The brief's passage says Accepted and sets a retry policy for failing GitHub calls. It says nothing about CLI output formats or flags on `list`, so it cannot be the precedent for adding `--json`.

2. The test plan does not pin down criterion 2, and its harness is unclear.
   > Three new tests in `tests/workitem.bats` run `cmd_list` with a stubbed `gh` that returns a fixed issues array: `--json` with two items, `--json` with none, and no flag.

   - **Criterion 2.** The "no flag" test names no expected output. Criterion 2 requires "exactly the text it prints today". The test must assert the exact tab-separated lines, in the order number, state, title. The design does not say it does.
   - **Harness.** The script ends with a top-level `case "${1:-}" in … *) usage ;; esac`. Calling `cmd_list` directly means sourcing the file, and sourcing runs that `case` and probably `usage`. The design does not say how the tests avoid this, for example by running the script as a process with a stub `gh` on `PATH`. A builder would have to guess.

**Nits**

- Alternative B is dismissed with "B needs a helper first". That is a weak reason, because the helper is a few lines. Its stated con is "two commands to keep in step", and that con is real. Its pro, that the text output cannot regress, is not weighed against A's risk.
- The design only tests `$1`. `list --json` works, but `list foo --json` silently prints text. State whether that is intended.
- The source uses `per_page=100` with no pagination. `--json | jq length` therefore equals the issue count only up to 100 items. The issues endpoint also returns pull requests. Both behaviours exist today. The "Expected effect" wording ("open issues the API returned") hides them.
- The design does not say how the JSON form is documented, for example in `usage`.

**Checked against source**

- `cmd_list` builds `{number, title, state}`.
- `cmd_list "$@"` is passed through and the arguments are unused.
- `jq 'map(...)'` on an empty response gives `[]`, and `jq .` prints `[]`.
- The `@tsv` escaping claim is correct.

Precedent: invalid — passage carried, not read at source. The carried passage covers a retry policy for GitHub calls, not output flags on `list`.

Real alternatives: yes — a `--json` flag on `list` (A) and a separate `list-json` subcommand (B) are both viable and fit the bounds. B's dismissal rests on a missing helper, which does not hold as a reason. The item goes to the owner for architectural review.

**Could not verify**

- The precedent link itself. I have no network access, so I could not confirm that the ADR exists, that its status is Accepted, or that it has no amendment notes.
- The contents of `tests/workitem.bats` and the rest of `bin/alfred-workitem` (`usage`, `cmd_show`, and how `REPO` is set). I had only the quoted `list` part.
