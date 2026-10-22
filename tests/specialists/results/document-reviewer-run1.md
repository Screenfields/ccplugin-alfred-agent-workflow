_[2026-10-22, time not checked: this session has no shell for `date`]_

**Verdict: fail.** Four blockers.

## Blockers

1. **The default label is wrong.**
   - Document: "`--label NAME` selects the items. The default is `status:ready`."
   - Source: `label="status:in-progress"`.
   - The intro sentence ("every open work item that is in progress") matches the source, so the section contradicts itself. Anyone who relies on the documented default will expect different items than the script selects.

2. **`--all` does not exist.**
   - Document: the synopsis and a bullet describe `--all`, "writes a note on every open item, whatever its label."
   - Source: the `case` has only `--repo`, `--label` and `--dry-run`. Any other argument, including `--all`, hits `*)`, prints the usage line and exits 2. The usage line and header comment do not list `--all` either.
   - Following the README fails with a usage error.

3. **The exit codes are wrong.**
   - Document: "exits 0 when every note was written, 1 when no open item matched, and 2 on a usage error."
   - Source header: "Exit 0 when every note was written (or nothing matched), 1 when a comment failed, 2 on a usage error or when the repo cannot be determined."
   - Code: when nothing matches, the loop does not run and the script exits 0. `rc=1` is set only when `gh issue comment` fails.
   - Anyone scripting around the documented codes would treat an empty result as a failure and miss a failed comment.
   - Exit 2 also covers a failed repo lookup and a failed `gh issue list`, which the document leaves out.

4. **Internal topology is in a public repo.**
   - Document: "`devbox-alfred-cc-tools-0`, node `pve-03`, internal address `10.20.4.31`."
   - This is host name, hypervisor node and private IP. The usage example does not need any of it: the command is the same on any machine with `gh`.
   - Remove it, or say "from the lead's devbox". Check the git history too. If this text has been published, the address may need more than an edit.

## Nits

- The `--dry-run` bullet is accurate. `gh issue list` does run, so it needs auth and network.
- The document does not say what the note contains: a timestamp in Europe/Amsterdam time plus the fixed text "parked by the lead; state is in this item and its branch." A reader parking from another role might want to know that.
- The document does not say that the 50-item limit silently truncates. It does not warn when more items match.
- The "Typical use" example repeats the repo name explicitly. That is fine, but `--repo` is optional by the document's own account.

## Not verified

- Whether `bin/alfred-park` is the current version on the default branch. I only had the quoted source.
- Whether the `status:ready` and `status:in-progress` labels exist in `Screenfields/ccplugin-alfred-agent-workflow`, and which one the workflow actually uses. This is needed to decide which side of blocker 1 should change. The source is the authority for what the script does, but not for what is intended.
- Whether the devbox, node and address are real. Their removal does not depend on that.
- Whether the section cites other documents, such as an ADR or the README structure. None were given, so the consistency check and the owner-approval check do not apply here.
