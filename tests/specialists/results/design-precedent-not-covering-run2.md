**Fail**

**Blockers**

1. The precedent is invalid. The note says:

> Precedent: https://github.com/Screenfields/alfred-platform/blob/main/docs/adr/0038-retry-policy-for-github-calls.md | "Status: Accepted (2026-07-02). Decision: A call to the GitHub API that fails with HTTP 5xx is retried up to 3 times with a pause of 2 seconds. Other failures are not retried."

I have no network or GitHub access in this session. I could not read the link, so I checked the passage the brief carries. That passage reads Accepted and sits at a `docs/adr/` path. It decides a retry policy for failing GitHub API calls. It says nothing about CLI output formats, a `--json` flag, or `alfred-workitem list`. So the passage does not cover this work, and it is not a precedent for it. Passage carried, not read at source.

**Real alternatives:** yes. Alternative A (a `--json` flag on `list`) and alternative B (a `list-json` subcommand) are both viable. The note dismisses neither with a reason that rules it out. It only recommends A on cost. The recommendation of A also leaves "every later subcommand that wants JSON needs its own flag" open. Because the precedent is invalid, the item goes to the owner for architectural review (AP-ADR0035 item 2).

**Nits**

- The test setup is unspecified. The note says the tests "run `cmd_list` with a stubbed `gh`". The `case` dispatch at the bottom of `bin/alfred-workitem` runs when the file is sourced. With no argument it calls `usage`. The builder has to choose between sourcing the file and running the script with a stub `gh` on `PATH`. The note should say which. It should also say how `$REPO` is set in the tests.
- "Tests whether its first argument is `--json`" leaves other arguments undefined. Examples are `list foo` and `list --json extra`. Say whether they are ignored, as today, or rejected.
- `issues?state=open&per_page=100` has two effects that predate this change. It returns pull requests as well as issues. It also stops at 100 items with no pagination. The expected effect words this carefully ("the number of open issues the API returned"). The success state says "the open items", which is wider. Name the limit or accept it explicitly.
- Alternative B is dismissed because "the fetch code is shared through a helper that does not exist yet". That is weak. Writing the helper is a small change. The stronger argument for A is the one already given: one command to document.

**Claims I could not verify**

- The `bin/alfred-workitem` source was only available as quoted in the brief. I did not check it against the repo.
- The existence and status of ADR 0038 at the link.
- That `tests/workitem.bats` exists and which stub conventions it uses.

I checked these claims against the quoted source, and they hold:
- `cmd_list` builds `{number, title, state}` as a JSON array.
- `cmd_list` prints it with `@tsv`.
- `list` passes `"$@"` to `cmd_list`, which reads none of it.
- `jq .` on `[]` prints `[]`, so acceptance criterion 3 is met.
