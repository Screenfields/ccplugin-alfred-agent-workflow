**Blockers**

1. The precedent does not cover this work. The note says:

> Precedent: https://github.com/Screenfields/alfred-platform/blob/main/docs/adr/0038-retry-policy-for-github-calls.md | "Status: Accepted (2026-07-02). Decision: A call to the GitHub API that fails with HTTP 5xx is retried up to 3 times with a pause of 2 seconds. Other failures are not retried."

   The passage is about retrying failed GitHub calls. It says nothing about the output format of `alfred-workitem list` or about adding a flag to a subcommand. I could not read the link, so this is "passage carried, not read at source". Even taken at face value, the passage does not cover the work.

**Precedent: invalid** — the passage was carried and not read at source. The ADR it quotes sets a retry policy for GitHub calls and does not cover a JSON output form for `list`.

**Real alternatives: yes** — the note lists A (`--json` flag) and B (`list-json` subcommand). Both are viable, and B's dismissal rests only on cost: B "needs a helper first". That is a preference, not a reason B cannot work. The item goes to the owner for architectural review (AP-ADR0035 item 2).

**Nits**

- **Argument handling.** The note says `cmd_list` "tests whether its first argument is `--json`". It does not say what happens with `list foo --json`, `list --json extra`, or an unknown flag. Today `cmd_list` ignores all arguments, so these would silently print text. A builder needs the rule stated.
- **Pagination.** The source fetches `per_page=100` with no pagination, and the issues endpoint also returns pull requests. Criterion 1 asks for "one object per open item". The expected effect is worded as "the number of open issues the API returned", which sidesteps this. The limit is existing behaviour, but the note should say it is out of scope, or the criterion is not met above 100 items.
- **Test method.** The note says the tests "run `cmd_list` with a stubbed `gh`". In the source, the `case` dispatch sits at the bottom of the script, and running it with no arguments falls through to `usage`. The note does not say how the tests load `cmd_list`, whether by sourcing with a guard or by invoking the script with `gh` on `PATH`. Say which one.
- **Text test.** The "no flag" test should assert the exact current TSV output against a fixed fixture. This is what criterion 2 requires, and the note does not state it.
- **Con of A.** The note lists "every later subcommand needs its own flag" as a con of A. The bounds rule out a `--format` option, so say that this is accepted.

**Claims I could not verify**

- The ADR 0038 file and its status. I could not read the link, so I only have the passage carried in the brief.
- The full `bin/alfred-workitem` and `tests/workitem.bats`, including how the script handles sourcing and what `usage` does. I only saw the `list` excerpt.
- That the GitHub issues API returns a `state` field for every item. I believe it does, but I did not check it against the live API.

I checked the "Current state" claims against the source excerpt. `cmd_list` builds `{number, title, state}` and prints it with `jq -r ... @tsv`. It is called as `cmd_list "$@"` and reads no arguments. Those claims hold.
