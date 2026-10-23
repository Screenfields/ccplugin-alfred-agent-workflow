**Fail**

The precedent is invalid, and the design has one blocker on top of that.

**Blockers**

1. The design has no `--json` parse that holds up under the existing dispatch, and the test plan doesn't match the interface. That part is minor. The precedent is the main problem.

   The note says:
   > Precedent: https://github.com/Screenfields/alfred-platform-docs/blob/main/doctrines/04-prefer-machine-readable-output.md | "Scripts consume what the tools print. Give them an output form that does not need guessing where one field ends and the next begins."

   The link points to `doctrines/` in a docs repo. Under step 4, a doctrine informs a design and is not a precedent. A precedent is an accepted ADR under `docs/adr/` or `docs/decisions/`, or a baseline doc under `docs/baseline/` on the default branch. The path is not any of those.

   I could not read the link. I can't reach GitHub, and the local doctrines directory was denied. The brief does carry the passage, so I record it as "passage carried, not read at source". The passage is general guidance and does not cover this choice: a `--json` flag versus a new subcommand.

2. The design note says "Three new tests in `tests/workitem.bats` run `cmd_list` with a stubbed `gh`". The source shows `cmd_list` is only reached through the `case` dispatch at the bottom of `bin/alfred-workitem`. The note doesn't say whether the tests call the script or source the function. Sourcing would run the `case` dispatch and call `usage`. This is a gap a builder would have to ask about.

**Precedent: invalid — the link is a doctrine, not an accepted ADR or baseline doc; passage carried, not read at source, and the passage is general and does not cover the flag-or-subcommand choice.**

**Real alternatives: yes — the note lists two viable options, A (`--json` flag) and B (`list-json` subcommand). B is dismissed only on cost grounds ("needs a helper first"), which is a weak reason, and a third option (an environment variable) is missing. The item goes to the owner for architectural review (AP-ADR0035 item 2).**

**Nits**

- Alternative A's stated con, "every later subcommand that wants JSON needs its own flag", is not a reason against it. It also sits close to the `--format` option that the work item puts out of scope. The note should say it leaves that decision open.
- The note doesn't say what happens with unknown arguments, such as `list --jsno`. Today they are silently ignored, so the typo would print text and a script would fail to parse it. Say whether that is accepted.
- Only the first argument is tested. `list --json` works, but the note doesn't say whether an argument in any other position is ignored.
- The expected effect `alfred-workitem list --json | jq length` equals "the number of open issues the API returned". That is hard to check against a live API. The bats tests with the stub already prove it, so say so.
- The current-state claim that `per_page=100` caps the list is not addressed. Above 100 open items the JSON array is silently truncated. This predates the change, but the note should say so now that a script depends on the array being complete.
- Criterion 2 says the text output stays exactly as it is. The note covers this with the "no flag" test, but that test should compare against the exact current tab-separated output with a title that contains a tab, so the escaping is also pinned.

**Could not verify**

- The precedent link and its content: no network access, and the local doctrines path was denied.
- That `bin/alfred-workitem` and `tests/workitem.bats` match the quoted source. The working directory holds no repo, so I relied on the quoted excerpt.
- The claim that `@tsv` escapes tabs, newlines and backslashes. This is standard `jq` behaviour that I know, but I did not run it here.
- Issue #162 itself, which I read only as quoted in the brief.
