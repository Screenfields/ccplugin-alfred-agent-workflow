**Fail**

**Blockers**
- `bin/alfred-config:44-49`: with `--default`, a missing or malformed thresholds file now prints the default and exits 0. Criterion 3 requires exit 2 with a stderr message. This is the `|| true` problem the work item exists to avoid. Remove the `have_default` branch so the file check always exits 2.
- `bin/alfred-config` (last `names` line): `names` changed from `keys_unsorted[]` to `to_entries[] | select(.value | type != "object") | .key`. This silently drops object-valued keys, such as `model-setting-per-role` in `config/thresholds.json`. Criterion 4 says `names` output must not change. Nothing in the work item asks for this. Restore `keys_unsorted[]`.
- `README.md`: not changed in the diff. Criterion 5 needs `--default` described in the "Thresholds" section. The README is within bounds. The section also still says an unknown name exits 2 without mentioning the default.

**Nits**
- `tests/thresholds.bats` (last test): "a missing thresholds file still exits 2 with --default" does not pass `--default`. It would pass on the old code, so it doesn't test the change. It would also have caught the first blocker if it did pass `--default`.
- `tests/thresholds.bats`: there is no test for a malformed file with `--default`. There is also no test that `names` output is unchanged, which would have caught the second blocker.
- `bin/alfred-config:9`: the usage comment's continuation lines are no longer aligned after the line was lengthened.

**Criteria** (read from the diff only; I did not run the tests. The reported 11 passing tests do not exercise the blockers.)
1. Met. An existing name goes through `has()` and then `tojson`, so `false` prints as `false`. The test covers it.
2. Met. An unknown name with `--default` prints the default and exits 0. The test covers it.
3. Not met. A missing or malformed file with `--default` exits 0 and prints the default. The test doesn't pass `--default`.
4. Not met. `names` output changed for object-valued keys. The exit codes for `get` without `--default` are unchanged.
5. Partly met. The usage string and header comment are updated, but the README is not.

Reviewed at: <Head SHA not provided in the brief>
