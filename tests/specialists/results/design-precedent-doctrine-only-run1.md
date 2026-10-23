**Verdict: fail**

**Blockers**

1. The precedent is invalid.

   > Precedent: https://github.com/Screenfields/alfred-platform-docs/blob/main/doctrines/04-prefer-machine-readable-output.md | "Scripts consume what the tools print. Give them an output form that does not need guessing where one field ends and the next begins."

   The link points into `doctrines/`. It is not an accepted ADR under `docs/adr/` or `docs/decisions/`, and it is not a baseline doc under `docs/baseline/`. A doctrine informs a design and is not a precedent. The passage is also general. It says scripts should get an output form that is easy to parse. It does not decide that `list` gets a `--json` flag. I could not read the link here, so the passage is "passage carried, not read at source". Even if the passage matches the file, the file type is wrong.

**Nits**

- The note doesn't say what happens to an unknown argument, such as `list --foo` or `--json` in a later position. Today `cmd_list` ignores all arguments, and the design keeps that without saying so.
- The expected effect says `alfred-workitem list --json | jq length` "equals the number of open issues the API returned". That check only compares the output with the same call's result. It doesn't show the output is correct.
- The test plan says `cmd_list` runs under a stubbed `gh`. The source ends with a top-level `case "${1:-}"` dispatch that falls through to `usage`. The note doesn't say how `tests/workitem.bats` loads `cmd_list` without running that dispatch, or how the "no flag" test checks that the text is byte-identical to today's output. A builder would have to work that out.
- Alternative B is dismissed with "B needs a helper first". That is an effort reason and doesn't show B is unsound. B's own pro, that the text output cannot regress, is not weighed against it.

**Alternatives**

`Real alternatives: yes — A (--json flag) and B (list-json subcommand) are both viable. B is dismissed only because it needs a shared helper first, which is an effort cost and doesn't rule it out. The item goes to the owner for architectural review (AP-ADR0035 item 2).`

**Precedent**

`Precedent: invalid — the link is a doctrine under doctrines/, not an accepted ADR or a baseline doc, and a doctrine is not a precedent. Passage carried, not read at source.`

**Not verified**

- The link target, which I could not fetch from here.
- Whether `gh api repos/$REPO/issues?state=open` also returns pull requests, and whether `per_page=100` without paging truncates the listing. Both are existing behaviour, but "one object per open item" depends on them.
- Whether `jq .` on `[]` prints `[]`. I expect it does, but I didn't run it.
- That `tests/workitem.bats` exists and can source `bin/alfred-workitem`. I only had the quoted `list` part of the source.
