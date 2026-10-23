**Fail.**

**Blockers**

1. The design misstates current state. It says:
> `hooks/hooks.json` has no `PreToolUse` entry today, so the design adds a new `PreToolUse` block with the matcher `Bash`.

   The source shows a `PreToolUse` entry with matcher `Bash` that already runs `"${CLAUDE_PLUGIN_ROOT}/bin/alfred-workitem" guard`. The design must say whether the new hook is a second command in that block, replaces the existing one, or is folded into `alfred-workitem guard`. It must also say how the two hooks interact. If two hooks run on the same call, a builder could overwrite the existing guard or produce a duplicate key. The design doesn't cover this, and it makes the "registered in `hooks/hooks.json`" criterion ambiguous.

2. The failure behavior contradicts a stated convention that CI enforces. The design says:
> On any internal failure (`jq` missing, unparseable input, a regex error) the script exits 2

   The README says:
> Hook-mode scripts use no `set -e`/`set -u` and always exit 0 (CI audits this); a syntax error would exit 2, which blocks, so CI also runs `bash -n` on every hook.

   As written, the new script fails the CI audit. The design neither mentions the convention nor proposes an exemption or a change to the audit. Fail-closed may be the right call. If it is, the design has to justify it, since a missing `jq` would then block every Bash call. It also has to say how the CI audit changes. The design doesn't acknowledge this conflict.

3. A dismissed alternative is rejected for a false reason. The design says:
> *Patterns in `config/thresholds.json`.* Rejected: the thresholds config cannot hold strings

   The source shows `thresholds.json` holding strings (`"waiting-label": "status:waiting-on-owner"`, `"ready-state": "status:ready"`) and a string array (`"workable-states"`). Strings are therefore not the obstacle. The rejection doesn't hold, and the design has not given a real reason for keeping the patterns in the script.

4. The expected effect isn't measurable. The design says:
> Secret handling gets safer, and agents follow the stdin rule more consistently.

   It gives no metric, no observable signal and no threshold, for example the number of denials or a check that a token-bearing command never reaches execution. The acceptance criteria are testable, but the stated effect is not.

**Precedent:** none declared — the note declares none.

**Real alternatives:** yes — the only dismissed alternatives are the thresholds config, which was rejected for a false reason, and the after-the-fact transcript scan. A plausible alternative is missing: extend the existing `alfred-workitem guard` PreToolUse hook instead of adding a second script. Others are exiting 0 with the deny JSON in every failure path, which follows the README convention, and a different failure policy for a missing `jq`. Because a real alternative exists, the item goes to the owner for architectural review (AP-ADR0035 item 2).

**Nits**

- The rule also names env-var prefixes, heredoc literals and here-strings. The design covers only three token shapes and doesn't say that other secret forms are out of scope.
- The test list has no case for a token inside a heredoc or here-string, and no case showing that `< /tmp/tok` passes when the command also contains a non-secret `ghp_` substring.
- The deny reason text is not specified, and acceptance requires it to say how to pass the secret by stdin. The test should assert that text.
- A match on `ghp_[A-Za-z0-9]{20,}` can also hit the middle of a longer string. The design should state that this is accepted.

**Could not verify**

- I did not read the repo. I judged only the quoted excerpts, so I can't say whether other `PreToolUse` or `Stop` hooks, or the CI audit script itself, exist beyond what is quoted.
- I did not check `tests/secret-arg-guard.bats` or `hooks/secret-arg-guard.sh` for existence or content.
- I did not confirm that exit 2 from a hook blocks the Bash call in the installed Claude Code version. I took that from the README.
