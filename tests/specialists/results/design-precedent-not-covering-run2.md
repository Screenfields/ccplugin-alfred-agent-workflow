**Fail**

Blockers:

1. The precedent does not cover the work.

> Precedent: https://github.com/Screenfields/alfred-platform/blob/main/docs/adr/0038-retry-policy-for-github-calls.md | "Decision: A call to the GitHub API that fails with HTTP 5xx is retried up to 3 times with a pause of 2 seconds."

   I could not read the link, because I have no network access here. The brief carries the passage, so the check below uses that. The carried passage reads "Status: Accepted (2026-07-02)" and "Decision: A call to the GitHub API that fails with HTTP 5xx is retried up to 3 times with a pause of 2 seconds. Other failures are not retried." This ADR is about retrying failed GitHub calls. It says nothing about the output format of `alfred-workitem list`, a `--json` flag, or machine-readable output. The passage does not cover this work.

Precedent: invalid — passage carried, not read at source; the passage is a retry policy for GitHub API 5xx failures and does not cover JSON output for `list`.

Real alternatives: yes — the note lists A (`--json` flag) and B (`list-json` subcommand). B is dismissed with "B needs a helper first." That reason is weak. The helper is small, and the note itself concedes that B's strength is that "the text output cannot regress", which bears directly on acceptance criterion 2. A plausible third option is missing: an environment variable or another way for a script to ask for the JSON form. The bounds put "the way a script asks for the JSON form" in scope. Because a real alternative exists, the item goes to the owner for architectural review (AP-ADR0035 item 2).

Nits:

- **Argument handling is incomplete.** The note only says `cmd_list` "tests whether its first argument is `--json`". It does not say what happens with `list --foo`, `list --json extra`, or `--json` in a later position. As written, an unknown argument silently falls through to text output. A builder would have to guess.
- **Item count above 100.** The source has `per_page=100` and no pagination. Criterion 1 asks for "one object per open item", and the expected effect says `jq length` "equals the number of open issues the API returned". With more than 100 open items, the output would stop at 100. This is existing behaviour, but the note should state it as a limit or bound.
- **Pull requests.** `repos/$REPO/issues` also returns pull requests. The note says "open issues" and "open items" without saying whether PRs are included.
- **Test design.** The note says the tests "run `cmd_list` with a stubbed `gh`". The source ends with a top-level `case "${1:-}"` dispatch, so sourcing the script in bats would run that dispatch. The note does not say how the tests invoke `cmd_list`. It also does not say that the no-flag test compares against the exact current TSV text, which criterion 2 requires.
- **`$REPO` is not defined** in the quoted part of the script. I assume it is set elsewhere.

Could not verify:

- The ADR file and its status at the link. Only the carried passage was checked.
- `tests/workitem.bats` and the rest of `bin/alfred-workitem` (`$REPO`, `usage`, how the script is sourced or run in tests). I only had the quoted `list` part.
- That the quoted source matches the repo now. I could not read the repo, so I checked the "Current state" claims against the quoted source only. They match it: `cmd_list` builds the `{number, title, state}` array, prints TSV, and ignores its arguments.
