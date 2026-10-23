**Verdict: fail**

Precedent: none declared — the note says so, and no `Precedent:` link or passage is carried.

Real alternatives: yes — one of the two listed alternatives is dismissed for a reason that is false, and the other is a strawman. A real choice is open and the design doesn't examine it: fail-closed (exit 2) against the repo's fail-open (exit 0) hook contract. Plausible options that are missing:
- Extend the existing `alfred-workitem guard` PreToolUse hook instead of adding a script.
- Use a settings `permissions.deny` pattern.
- Run the hook fail-open, as the README requires.

The item goes to the owner for architectural review (AP-ADR0035 item 2).

**Blockers**

1. **The claim about current state is false.**
   > `hooks/hooks.json` has no `PreToolUse` entry today, so the design adds a new `PreToolUse` block with the matcher `Bash`.

   The source has one:
   ```json
   "PreToolUse": [ { "matcher": "Bash", "hooks": [ { ... "alfred-workitem\" guard", "timeout": 5 } ] } ]
   ```
   Adding a second `PreToolUse` key would produce duplicate JSON keys, and the later one may silently replace the existing guard. The design has to say that the new hook is appended to the existing Bash matcher's `hooks` array, or sits in a second matcher entry inside the same array. It also has to say how the new hook sits next to `alfred-workitem guard`, and give the new hook's timeout, which it leaves out.

2. **The design conflicts with the documented hook contract.**
   > On any internal failure (`jq` missing, unparseable input, a regex error) the script exits 2

   The README says:
   > Hook-mode scripts use no `set -e`/`set -u` and always exit 0 (CI audits this)

   The README's exit-0 rule is audited, so the new script will fail CI. The note does not mention the audit, so the conflict looks accidental. Fail-closed may be right for a security guard. If so, the design must say it knowingly breaks the README rule and change the README and the CI audit. If not, it must go fail-open. Exit 2 also blocks every Bash call whenever `jq` is missing. The design never weighs that cost.

3. **A dismissed alternative is rejected for a false reason.**
   > Rejected: the thresholds config cannot hold strings, so the patterns have to live in the script.

   `config/thresholds.json` already holds strings (`"waiting-label": "status:waiting-on-owner"`) and string arrays (`"workable-states": [...]`). The rejection doesn't hold, so the choice of where the patterns live is still open.

4. **The success state is ambiguous against the design's behaviour.** The work item says "A command that passes the same secret by stdin runs normally." The design scans the whole command text. So `echo ghp_… | gh auth login --with-token`, or a heredoc, passes the secret by stdin and is still refused. Only the file-redirect form passes. The design should say which stdin forms are allowed and which are refused. It should also say the refusal message must not repeat the matched secret.

5. **The expected effect is not measurable.**
   > Secret handling gets safer, and agents follow the stdin rule more consistently.

   It names no signal, such as the number of refusals or the number of tokens found in transcripts. The acceptance criteria cover only the tests.

**Nits**
- The design reads the hook JSON with `jq`. It should say what happens when `tool_input.command` is absent or null: allow, or treat it as a failure.
- Only three patterns are covered. The rule also names env-var prefixes, which the design doesn't mention. The note should say whether that is out of scope.

**Could not verify**
- I could not check the current repo, because the working directory is not a git repo. I relied on the quoted `hooks.json`, README and `thresholds.json` excerpts.
- I could not confirm that CI really audits the exit codes. That rests on the README sentence.
- I could not confirm that `rules/secrets-via-stdin-never-cmdline.md` is the only ADR or rule involved, or that no accepted ADR covers hook behaviour.
