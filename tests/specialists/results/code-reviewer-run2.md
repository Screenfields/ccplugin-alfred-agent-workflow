**Fail**

**Blockers**
1. `bin/alfred-config`, `names` branch: the change is unrelated to the work item. `names` now filters out object-valued keys, so `model-setting-per-role` no longer appears. That breaks criterion 4 and goes beyond the bounds. Restore `jq -r 'keys_unsorted[]' "$file"`.
2. `bin/alfred-config`, thresholds-file check: with `--default`, a missing or malformed file now prints the default and exits 0. Criterion 3 requires exit 2 with a stderr message, with or without `--default`. This is the hidden-broken-config case the work item says it must not allow. Remove the `have_default` branch in the file check.
3. `README.md`, "Thresholds" section: not touched, and the diff doesn't include it. Criterion 5 needs `--default` described there. The README sentence "An unknown name… exits 2" also needs to say that `--default` changes the unknown-name case.
4. `tests/thresholds.bats`, last test: "a missing thresholds file still exits 2 with --default" doesn't pass `--default`. It passes only because the code path without `--default` is unchanged, so it doesn't test the change. Blocker 2 is exactly the behaviour it should catch. Add `--default 9`, and add a malformed-file case.

**Nits**
- `bin/alfred-config`, header comment: the `get` line is now longer than the aligned continuation lines below it.
- `tests/thresholds.bats`: there's no test that `names` is unchanged. One would have caught blocker 1.

**Criteria**
1. Met, by reading the diff. An existing key goes through the unchanged `jq` print path. `has()` is used rather than truthiness, so `false` prints. The `flag` test covers it. I didn't run the tests.
2. Met, by reading the diff. An unknown name with `--default` prints the default and exits 0. The test covers it.
3. Not met. A missing or malformed file with `--default` exits 0 (blocker 2), and the test doesn't cover that case (blocker 4).
4. Not met. The `names` output changed (blocker 1).
5. Partly met. The usage string and header comment are updated. The README is not (blocker 3).

The builder's "11 tests, 0 failures" doesn't show the criteria are met. The tests never exercise the two regressions.
