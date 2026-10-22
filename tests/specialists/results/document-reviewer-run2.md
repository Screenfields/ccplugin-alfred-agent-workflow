_[2026-10-22, time not available: this session has no shell for `date`]_

**Verdict: fail.** Four claims contradict the source, and the example block exposes internal topology in a public repo.

## Blockers

1. **`--all` does not exist.**
   - Document: "`--all` writes a note on every open item, whatever its label." The synopsis also lists `[--all]`.
   - Source: the option parser has only `--repo`, `--label` and `--dry-run`. Everything else hits `*) echo "usage: …" >&2; exit 2`. The usage string has no `--all`. Anyone who runs `alfred-park --all` gets exit 2.

2. **The default label is wrong.**
   - Document: "The default is `status:ready`."
   - Source: `label="status:in-progress"`.
   - The document's own first sentence ("in progress") contradicts its default.

3. **The exit codes are wrong.**
   - Document: "exits 0 when every note was written, 1 when no open item matched, and 2 on a usage error."
   - Source header and code:
     - No match gives an empty loop, so `rc=0` and the script exits 0.
     - Exit 1 means a `gh issue comment` failed (`|| rc=1`).
     - Exit 2 also covers a repo that cannot be determined (`gh repo view … || exit 2`) and a failed `gh issue list` (`|| exit 2`), not only a usage error.
   - A caller who treats exit 1 as "nothing to do" would ignore failed comments.

4. **Internal topology in a public repo.**
   - Document: "`devbox-alfred-cc-tools-0`, node `pve-03`, internal address `10.20.4.31`".
   - The script needs none of this. The hostname, node name and private IP should come out. "From the lead's devbox" is enough, or drop the sentence.

## Nits

- The first sentence describes only the default label. Say "every open item with the selected label (default `status:in-progress`)".
- The document does not say what the note contains. The source posts a fixed text with an Amsterdam-time timestamp: "parked by the lead; state is in this item and its branch". Say so, or the reader may expect a note that summarizes the item.
- The `--dry-run` line is correct. It reads the issue list through `gh issue list`, so it needs `gh` authentication and network access, and it skips only the comments. After the fixes, consider noting that a dry run still exits 2 if the listing fails.
- "Uses the repository of the current directory" is correct, but it relies on `gh repo view`. It exits 2 outside a repository or when `gh` is unauthenticated.

## Claims I could not verify

- Whether `Screenfields/ccplugin-alfred-agent-workflow` is the right repository to name in a public example.
- Whether `--all` exists in another branch or version of the script. I checked only the quoted source, so if it is planned, the README is ahead of the code.
- Whether the quoted source matches `bin/alfred-park` on the default branch. The working directory is not a git repository, so I could not read the file itself.
- Whether the README follows a house template or naming convention. None was supplied.

No ADR, vision or objective is involved, so no owner approval is needed.
