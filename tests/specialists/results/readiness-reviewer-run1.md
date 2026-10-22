**Result: FAIL**

**Failed checks, in order:**

1. **Charter: objective trace.** The item says it supports O7, "Keep the plugin repo lean". The register has only O1–O4, so O7 doesn't exist and can't be approved. The item has no approved objective to trace to. The business case is also thin. Its benefit is "less noise when listing branches", and nothing says how that is measured.

2. **Size: class.** The item says small. The sizing rule says a change that touches a threshold is medium at least, and this change adds `stale-branch-days` to `config/thresholds.json`. Small is wrong on that point alone. The 1.1M estimate and the note that no extra spending is needed are consistent with a medium item. The class is the problem, not the estimate. Because the class is doubtful, I'm failing it and not passing it with a caveat.

3. **Success state and acceptance criteria.**
   - The success state, "a list of branches that have had no commit for a long time", does not say what the lead notices. It also doesn't mention the weekly cadence in the title, and nothing in the item delivers a weekly report. The script lists branches but nothing runs it weekly. The item doesn't say whether the lead runs it by hand.
   - Criterion 2, "fast and easy to read", can't be tested. It has no check and no limit.
   - Criteria 1, 3 and 4 have no named check. For example, none says which test, runner or file shows that the script exits 2 when the repo can't be read.
   - Criterion 1 does not say what to do with branches that have no author or with the default branch. That is a minor gap.

4. **Bounds.**
   - The test structure says "Not decided yet". The template needs the runner, style and file.
   - In scope, out of scope and blocked-by are fine. #131 is closed and merged in 2.25.0, so the blocked-by link checks out.

**Expected class:** medium, because the change adds a threshold name.

**To get a pass:**
- Trace the item to an approved objective. Either get O7 added to the register and approved, or re-point the item to one that exists.
- Re-class it as medium and re-check the estimate.
- Rewrite the success state so it names what the lead notices.
- Replace criterion 2 with a measurable one, and name a check for each criterion.
- Fill in the test structure: runner, style and file.
