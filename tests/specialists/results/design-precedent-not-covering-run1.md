**Fail**

Precedent: invalid. Passage carried, not read at source. I did not open the ADR 0038 link. The passage in the brief is about retrying GitHub API calls that fail with HTTP 5xx. It says nothing about CLI output formats, JSON output or the `list` subcommand, so it does not cover this work. The note quotes:

> Precedent: https://github.com/Screenfields/alfred-platform/blob/main/docs/adr/0038-retry-policy-for-github-calls.md | "Status: Accepted (2026-07-02). Decision: A call to the GitHub API that fails with HTTP 5xx is retried up to 3 times with a pause of 2 seconds. Other failures are not retried."

Real alternatives: yes. Both A (`--json` flag) and B (`list-json` subcommand) are viable. The design dismisses B with only "B needs a helper first", which is a build-effort cost. It is not a reason B cannot work. B also has a benefit the design itself names: `list` stays untouched, so the text output cannot regress (acceptance criterion 2). The reasons given against A are likewise weak ("every later subcommand … needs its own flag"). The item goes to the owner for architectural review.

**Blockers**

1. The precedent is invalid, as above. This blocks the item.
2. The dismissal of B does not hold. The note quotes:
   > Recommendation: A, because the array is already built in `cmd_list` and B needs a helper first.

   The source shows the fetch is a 3-line function body. Extracting it takes little effort. The design does not weigh this against B's no-regression property, which matters for criterion 2.

**Nits**

- The note does not say what `list` does with an unknown argument, such as `list --jsno`. `cmd_list` ignores arguments today, so it would silently print text. A script that mistypes the flag then fails to parse. The note says only "tests whether its first argument is `--json`".
- The test plan says the tests "run `cmd_list`". The script ends in a `case` dispatch that runs on load. The note does not say how bats reaches `cmd_list`: by invoking the script with a `gh` stub on `PATH`, or by sourcing it. A builder would have to guess.
- The "no flag" test must assert the exact current tab-separated text (number, state, title), because criterion 2 says "exactly". The note does not say it will.
- `per_page=100` with no pagination means only the first 100 issues come back. The `issues` endpoint also returns pull requests. The expected effect ("equals the number of open issues the API returned") is true by definition and would not catch either gap. This predates the change and is probably out of scope, but "open items" is not defined.

**Could not verify**

- That the ADR 0038 file exists, is Accepted, and contains the quoted passage. I did not read it at the link.
- That `bin/alfred-workitem` and `tests/workitem.bats` match the quoted source. I checked the design only against the excerpt in the brief. Against that excerpt, the claims about `cmd_list` building the array and ignoring its arguments are accurate.
