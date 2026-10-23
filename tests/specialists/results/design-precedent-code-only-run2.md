**Fail**

**Blockers**

1. The precedent is not an accepted ADR or a baseline doc.

> Precedent: https://github.com/Screenfields/ccplugin-alfred-agent-workflow/blob/main/bin/alfred-alfred-config | "# names [--json]: print the config keys, as a JSON array with --json"

The link points to `bin/alfred-config`, a code file. Code counts as precedent only when a baseline doc under `docs/baseline/` describes it, and the note cites no such doc. I could not read the link here, so this is "passage carried, not read at source". The carried passage is a comment about `names [--json]` in another tool. It would not cover this work even if the file were readable. The precedent is therefore invalid.

**Nits**

- The note says `cmd_list` tests only its first argument. `list foo --json` would print text without any error. Say whether that is intended.
- The design does not say how the bats tests load `cmd_list`. The source runs `case "${1:-}"` at the bottom of `bin/alfred-workitem`, so sourcing the file triggers `usage`. State how the tests avoid that.
- The `gh api repos/$REPO/issues` endpoint also returns pull requests. The `per_page=100` limit also cuts the list at 100. Both already apply today. The expected effect, "equals the number of open issues the API returned", is measurable, but the work item says "open items", which is ambiguous.
- The first rejection reason has two parts. "Every script would have to undo the escapes" holds. "The array is already built as JSON" is a reason for the chosen design, not against the alternative.

**Claims I could not verify**

- I did not read `bin/alfred-workitem`, `tests/workitem.bats` or `bin/alfred-config` in the repo. I checked the `cmd_list` description only against the quoted source, and it matches: it reads no arguments and builds `{number, title, state}`.
- I did not check whether any ADR constrains CLI output flags.

Precedent: invalid — the link is code with no baseline doc describing it, and the passage was carried, not read at source.

Real alternatives: no — the work item rules out `--format` and a new subcommand, and the note's rejection of quoting tabs in titles holds. The only open choice is how `--json` is parsed (first argument versus any position), which is a nit and not an architectural alternative. The item can go ahead once its design is recorded in a baseline doc, per AP-ADR0035 item 7.
