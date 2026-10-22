**Fail**

Failed checks, in order:

1. **Charter: trace to an approved objective.** The item cites O7, "Keep the plugin repo lean". The register lists only O1–O4, so O7 doesn't exist there and can't be approved. Either cite an approved objective (none obviously fits) or get O7 into the register first.
2. **Size: class.** The item says small. The sizing rule says a change touching a threshold is medium at least, and this item adds the threshold `stale-branch-days` to `config/thresholds.json`. **Expected class: medium.** Re-derive the estimate for that class. Separately, the notional cost doesn't match its own inputs: 0.07M × EUR 0.21 is about EUR 0.015, which rounds to 0.01, not 0.02. The token totals and the weighted 0.07M do add up.
3. **Success state.** "A list of branches that have had no commit for a long time" doesn't name what the lead notices at the weekly retro. "A long time" can't be tested. State the outcome, for example that the lead sees the stale branches at the retro without searching for them. Say how the report reaches the lead, and give the default value of `stale-branch-days`.
4. **Acceptance criteria.**
   - Criterion 2, "fast and easy to read", is not testable. Replace it with measurable terms, such as a time limit on a repo of a stated size and a fixed column layout.
   - None of the four criteria names the check that proves it (test, command or file). Criterion 1 is also unclear on whether the default branch counts as a remote branch.
5. **Bounds: test structure.** "Not decided yet" fails the requirement to specify tests by runner, style and file. The scope and blocked-by parts are fine: #131 is merged in 2.25.0, and the out-of-scope lines are clear.

Resubmit after fixing 1–5. The item should be reclassified as medium. Since medium is not large, the owner's approval isn't required for the class, and no extra spending is claimed.
