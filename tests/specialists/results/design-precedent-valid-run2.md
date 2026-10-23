**Verdict: pass**

Precedent: valid. Passage carried, not read at source. I have no network access, so I could not open the ADR 0041 link. The brief's passage says "Status: Accepted (2026-08-14)". It also says "A command that prints a list offers a `--json` flag. With the flag it prints one JSON array on standard output, one object per entry. Without the flag its text output does not change." That covers `list`, the flag, one array, one object per item, and unchanged text without the flag. I could not read its amendment notes.

**Blockers:** none.

**Checks against the source (`bin/alfred-workitem`, as quoted in the brief)**
- The design says "`cmd_list` ... already builds the open items as a JSON array of `{number, title, state}`". The source confirms it: `jq 'map({number, title, state})'` is stored in `items`.
- The design says "`list` takes its arguments through `cmd_list "$@"`, and `cmd_list` reads none of them". The source confirms both. `list) shift; cmd_list "$@"` makes `--json` arrive as `$1`.
- `jq . <<<"[]"` prints `[]`, so acceptance criterion 3 holds.
- The existing `jq -r` line stays unchanged, so criterion 2 holds.
- The design stays inside the bounds: no `--format`, no new subcommand, no sorting.

**Alternatives:** the two rejections that rest on the work item's bounds hold. The first is weaker: "every script would have to undo the `@tsv` escapes itself". Even so, it is out of the bounds, since the success state asks for JSON. I see no missing plausible alternative.

**Nits**
1. The test mechanism is vague. The design says "Three new tests ... run `cmd_list` with a stubbed `gh`". The source ends in a top-level `case` that calls `usage` when no argument is given, and `REPO` is not set in the shown part. A builder has to guess whether to source the file or run the script with a stub `gh` on `PATH`. Running the script with a `gh` stub on `PATH` and `REPO` set would be unambiguous.
2. Criterion 2 says "exactly the text it prints today". The design does not say what the no-flag test compares against. A fixed expected tab-separated string for the stubbed input would do.
3. The design does not say what happens with other or extra arguments, such as `list --foo` or `list --json x`. Presumably they are ignored as today, but it does not say so.
4. `repos/$REPO/issues?state=open` also returns pull requests, and `per_page=100` has no pagination. The expected effect, "equals the number of open issues the API returned", is true as worded. Both limits already apply to the current text output and are not part of this item. A line in the note would keep a reader from taking `--json` to mean "all open issues".

**Claims I could not verify**
- That ADR 0041 exists at the linked path, that its status is Accepted, and that no amendment changes the passage. Only the carried passage was available.
- The full `bin/alfred-workitem` and `tests/workitem.bats`. I saw only the quoted `list` part, so I could not check how `REPO` is set, whether `set -e` or `pipefail` applies, or how the existing tests load the script.

Precedent: valid — passage carried, not read at source; it covers a list command with a `--json` flag, one JSON array, and unchanged text without the flag.
