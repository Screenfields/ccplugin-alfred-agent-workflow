**Fail**

Precedent: invalid — the design note has no `Precedent:` line, so it declares neither a link nor "none declared".

Real alternatives: yes — B is dismissed only by effort, which does not hold as a reason. Details are in blocker 2.

## Blockers

1. **No precedent line.** The note has no line beginning `Precedent: `. A note without one has an invalid precedent, and that blocks it. The note must declare either a link with a quoted passage or `Precedent: none declared`.

2. **B's dismissal does not hold.** The note says:
   > Recommendation: A, because the array is already built in `cmd_list` and B needs a helper first.

   B's own listed con is only that "the fetch code is shared through a helper that does not exist yet". That is a small amount of work, not a barrier. B also has a pro that A lacks and that matters here. It leaves `list` untouched, so criterion 2 ("prints exactly the text it prints today") cannot regress. The note does not weigh that against A. Because the choice rests on effort alone, the item goes to the owner for architectural review.

3. **The test setup cannot be built as written.** The note says:
   > Three new tests in `tests/workitem.bats` run `cmd_list` with a stubbed `gh`

   The source ends with a top-level `case "${1:-}" in … *) usage ;; esac`. Sourcing the script to call `cmd_list` directly would run that dispatch with an empty `$1` and hit `usage`. The note does not say how the tests call it. It could be by running the script with a stub `gh` on `PATH`, or by a source guard. It also does not say where `$REPO` comes from, since the quoted part of the script never sets it. A builder would have to ask.

4. **The no-flag test has no stated assertion.** Criterion 2 requires "exactly the text it prints today". The note gives no expected output for the stubbed array, such as the exact tab-separated lines. Without it, the third test could pass without proving the criterion.

## Nits

- **Expected effect.** The note says:
  > `alfred-workitem list --json | jq length` equals the number of open issues the API returned.

  This only checks the output against the API response. The source fetches `per_page=100` with no pagination. Past 100 open issues the array is truncated, which breaks criterion 1 ("one object per open item"). The endpoint also returns pull requests. Both behaviours already exist, but the note should either state them as known limits or state that they are outside the bounds.
- **Unknown arguments.** Today `list` ignores all arguments. The design checks only the first argument. `list foo --json` therefore prints text, and `list --json foo` prints JSON. Say whether that is intended.
- **Output format.** `jq .` pretty-prints. Criterion 1 only requires a parseable array, so this is fine, but state it so the test can compare the output.

## Not verified

- **Repo state.** I did not read the repo or the issue. I checked the "Current state" claims only against the quoted source, and they match it. That covers the array of `{number, title, state}`, `cmd_list "$@"`, and `cmd_list` reading no arguments.
- **The rest of `bin/alfred-workitem`.** I did not see where `$REPO` is set, what `usage` does, or whether `tests/workitem.bats` already has a stub pattern for `gh`.
- **The `@tsv` escaping claim.** I took the claim in the Problem section as stated. It is standard jq behaviour.
