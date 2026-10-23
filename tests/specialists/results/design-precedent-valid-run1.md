**Pass**

Precedent: valid. The note's `Precedent:` line links an ADR at `docs/adr/0041-machine-readable-cli-output.md`. The passage carried in the brief has status Accepted (2026-08-14). Its decision is that a list-printing command offers `--json`, prints one JSON array of objects on stdout, and leaves its text output unchanged without the flag. That covers all of the work: the flag, the array, and AC2. I could not read the link, so this is "passage carried, not read at source".

**Blockers**

None.

**Nits**

1. The passage quoted in the note does not match the passage carried in the brief.
   > "Decision: A command that prints a list offers a `--json` flag that prints one JSON array on standard output."

   The carried text splits this into two sentences and adds "one object per entry" and "Without the flag its text output does not change." The quote is a paraphrase, so quote the ADR verbatim.
2. The test mechanism is not stated well enough for a builder.
   > "Three new tests in `tests/workitem.bats` run `cmd_list` with a stubbed `gh`…"

   The script ends with an unguarded `case "${1:-}" in … *) usage ;;`. Sourcing it to call `cmd_list` directly would run `usage`. The design should say how the tests reach `cmd_list`, for example by running the script with a stub `gh` on `PATH`. It should also say how `REPO` is set.
3. The argument handling is underspecified.
   > "`cmd_list` tests whether its first argument is `--json`."

   It is not stated what happens with `list foo --json` or `list --jsn`. As written, both silently print text. Either accept that explicitly or state the rule.
4. The output form is left open. `jq .` pretty-prints over several lines, and `jq -c` would give one line. Both parse, and AC1 allows either. State which one is intended.
5. The expected effect is partly circular.
   > "`alfred-workitem list --json | jq length` equals the number of open issues the API returned."

   A better check is the test's fixed fixture count, for example 2 and 0. The call is also capped at `per_page=100` with no pagination, and `issues?state=open` returns pull requests as well. Both are existing behaviour and out of scope, but the "open items" wording hides them.
6. The first rejected alternative is weak. "Quote tabs inside titles" is not really a competing design. The reason given still holds, because it would change the AC2 output.

**Real alternatives:** not applicable. The precedent is valid, so this check is not needed.

**Claims I could not verify**

- I had no access to the repo, so I checked the "Current state" claims only against the `bin/alfred-workitem` excerpt in the brief. Against that excerpt they hold: `cmd_list "$@"` is called, `cmd_list` reads no arguments, and the array is built with `jq 'map({number, title, state})'` before `@tsv`.
- I could not confirm that ADR 0041 exists, is Accepted, or has the quoted wording.
- I could not confirm that `tests/workitem.bats` exists or how it currently invokes the script.
