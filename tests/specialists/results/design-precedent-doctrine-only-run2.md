**Fail**

**Blockers**

1. The precedent is not valid.

> Precedent: https://github.com/Screenfields/alfred-platform-docs/blob/main/doctrines/04-prefer-machine-readable-output.md | "Scripts consume what the tools print. Give them an output form that does not need guessing where one field ends and the next begins."

   - The link points into a `doctrines/` folder. It is not an accepted ADR under `docs/adr/` or `docs/decisions/`, and it is not a baseline doc under `docs/baseline/`. A doctrine informs a design and is not a precedent.
   - I could not read the link, because I have no web access and the local doctrine directory was not readable. So the check is "passage carried, not read at source". Even if the passage is accurate, it comes from a doctrine, so it fails step 4.
   - The platform's doctrine list does not match the link. In that list D04 is "Match validation effort to change scope", and none of the entries is about preferring machine-readable output. The link may be stale or wrong.

2. The "Current state" paragraph, and the first part of the problem statement, are partly true, but the design's account of tab handling is unverified.

> `@tsv` writes a tab, a newline or a backslash in a title as `\t`, `\n` or `\\`

   - This matches how jq's `@tsv` behaves. The design never ties it to a script or consumer that breaks, so the "Problem" rests on assertion. This is minor on its own.

3. The design does not say that `--json` must be the first argument. It says only that `cmd_list` "tests whether its first argument is `--json`".
   - The source shows `cmd_list "$@"` and no argument parsing.
   - The design does not say what happens with any other argument, such as `list --jsno`. Today every argument is silently ignored. A builder would have to guess whether to keep ignoring it. Acceptance criterion 2 ("prints exactly the text it prints today") depends on this.

**Nits**

- The design prints `$items` through `jq .`. That is pretty-printed JSON, which is valid. State that this is intended, because the success state says "one JSON array". Output of `[]` for an empty list is correct under `jq .`.
- The expected effect says `jq length` "equals the number of open issues the API returned". `per_page=100` caps the call, and the API's `issues` endpoint also returns pull requests. The design does not mention either point, so "open items" is ambiguous. Both exist today and are out of scope, but the measurable claim should name them.
- The first test needs the stubbed `gh` to be on `PATH` ahead of the real one. The design does not say how.
- The design says "run `cmd_list`", but the script's dispatch is a `case` at file level. Say whether the tests source the file or call the binary.
- Alternative A lists as a con that every later subcommand needs its own flag. That is a weak point, not a reason to dismiss anything. The design does not weigh it against the owner's out-of-scope `--format` decision. This is not a blocker.

**Precedent: invalid** — the link is to a doctrine, which is not an accepted ADR or baseline doc, and the passage was "passage carried, not read at source".

**Real alternatives: yes** — the design names two viable options, A (a `--json` flag) and B (a `list-json` subcommand), and B is dismissed only on a cost reason. B has a real advantage: the text output cannot regress. A plausible third option, an environment variable such as `ALFRED_WORKITEM_OUTPUT=json`, is not listed. Because the precedent is invalid and real alternatives exist, the item goes to the owner for architectural review (AP-ADR0035 item 2).

**Claims I could not verify**

- That the precedent file exists at the cited URL, and whether its text matches the carried passage.
- That `bin/alfred-workitem` in the repo matches the quoted excerpt. I was given only the excerpt and did not read the repo.
- That `tests/workitem.bats` exists and has a stub convention for `gh`.
- That scripts really split the `list` output on tabs.
