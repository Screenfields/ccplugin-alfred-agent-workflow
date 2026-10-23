---
name: issue-and-pr-titles-carry-codes
roles: [lead]
work: [work item]
severity: minor
---
An issue title starts with its own ID (`<CODE>-<n>: ...`, for example `CCW-139: ...`), so the title is fixed with an edit after creation; a PR title starts with the ID of the issue it implements (`CCW-128: ...` for PR #136), not its own number, and may carry any registered code; PRs are referenced as `<CODE>#<n>` (`CCW#136`), ADRs as `<CODE>-ADR<nnnn>`, and the PR body keeps `Closes #N`. CODE comes from alfred-code-lookup `<owner/repo>`; the `code` in `.alfred/config.json` is the fallback for the session's own repo only, and a code is never taken from memory. Invoke it as `CL=$(command -v alfred-code-lookup || echo "${CLAUDE_PLUGIN_ROOT:-}/bin/alfred-code-lookup")`; a `CL` that is not executable counts as exit 2. If exit 0: use the code. If exit 1 (no code, for example an ops repo): title without a prefix, plus one line in the PR or issue body, "repo has no registry code". If exit 2 (registry failure): use the config `code` if present for the own repo, otherwise no prefix plus the body line "registry unreachable; title not coded". Typed IDs link on GitHub only when titles and references use the codes consistently.
